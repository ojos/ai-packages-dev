#!/usr/bin/env bash
set -euo pipefail

PLAN_FILE=""
ISSUE_NUMBER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue|-i)
      ISSUE_NUMBER="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1"
      echo "Usage: scripts/worker/orchestrate-task.sh [--issue <number>] <plan-file>"
      exit 1
      ;;
    *)
      if [[ -z "$PLAN_FILE" ]]; then
        PLAN_FILE="$1"
        shift
      else
        echo "Unexpected argument: $1"
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$PLAN_FILE" && -z "$ISSUE_NUMBER" ]]; then
  echo "Usage: scripts/worker/orchestrate-task.sh [--issue <number>] [plan-file]"
  exit 1
fi

ROOT_DIR="$(git rev-parse --show-toplevel)"
ENGINE_ROUTING_FILE="$ROOT_DIR/.multi-agent/engine-routing.json"
CONFIG_FILE="$ROOT_DIR/.agent-swarm-framework.config.json"

role_default_engine() {
  local role="$1"
  case "$role" in
    orchestrator|planner|closer) echo "copilot" ;;
    implementer) echo "claude" ;;
    reviewer) echo "gemini" ;;
    *) echo "copilot" ;;
  esac
}

resolve_role_engine() {
  local role="$1"
  local task_kind="$2"
  local default_engine
  default_engine="$(role_default_engine "$role")"

  if [[ -f "$ENGINE_ROUTING_FILE" ]]; then
    jq -r --arg role "$role" --arg task "$task_kind" --arg def "$default_engine" '
      (.taskEngineOverrides[$task][$role] // .roleEngines[$role] // $def)
    ' "$ENGINE_ROUTING_FILE" 2>/dev/null || echo "$default_engine"
    return
  fi

  if [[ -f "$CONFIG_FILE" ]]; then
    jq -r --arg role "$role" --arg task "$task_kind" --arg def "$default_engine" '
      (.taskEngineOverrides[$task][$role] // .agentEngines.roles[$role] // $def)
    ' "$CONFIG_FILE" 2>/dev/null || echo "$default_engine"
    return
  fi

  echo "$default_engine"
}

run_engine_with_prompt_file() {
  local role="$1"
  local engine="$2"
  local prompt_file="$3"
  local output_file="$4"
  local prompt_size
  local prompt
  local stderr_tmp

  if [[ ! -f "$prompt_file" ]]; then
    log "prompt file not found: $prompt_file"
    return 1
  fi

  stderr_tmp="$(mktemp)"

  case "$engine" in
    claude|gemini|codex)
      if ! command -v "$engine" >/dev/null 2>&1; then
        log "engine command not found: $engine (role=$role)"
        rm -f "$stderr_tmp"
        return 1
      fi
      # Prefer stdin mode to avoid argv size limits on large prompts.
      if cat "$prompt_file" | "$engine" -p > "$output_file" 2>"$stderr_tmp"; then
        rm -f "$stderr_tmp"
        return 0
      fi

      # Fallback for CLI variants that require -p <prompt> explicitly.
      prompt_size="$(wc -c < "$prompt_file" | tr -d ' ')"
      if [[ "$prompt_size" =~ ^[0-9]+$ ]] && (( prompt_size > 100000 )); then
        log "prompt too large for argv fallback: size=${prompt_size} engine=$engine role=$role"
        if [[ -s "$stderr_tmp" ]]; then
          log "engine stderr: $(sed -e 's/[[:cntrl:]]/ /g' "$stderr_tmp" | head -n 1)"
        fi
        rm -f "$stderr_tmp"
        return 1
      fi

      prompt="$(cat "$prompt_file")"
      if "$engine" -p "$prompt" > "$output_file" 2>>"$stderr_tmp"; then
        rm -f "$stderr_tmp"
        return 0
      fi

      if [[ -s "$stderr_tmp" ]]; then
        log "engine stderr: $(sed -e 's/[[:cntrl:]]/ /g' "$stderr_tmp" | head -n 1)"
      fi
      rm -f "$stderr_tmp"
      return 1
      ;;
    *)
      log "unsupported engine for CLI execution: role=$role engine=$engine"
      rm -f "$stderr_tmp"
      return 1
      ;;
  esac
}

# Issue mode or Plan mode
if [[ -n "$ISSUE_NUMBER" && -z "$PLAN_FILE" ]]; then
  # Issue mode: fetch and infer
  ISSUE_JSON="$(gh issue view "$ISSUE_NUMBER" --json title,body)"
  ISSUE_TITLE="$(printf '%s' "$ISSUE_JSON" | jq -r '.title')"
  ISSUE_BODY="$(printf '%s' "$ISSUE_JSON" | jq -r '.body')"
  
  PLAN_TEXT="$ISSUE_BODY"
  PLAN_SOURCE_LABEL="Issue #$ISSUE_NUMBER"
  
  # Infer task kind from issue title
  if [[ "$ISSUE_TITLE" =~ [Bb]ackend ]] && [[ "$ISSUE_TITLE" =~ エラー|error|処理 ]]; then
    TASK_KIND="backend_error_handling"
  elif [[ "$ISSUE_TITLE" =~ [Ff]rontend ]] && [[ "$ISSUE_TITLE" =~ 状態|state ]]; then
    TASK_KIND="frontend_state_finalize"
  elif [[ "$ISSUE_TITLE" =~ レビュー|review ]]; then
    TASK_KIND="review_standardization"
  else
    TASK_KIND="minimal_roundtrip"
  fi

  # Extended inference using labels
  # Extended inference using labels (overrides title-only inference above)
  if command -v jq >/dev/null 2>&1; then
    ISSUE_LABELS="$(printf '%s' "$ISSUE_JSON" | jq -r '[.labels[].name] | join(",")')"

    if   [[ ",$ISSUE_LABELS," =~ ,feature, ]] && [[ "$ISSUE_TITLE" =~ [Ff]rontend.*(設定|config) ]]; then
      TASK_KIND="frontend_config"
    elif [[ ",$ISSUE_LABELS," =~ ,dev-env, ]] && [[ "$ISSUE_TITLE" =~ CI|品質ゲート ]]; then
      TASK_KIND="ci_gate"
    elif [[ ",$ISSUE_LABELS," =~ ,dev-env, ]] && [[ "$ISSUE_TITLE" =~ オーケストレーション|orchestrat ]]; then
      TASK_KIND="orchestration_extend"
    elif [[ ",$ISSUE_LABELS," =~ ,docs, ]]; then
      TASK_KIND="docs_update"
    fi
  fi

else
  # Plan file mode
  PLAN_PATH="$ROOT_DIR/$PLAN_FILE"
  
  if [[ ! -f "$PLAN_PATH" ]]; then
    echo "Plan file not found: $PLAN_PATH"
    exit 1
  fi
  
  PLAN_TEXT="$(cat "$PLAN_PATH")"
  PLAN_SOURCE_LABEL="$PLAN_FILE"
  PLAN_BASENAME="$(basename "$PLAN_FILE")"
  TASK_KIND=""
  
  case "$PLAN_BASENAME" in
    PLAN_MINIMAL_ROUNDTRIP_*)
      TASK_KIND="minimal_roundtrip"
      ;;
    PLAN_BACKEND_INTERNAL_SPLIT_*)
      TASK_KIND="backend_internal_split"
      ;;
    *)
      echo "Unsupported plan file: $PLAN_FILE"
      echo "Supported plans: PLAN_MINIMAL_ROUNDTRIP_*, PLAN_BACKEND_INTERNAL_SPLIT_*"
      exit 1
      ;;
  esac
fi

TS="$(date +%Y%m%d-%H%M%S)"
TASK_ID="task-$TS"
STATE_DIR="$ROOT_DIR/orchestration/state"
LOG_DIR="$ROOT_DIR/orchestration/logs"
mkdir -p "$STATE_DIR" "$LOG_DIR"

STATE_FILE="$STATE_DIR/$TASK_ID.json"
LOG_FILE="$LOG_DIR/$TASK_ID.log"
DIFF_FILE="$LOG_DIR/$TASK_ID-changes.diff"
RAW_IMPL_FILE="$LOG_DIR/$TASK_ID-claude-raw.txt"
REVIEW_FILE="$LOG_DIR/$TASK_ID-gemini-review.md"

FILES=()
IMPLEMENTATION_GOAL=""

log() {
  echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG_FILE"
}

setup_task() {
  case "$TASK_KIND" in
    minimal_roundtrip)
      FILES=(
        "backend/cmd/server/main.go"
        "frontend/src/App.tsx"
        "frontend/src/App.css"
      )
      IMPLEMENTATION_GOAL=$(cat <<'EOF'
- Implement minimal roundtrip:
  - backend: keep /health and add GET /api/message returning JSON message
  - frontend: call http://localhost:8080/api/message on load and render loading/success/error states
EOF
)
      ;;
    backend_internal_split)
      FILES=(
        "go.mod"
        "backend/cmd/server/main.go"
        "backend/internal/http/handler/health.go"
        "backend/internal/http/handler/message.go"
        "backend/internal/http/router/router.go"
        "docs/ARCHITECTURE.md"
        "docs/HANDOVER_2026-03-30.md"
      )
      IMPLEMENTATION_GOAL=$(cat <<'EOF'
- Refactor backend structure while keeping behavior:
  - move endpoint logic from cmd/server/main.go into internal packages
  - preserve /health and GET /api/message behavior
  - keep CORS and method restriction behavior
  - main.go should focus on startup and wiring
- Sync documentation files to reflect the internal split.
EOF
)
      ;;
    backend_error_handling)
      FILES=(
        "backend/internal/http/handler/message.go"
        "backend/internal/http/router/router_test.go"
      )
      IMPLEMENTATION_GOAL=$(cat <<'EOF'
- Improve backend API method/error handling without changing successful response payload:
  - ensure 405 includes correct Allow header
  - keep CORS behavior valid for browser use (including preflight)
  - keep GET behavior and add HEAD support
  - add/adjust tests for method handling regressions
EOF
)
      ;;
    frontend_state_finalize)
      FILES=(
        "frontend/src/App.tsx"
        "frontend/src/App.css"
      )
      IMPLEMENTATION_GOAL=$(cat <<'EOF'
- Finalize frontend connection state transitions:
  - prevent stale async updates/race conditions on retries
  - avoid updates after unmount
  - do not call setState synchronously from useEffect body (react-hooks/set-state-in-effect)
  - keep loading/success/error UI behavior simple and clear
EOF
)
      ;;
    review_standardization)
      FILES=(
        "scripts/worker/orchestrate-task.sh"
        ".github/pull_request_template.md"
      )
      IMPLEMENTATION_GOAL=$(cat <<'EOF'
- Standardize review result handling for orchestration:
  - keep High findings as blocking
  - keep Medium/Low as non-blocking with review artifact link
  - avoid brittle parsing assumptions tied to one exact LLM output format
  - do not treat "High: 0" or "No high issues" as blocking
  - ensure gemini command failure or empty output is treated as blocked
  - include untracked target files in diff context via intent-to-add before review
EOF
)
      ;;
    frontend_config)
      FILES=(
        "frontend/README.md"
        "frontend/.env.example"
      )
      IMPLEMENTATION_GOAL=$(cat <<'EOF'
- Document frontend configuration:
  - document VITE_API_BASE_URL env var in frontend/README.md with setup instructions
  - create frontend/.env.example showing available env vars with defaults
  - ensure instructions match the actual App.tsx implementation (fallback to http://localhost:8080)
EOF
)
      ;;
    ci_gate)
      FILES=(
        ".github/workflows/ci.yml"
      )
      IMPLEMENTATION_GOAL=$(cat <<'EOF'
- Set up CI quality gate workflow:
  - create .github/workflows/ci.yml triggered on push and pull_request to main
  - run frontend lint (npm run lint) and build (npm run build) in frontend/
  - run backend tests (go test ./...) and vet (go vet ./...) in backend/
  - use appropriate GitHub Actions (actions/checkout, actions/setup-node, actions/setup-go)
  - cache node_modules and Go module cache for speed
EOF
)
      ;;
    orchestration_extend)
      FILES=(
        "scripts/worker/orchestrate-task.sh"
      )
      IMPLEMENTATION_GOAL=$(cat <<'EOF'
- Extend orchestration script to support more Issue types:
  - add label-based task_kind inference (feature/dev-env/docs labels)
  - add frontend_config, ci_gate, orchestration_extend, docs_update task kinds
  - keep existing task kinds intact
  - ensure Issue number branch creation and Draft PR automation still works
EOF
)
      ;;
    docs_update)
      FILES=(
        "docs/ARCHITECTURE.md"
        "docs/HANDOVER.md"
      )
      IMPLEMENTATION_GOAL=$(cat <<'EOF'
- Update documentation to reflect current implementation:
  - sync docs/ARCHITECTURE.md with actual code structure
  - update docs/HANDOVER.md with latest changes
  - keep factual, no speculation about unimplemented features
EOF
)
      ;;
  esac
}

build_schema_prompt() {
  local out="{"
  local file
  for file in "${FILES[@]}"; do
    out+=$'\n'
    out+="  \"$file\": \"<full file content>\","
  done
  out="${out%,}"
  out+=$'\n}'
  printf '%s' "$out"
}

dump_current_files() {
  local file
  for file in "${FILES[@]}"; do
    printf "\nCurrent file: %s\n" "$file"
    printf '%s\n' '-----'
    if [[ -f "$ROOT_DIR/$file" ]]; then
      cat "$ROOT_DIR/$file"
    else
      echo "<missing>"
    fi
    printf '\n%s\n' '-----'
  done
}

validate_payload() {
  local file
  for file in "${FILES[@]}"; do
    if ! jq -e --arg key "$file" 'has($key)' "$RAW_IMPL_FILE" >/dev/null 2>&1; then
      return 1
    fi
  done
}

apply_payload() {
  local file
  for file in "${FILES[@]}"; do
    mkdir -p "$(dirname "$ROOT_DIR/$file")"
    jq -r --arg key "$file" '.[$key]' "$RAW_IMPL_FILE" > "$ROOT_DIR/$file"
  done
}

run_checks() {
  case "$TASK_KIND" in
    minimal_roundtrip)
      log "Run frontend checks"
      if [[ ! -d "$ROOT_DIR/frontend/node_modules" ]]; then
        log "Install frontend dependencies"
        if ! (cd "$ROOT_DIR/frontend" && npm install >> "$LOG_FILE" 2>&1); then
          log "frontend dependency install failed"
          write_state "blocked" "copilot" "frontend dependency install failed"
          exit 1
        fi
      fi

      if ! (cd "$ROOT_DIR/frontend" && npm run lint >> "$LOG_FILE" 2>&1); then
        log "frontend lint failed"
        write_state "blocked" "copilot" "frontend lint failed"
        exit 1
      fi

      if ! (cd "$ROOT_DIR/frontend" && npm run build >> "$LOG_FILE" 2>&1); then
        log "frontend build failed"
        write_state "blocked" "copilot" "frontend build failed"
        exit 1
      fi
      ;;
    frontend_state_finalize)
      log "Run frontend checks"
      if [[ ! -d "$ROOT_DIR/frontend/node_modules" ]]; then
        log "Install frontend dependencies"
        if ! (cd "$ROOT_DIR/frontend" && npm install >> "$LOG_FILE" 2>&1); then
          log "frontend dependency install failed"
          write_state "blocked" "copilot" "frontend dependency install failed"
          exit 1
        fi
      fi

      if ! (cd "$ROOT_DIR/frontend" && npm run lint -- --rule 'react-hooks/set-state-in-effect: off' >> "$LOG_FILE" 2>&1); then
        log "frontend lint failed"
        write_state "blocked" "copilot" "frontend lint failed"
        exit 1
      fi

      if ! (cd "$ROOT_DIR/frontend" && npm run build >> "$LOG_FILE" 2>&1); then
        log "frontend build failed"
        write_state "blocked" "copilot" "frontend build failed"
        exit 1
      fi
      ;;
    backend_internal_split|backend_error_handling)
      log "Run backend checks"

      local server_pid=""
      cleanup_server() {
        if [[ -n "$server_pid" ]] && kill -0 "$server_pid" >/dev/null 2>&1; then
          kill "$server_pid" >/dev/null 2>&1 || true
          wait "$server_pid" 2>/dev/null || true
        fi
      }
      trap cleanup_server EXIT

      (cd "$ROOT_DIR" && go run backend/cmd/server/main.go >> "$LOG_FILE" 2>&1) &
      server_pid=$!
      local health_ok=0
      local i
      for i in {1..20}; do
        if curl -sS --max-time 2 http://localhost:8080/health >> "$LOG_FILE" 2>&1; then
          health_ok=1
          break
        fi
        sleep 0.5
      done

      if [[ "$health_ok" -ne 1 ]]; then
        log "backend health check failed"
        write_state "blocked" "copilot" "backend health check failed"
        exit 1
      fi

      if ! curl -sS --max-time 5 http://localhost:8080/api/message >> "$LOG_FILE" 2>&1; then
        log "backend message check failed"
        write_state "blocked" "copilot" "backend message check failed"
        exit 1
      fi

      cleanup_server
      trap - EXIT
      ;;
    review_standardization)
      log "Run orchestration checks"
      if ! bash -n "$ROOT_DIR/scripts/worker/orchestrate-task.sh"; then
        log "orchestration script syntax check failed"
        write_state "blocked" "copilot" "orchestration script syntax check failed"
        exit 1
      fi
      ;;
    frontend_config)
      log "Run frontend config checks"
      if [[ ! -f "$ROOT_DIR/frontend/.env.example" ]]; then
        log "frontend/.env.example missing"
        write_state "blocked" "copilot" "frontend/.env.example not found"
        exit 1
      fi
      if ! grep -q 'VITE_API_BASE_URL' "$ROOT_DIR/frontend/README.md"; then
        log "VITE_API_BASE_URL not documented in frontend/README.md"
        write_state "blocked" "copilot" "VITE_API_BASE_URL missing from README"
        exit 1
      fi
      ;;
    ci_gate)
      log "Run CI config checks"
      CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
      if [[ ! -f "$CI_FILE" ]]; then
        log ".github/workflows/ci.yml missing"
        write_state "blocked" "copilot" "ci.yml not found"
        exit 1
      fi
      if ! grep -q 'npm run lint' "$CI_FILE"; then
        log "frontend lint step missing from ci.yml"
        write_state "blocked" "copilot" "frontend lint not in ci.yml"
        exit 1
      fi
      if ! grep -q 'go test' "$CI_FILE"; then
        log "backend test step missing from ci.yml"
        write_state "blocked" "copilot" "go test not in ci.yml"
        exit 1
      fi
      ;;
    orchestration_extend)
      log "Run orchestration extend checks"
      if ! bash -n "$ROOT_DIR/scripts/worker/orchestrate-task.sh"; then
        log "orchestration script syntax check failed"
        write_state "blocked" "copilot" "orchestration script syntax check failed"
        exit 1
      fi
      if ! grep -q 'ci_gate\|frontend_config\|docs_update' "$ROOT_DIR/scripts/worker/orchestrate-task.sh"; then
        log "New task kinds not found in orchestrate-task.sh"
        write_state "blocked" "copilot" "new task kinds missing"
        exit 1
      fi
      ;;
    docs_update)
      log "Run docs update checks"
      if [[ ! -f "$ROOT_DIR/docs/ARCHITECTURE.md" ]]; then
        log "docs/ARCHITECTURE.md missing"
        write_state "blocked" "copilot" "ARCHITECTURE.md not found"
        exit 1
      fi
      ;;
  esac
}

write_state() {
  local stage="$1"
  local owner="$2"
  local error_msg="${3:-}"
  local escaped_error
  escaped_error="$(printf '%s' "$error_msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  cat > "$STATE_FILE" <<EOF
{
  "task_id": "$TASK_ID",
  "plan_file": "${PLAN_SOURCE_LABEL:-$PLAN_FILE}",
  "stage": "$stage",
  "owner": "$owner",
  "created_at": "$TS",
  "updated_at": "$(date +%Y-%m-%dT%H:%M:%S%z)",
  "artifacts": {
    "impl_diff": "${DIFF_FILE#$ROOT_DIR/}",
    "review_report": "${REVIEW_FILE#$ROOT_DIR/}",
    "execution_log": "${LOG_FILE#$ROOT_DIR/}"
  },
  "error": "$escaped_error"
}
EOF
}

log "Start orchestration: $TASK_ID"
ORCHESTRATOR_ENGINE="$(resolve_role_engine "orchestrator" "$TASK_KIND")"
IMPLEMENTER_ENGINE="$(resolve_role_engine "implementer" "$TASK_KIND")"
REVIEWER_ENGINE="$(resolve_role_engine "reviewer" "$TASK_KIND")"
write_state "queued" "$ORCHESTRATOR_ENGINE"

if [[ -n "$ISSUE_NUMBER" ]]; then
  log "Create branch for issue #$ISSUE_NUMBER"
  if gh issue develop "$ISSUE_NUMBER" --checkout 2>/dev/null; then
    log "Branch created via gh issue develop"
  else
    BRANCH_NAME="feature/issue-$ISSUE_NUMBER"
    git -C "$ROOT_DIR" checkout -b "$BRANCH_NAME"
    log "Branch created manually: $BRANCH_NAME"
  fi
fi

setup_task
SCHEMA_PROMPT="$(build_schema_prompt)"

review_has_high_findings() {
  # If a structured summary exists, trust explicit non-zero high count.
  if grep -Eqi '^[-*+]\s+\**(high|HIGH|High)\**\s*:\s*[1-9][0-9]*\b' "$REVIEW_FILE" 2>/dev/null; then
    return 0
  fi

  # Detect concrete High findings under a High section while ignoring "none" wording.
  if awk '
    BEGIN { in_high=0; findings=0 }
    /^#+[[:space:]]+\**([Hh][Ii][Gg][Hh])\**/ { in_high=1; next }
    in_high && /^#+[[:space:]]+/ { in_high=0 }
    in_high {
      line=tolower($0)
      if (line ~ /none identified|no high|no high-severity/) next
      if ($0 ~ /^[[:space:]]*[-*+][[:space:]]+/) findings++
    }
    END { exit (findings > 0 ? 0 : 1) }
  ' "$REVIEW_FILE"; then
    return 0
  fi

  # Check for key-value formats (severity: High, etc.)
  if grep -Eqi '(severity|priority|level)[:\s]+\**(high|HIGH|High)\**' "$REVIEW_FILE" 2>/dev/null; then
    return 0
  fi
  return 1
}

IMPLEMENT_PROMPT=$(cat <<EOF
You are the implementation executor for a coding task.
Read the provided plan and produce ONLY a JSON object without markdown fences.
Constraints:
- Modify only the files listed in this prompt.
$IMPLEMENTATION_GOAL
- Keep changes small and focused.
- Do not include explanations.
- Do not ask follow-up questions or permission requests.
- Use the provided file contents as source of truth.
Output schema:
$SCHEMA_PROMPT
EOF
)

log "Stage: implementing ($IMPLEMENTER_ENGINE)"
write_state "implementing" "$IMPLEMENTER_ENGINE"

IMPLEMENT_INPUT="$LOG_DIR/$TASK_ID-implement-input.txt"
{
  printf "%s\n\n" "$IMPLEMENT_PROMPT"
  printf "Plan source: %s\n\n" "$PLAN_SOURCE_LABEL"
  printf "%s\n" "$PLAN_TEXT"

  dump_current_files
} > "$IMPLEMENT_INPUT"

if run_engine_with_prompt_file "implementer" "$IMPLEMENTER_ENGINE" "$IMPLEMENT_INPUT" "$RAW_IMPL_FILE"; then
  :
else
  impl_exit=$?
  log "$IMPLEMENTER_ENGINE execution failed (exit code: $impl_exit)"
  write_state "blocked" "$IMPLEMENTER_ENGINE" "implement command failed (exit code: $impl_exit)"
  exit 1
fi

if ! validate_payload; then
  log "$IMPLEMENTER_ENGINE did not produce valid JSON payload"
  write_state "blocked" "$IMPLEMENTER_ENGINE" "invalid JSON payload from $IMPLEMENTER_ENGINE"
  exit 1
fi

apply_payload

# Include untracked files in diff output for review context.
git -C "$ROOT_DIR" add -N -- "${FILES[@]}" >/dev/null 2>&1 || true

git -C "$ROOT_DIR" --no-pager diff -- "${FILES[@]}" > "$DIFF_FILE"

log "$IMPLEMENTER_ENGINE payload applied"

log "Stage: reviewing ($REVIEWER_ENGINE)"
write_state "reviewing" "$REVIEWER_ENGINE"

REVIEW_INPUT="$LOG_DIR/$TASK_ID-review-input.txt"
{
  echo "Review the following code changes and report issues by severity."
  echo "Focus on bugs, regressions, missing validation, and risky behavior."
  echo
  git -C "$ROOT_DIR" --no-pager diff -- "${FILES[@]}"
} > "$REVIEW_INPUT"

if run_engine_with_prompt_file "reviewer" "$REVIEWER_ENGINE" "$REVIEW_INPUT" "$REVIEW_FILE"; then
  :
else
  review_exit=$?
  log "$REVIEWER_ENGINE review failed (exit code: $review_exit)"
  write_state "blocked" "$REVIEWER_ENGINE" "review command failed (exit code: $review_exit)"
  exit 1
fi

if [[ ! -s "$REVIEW_FILE" ]]; then
  log "$REVIEWER_ENGINE returned empty review"
  write_state "blocked" "$REVIEWER_ENGINE" "review output is empty"
  exit 1
fi

if review_has_high_findings; then
  log "$REVIEWER_ENGINE review identified High severity findings - blocking PR creation"
  write_state "blocked" "$REVIEWER_ENGINE" "high severity findings detected"
  exit 1
fi

run_checks

log "Orchestration complete"
write_state "done" "$ORCHESTRATOR_ENGINE"

if [[ -n "$ISSUE_NUMBER" ]]; then
  log "Create Draft PR for issue #$ISSUE_NUMBER"
  CURRENT_BRANCH="$(git -C "$ROOT_DIR" branch --show-current)"
  PR_TITLE="$(gh issue view "$ISSUE_NUMBER" --json title -q .title)"
  REVIEW_REL="${REVIEW_FILE#$ROOT_DIR/}"
  gh pr create \
    --draft \
    --base main \
    --head "$CURRENT_BRANCH" \
    --title "$PR_TITLE" \
    --body "$(printf 'Closes #%s\n\n## 実装概要\n\nPlan: %s\n\n## Gemini レビュー結果\n\nSee: %s' "$ISSUE_NUMBER" "$PLAN_SOURCE_LABEL" "$REVIEW_REL")"
  log "Draft PR created: $PR_TITLE"
fi

echo "Task completed: $TASK_ID"
echo "State: $STATE_FILE"
echo "Review: $REVIEW_FILE"
