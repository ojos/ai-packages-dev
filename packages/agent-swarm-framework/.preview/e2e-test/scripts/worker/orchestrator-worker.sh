#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
RUNTIME_DIR="$SCRIPT_DIR/../orchestration/runtime"
PID_DIR="$RUNTIME_DIR/pids"
LINE_SCALER="$SCRIPT_DIR/line-workers-scale.sh"
LINE_STATE_FILE="$RUNTIME_DIR/line-states.json"
SLOTS_FILE="$RUNTIME_DIR/line-worker-slots.json"

interval="15"
once="false"
auto_execute="false"
max_retries="${ORCHESTRATOR_WORKER_MAX_RETRIES:-${WORKER_MAX_RETRIES:-3}}"
scale_interval_seconds="${ORCHESTRATOR_SCALE_INTERVAL_SECONDS:-60}"
event_driven_scale="${ORCHESTRATOR_EVENT_DRIVEN:-true}"
max_line_workers="${MAX_LINE_WORKERS:-4}"
last_scaled_epoch=0
project_number="${ORCHESTRATOR_PROJECT_NUMBER:-2}"

REPO_FULL_NAME_CACHE=""
PROJECT_CACHE_INITIALIZED="false"
PROJECT_OWNER_CACHE=""
PROJECT_ID_CACHE=""
PROJECT_STATUS_FIELD_ID=""
PROJECT_LINE_FIELD_ID=""
PROJECT_PRIORITY_FIELD_ID=""
PROJECT_BATCH_ID_FIELD_ID=""
PROJECT_BLOCKED_BY_FIELD_ID=""
PROJECT_NEXT_ACTION_FIELD_ID=""
PROJECT_DUE_DATE_FIELD_ID=""
PROJECT_OWNER_ROLE_FIELD_ID=""
PROJECT_STATUS_TODO_OPTION_ID=""

usage() {
  cat <<'EOF'
usage: ./scripts/orchestrator-worker.sh [--interval <sec>] [--once] [--auto-execute]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      interval="$2"
      shift 2
      ;;
    --once)
      once="true"
      shift
      ;;
    --auto-execute)
      auto_execute="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

mkdir -p "$RUNTIME_DIR" "$PID_DIR"

QUEUE_FILE="$RUNTIME_DIR/orchestrator-queue.jsonl"
QUEUE_LOCK_FILE="$RUNTIME_DIR/orchestrator-queue.lock"
PROCESSED_FILE="$RUNTIME_DIR/orchestrator-processed.ids"
PROCESS_LOG="$RUNTIME_DIR/orchestrator-process.log"
PID_FILE="$PID_DIR/orchestrator-worker.pid"
ATTEMPT_FILE="$RUNTIME_DIR/orchestrator-attempts.tsv"
DEAD_LETTER_FILE="$RUNTIME_DIR/orchestrator-dead-letter.jsonl"
DECOMPOSE_QUEUE_FILE="$RUNTIME_DIR/orchestrator-decompose-queued.ids"
DECOMPOSE_DONE_FILE="$RUNTIME_DIR/orchestrator-decompose-done.ids"
CONSULT_STATE_FILE="$RUNTIME_DIR/consult-state.json"
CONSULT_GUARD_FILE="$RUNTIME_DIR/consult-guard.json"

ensure_single_instance() {
  if [[ -f "$PID_FILE" ]]; then
    local existing_pid
    existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "error: orchestrator-worker already running (pid=${existing_pid})" >&2
      exit 1
    fi
  fi
}

touch "$QUEUE_FILE" "$PROCESSED_FILE" "$PROCESS_LOG" "$ATTEMPT_FILE" "$DEAD_LETTER_FILE" "$DECOMPOSE_QUEUE_FILE" "$DECOMPOSE_DONE_FILE"
ensure_single_instance
printf '%s\n' "$BASHPID" >"$PID_FILE"

if [[ ! "$scale_interval_seconds" =~ ^[0-9]+$ ]]; then
  scale_interval_seconds=60
fi

if [[ ! "$max_line_workers" =~ ^[0-9]+$ ]]; then
  max_line_workers=4
fi

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_process() {
  printf '[%s] %s\n' "$(now_iso)" "$1" >>"$PROCESS_LOG"
}

now_epoch() {
  date -u +%s
}

repo_full_name() {
  if [[ -n "$REPO_FULL_NAME_CACHE" ]]; then
    printf '%s' "$REPO_FULL_NAME_CACHE"
    return 0
  fi

  REPO_FULL_NAME_CACHE="$(cd "$ROOT_DIR" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  printf '%s' "$REPO_FULL_NAME_CACHE"
}

project_owner() {
  cd "$ROOT_DIR" && gh repo view --json owner -q .owner.login 2>/dev/null || true
}

project_id_by_number() {
  local owner="$1"
  local number="$2"
  cd "$ROOT_DIR" && gh project list --owner "$owner" --limit 100 --format json --jq ".projects[] | select(.number==$number) | .id" 2>/dev/null | head -n 1
}

project_field_id() {
  local owner="$1"
  local number="$2"
  local field_name="$3"
  cd "$ROOT_DIR" && gh project field-list "$number" --owner "$owner" --format json --jq ".fields[] | select(.name==\"$field_name\") | .id" 2>/dev/null | head -n 1
}

project_single_select_option_id() {
  local owner="$1"
  local number="$2"
  local field_name="$3"
  local option_name="$4"
  cd "$ROOT_DIR" && gh project field-list "$number" --owner "$owner" --format json --jq ".fields[] | select(.name==\"$field_name\") | .options[]? | select(.name==\"$option_name\") | .id" 2>/dev/null | head -n 1
}

project_item_id_by_issue_number() {
  local owner="$1"
  local number="$2"
  local issue_number="$3"
  cd "$ROOT_DIR" && gh project item-list "$number" --owner "$owner" --limit 500 --format json --jq ".items[] | select(.content.number==$issue_number) | .id" 2>/dev/null | head -n 1
}

retry_project_item_id() {
  local owner="$1"
  local number="$2"
  local issue_number="$3"
  local max_attempts="${4:-10}"
  local sleep_sec="${5:-1}"
  local i item_id

  for ((i=1; i<=max_attempts; i++)); do
    item_id="$(project_item_id_by_issue_number "$owner" "$number" "$issue_number")"
    if [[ -n "$item_id" ]]; then
      printf '%s' "$item_id"
      return 0
    fi
    sleep "$sleep_sec"
  done

  return 1
}

project_set_text_field() {
  local item_id="$1"
  local project_id="$2"
  local field_id="$3"
  local value="$4"
  [[ -z "$item_id" || -z "$project_id" || -z "$field_id" || -z "$value" ]] && return 1
  cd "$ROOT_DIR" && gh project item-edit --id "$item_id" --project-id "$project_id" --field-id "$field_id" --text "$value" >/dev/null
}

project_set_date_field() {
  local item_id="$1"
  local project_id="$2"
  local field_id="$3"
  local value="$4"
  [[ -z "$item_id" || -z "$project_id" || -z "$field_id" || -z "$value" ]] && return 1
  cd "$ROOT_DIR" && gh project item-edit --id "$item_id" --project-id "$project_id" --field-id "$field_id" --date "$value" >/dev/null
}

project_set_single_select_field() {
  local item_id="$1"
  local project_id="$2"
  local field_id="$3"
  local option_id="$4"
  [[ -z "$item_id" || -z "$project_id" || -z "$field_id" || -z "$option_id" ]] && return 1
  cd "$ROOT_DIR" && gh project item-edit --id "$item_id" --project-id "$project_id" --field-id "$field_id" --single-select-option-id "$option_id" >/dev/null
}

project_init_cache() {
  if [[ "$PROJECT_CACHE_INITIALIZED" == "true" ]]; then
    return 0
  fi

  PROJECT_OWNER_CACHE="$(project_owner)"
  [[ -z "$PROJECT_OWNER_CACHE" ]] && return 1

  PROJECT_ID_CACHE="$(project_id_by_number "$PROJECT_OWNER_CACHE" "$project_number")"
  [[ -z "$PROJECT_ID_CACHE" ]] && return 1

  PROJECT_STATUS_FIELD_ID="$(project_field_id "$PROJECT_OWNER_CACHE" "$project_number" "Status")"
  PROJECT_LINE_FIELD_ID="$(project_field_id "$PROJECT_OWNER_CACHE" "$project_number" "Line")"
  PROJECT_PRIORITY_FIELD_ID="$(project_field_id "$PROJECT_OWNER_CACHE" "$project_number" "Priority")"
  PROJECT_BATCH_ID_FIELD_ID="$(project_field_id "$PROJECT_OWNER_CACHE" "$project_number" "Batch ID")"
  PROJECT_BLOCKED_BY_FIELD_ID="$(project_field_id "$PROJECT_OWNER_CACHE" "$project_number" "Blocked By")"
  PROJECT_NEXT_ACTION_FIELD_ID="$(project_field_id "$PROJECT_OWNER_CACHE" "$project_number" "Next Action")"
  PROJECT_DUE_DATE_FIELD_ID="$(project_field_id "$PROJECT_OWNER_CACHE" "$project_number" "Due Date")"
  PROJECT_OWNER_ROLE_FIELD_ID="$(project_field_id "$PROJECT_OWNER_CACHE" "$project_number" "Owner Role")"
  PROJECT_STATUS_TODO_OPTION_ID="$(project_single_select_option_id "$PROJECT_OWNER_CACHE" "$project_number" "Status" "To Do")"
  if [[ -z "$PROJECT_STATUS_TODO_OPTION_ID" ]]; then
    PROJECT_STATUS_TODO_OPTION_ID="$(project_single_select_option_id "$PROJECT_OWNER_CACHE" "$project_number" "Status" "Todo")"
  fi

  PROJECT_CACHE_INITIALIZED="true"
  return 0
}

priority_from_issue() {
  local issue_number="$1"
  local body raw
  body="$(cd "$ROOT_DIR" && gh issue view "$issue_number" --json body --jq '.body // ""' 2>/dev/null || true)"
  raw="$(printf '%s\n' "$body" | awk -F':' '/^priority:[[:space:]]*/ {sub(/^priority:[[:space:]]*/, ""); print; exit}')"
  raw="$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')"
  case "$raw" in
    P0|HIGH) echo "High" ;;
    P1) echo "High" ;;
    P2|MEDIUM) echo "Medium" ;;
    P3|LOW) echo "Low" ;;
    *) echo "Medium" ;;
  esac
}

detect_project_scale() {
  local issue_number="$1"
  local title body haystack
  title="$(cd "$ROOT_DIR" && gh issue view "$issue_number" --json title --jq '.title // ""' 2>/dev/null || true)"
  body="$(cd "$ROOT_DIR" && gh issue view "$issue_number" --json body --jq '.body // ""' 2>/dev/null || true)"
  haystack="$(printf '%s %s' "$title" "$body" | tr '[:upper:]' '[:lower:]')"

  if printf '%s' "$haystack" | grep -Eq '(\[l\]|\blarge\b)'; then
    echo "Large"
    return
  fi
  if printf '%s' "$haystack" | grep -Eq '(\[m\]|\bstandard\b|\bmedium\b)'; then
    echo "Standard"
    return
  fi
  echo "Small"
}

calculate_due_date() {
  local priority="$1"
  local scale="$2"
  local days="2"

  case "$scale:$priority" in
    Small:High) days=1 ;;
    Small:Medium) days=2 ;;
    Small:Low) days=4 ;;
    Standard:High) days=2 ;;
    Standard:Medium) days=3 ;;
    Standard:Low) days=7 ;;
    Large:High) days=3 ;;
    Large:Medium) days=5 ;;
    Large:Low) days=10 ;;
  esac

  date -u -d "+${days} day" +"%Y-%m-%d"
}

batch_id_from_issue() {
  local issue_number="$1"
  cd "$ROOT_DIR" && gh issue view "$issue_number" --json labels --jq '.labels[].name' 2>/dev/null | sed -n 's/^intake-batch://p' | head -n 1
}

blocked_by_from_issue() {
  local issue_number="$1"
  local body refs line_refs
  body="$(cd "$ROOT_DIR" && gh issue view "$issue_number" --json body --jq '.body // ""' 2>/dev/null || true)"
  refs="$(awk '/^##[[:space:]]+依存/ {in_dep=1; next} /^##[[:space:]]+/ {if (in_dep) exit} {if (in_dep) print}' <<<"$body" | grep -oE '#[0-9]+' | tr -d '#' | paste -sd',' - 2>/dev/null || true)"
  line_refs="$(printf '%s\n' "$body" | awk -F':' '/^depends-on:[[:space:]]*/ {sub(/^depends-on:[[:space:]]*/, ""); print; exit}' | grep -oE '[0-9]+' | paste -sd',' - 2>/dev/null || true)"
  if [[ -n "$line_refs" ]]; then
    echo "$line_refs"
    return
  fi
  echo "$refs"
}

extract_next_action() {
  local kind="$1"
  case "$kind" in
    intake) echo "decompose" ;;
    milestone|line) echo "implement" ;;
    *) echo "implement" ;;
  esac
}

extract_owner_role() {
  local kind="$1"
  case "$kind" in
    intake) echo "Intake Manager" ;;
    milestone) echo "Coordinator" ;;
    line) echo "Line Worker" ;;
    *) echo "Coordinator" ;;
  esac
}

project_owner_role_option_id() {
  local role="$1"
  project_single_select_option_id "$PROJECT_OWNER_CACHE" "$project_number" "Owner Role" "$role"
}

project_priority_option_id() {
  local priority="$1"
  project_single_select_option_id "$PROJECT_OWNER_CACHE" "$project_number" "Priority" "$priority"
}

project_line_option_id() {
  local line_value="$1"
  project_single_select_option_id "$PROJECT_OWNER_CACHE" "$project_number" "Line" "$line_value"
}

populate_project_fields() {
  local project_issue_number="$1"
  local source_issue_number="$2"
  local item_kind="$3"
  local line_value="$4"
  local item_id issue_url priority scale due_date batch_id blocked_by next_action owner_role
  local priority_option owner_role_option line_option

  project_init_cache || return 0

  issue_url="https://github.com/$(repo_full_name)/issues/$project_issue_number"
  (cd "$ROOT_DIR" && gh project item-add "$project_number" --owner "$PROJECT_OWNER_CACHE" --url "$issue_url" >/dev/null 2>&1 || true)
  if ! item_id="$(retry_project_item_id "$PROJECT_OWNER_CACHE" "$project_number" "$project_issue_number" 12 1)"; then
    log_process "project sync skipped: item not found issue=#${project_issue_number}"
    return 0
  fi

  priority="$(priority_from_issue "$source_issue_number")"
  scale="$(detect_project_scale "$source_issue_number")"
  due_date="$(calculate_due_date "$priority" "$scale")"
  batch_id="$(batch_id_from_issue "$source_issue_number")"
  blocked_by="$(blocked_by_from_issue "$source_issue_number")"
  next_action="$(extract_next_action "$item_kind")"
  owner_role="$(extract_owner_role "$item_kind")"
  priority_option="$(project_priority_option_id "$priority")"
  owner_role_option="$(project_owner_role_option_id "$owner_role")"
  line_option="$(project_line_option_id "$line_value")"

  local i ok_status="false" ok_priority="false" ok_owner="false" ok_line="false" ok_batch="false" ok_blocked="false" ok_next="false" ok_due="false"
  for ((i=1; i<=5; i++)); do
    if [[ "$ok_status" != "true" ]]; then
      project_set_single_select_field "$item_id" "$PROJECT_ID_CACHE" "$PROJECT_STATUS_FIELD_ID" "$PROJECT_STATUS_TODO_OPTION_ID" && ok_status="true" || true
    fi
    if [[ "$ok_priority" != "true" ]]; then
      project_set_single_select_field "$item_id" "$PROJECT_ID_CACHE" "$PROJECT_PRIORITY_FIELD_ID" "$priority_option" && ok_priority="true" || true
    fi
    if [[ "$ok_owner" != "true" ]]; then
      project_set_single_select_field "$item_id" "$PROJECT_ID_CACHE" "$PROJECT_OWNER_ROLE_FIELD_ID" "$owner_role_option" && ok_owner="true" || true
    fi
    if [[ "$ok_line" != "true" ]]; then
      if [[ -n "$line_option" ]]; then
        project_set_single_select_field "$item_id" "$PROJECT_ID_CACHE" "$PROJECT_LINE_FIELD_ID" "$line_option" && ok_line="true" || true
      else
        project_set_text_field "$item_id" "$PROJECT_ID_CACHE" "$PROJECT_LINE_FIELD_ID" "$line_value" && ok_line="true" || true
      fi
    fi
    if [[ "$ok_batch" != "true" ]]; then
      if [[ -n "$batch_id" ]]; then
        project_set_text_field "$item_id" "$PROJECT_ID_CACHE" "$PROJECT_BATCH_ID_FIELD_ID" "$batch_id" && ok_batch="true" || true
      else
        ok_batch="true"
      fi
    fi
    if [[ "$ok_blocked" != "true" ]]; then
      if [[ -n "$blocked_by" ]]; then
        project_set_text_field "$item_id" "$PROJECT_ID_CACHE" "$PROJECT_BLOCKED_BY_FIELD_ID" "$blocked_by" && ok_blocked="true" || true
      else
        ok_blocked="true"
      fi
    fi
    if [[ "$ok_next" != "true" ]]; then
      project_set_text_field "$item_id" "$PROJECT_ID_CACHE" "$PROJECT_NEXT_ACTION_FIELD_ID" "$next_action" && ok_next="true" || true
    fi
    if [[ "$ok_due" != "true" ]]; then
      project_set_date_field "$item_id" "$PROJECT_ID_CACHE" "$PROJECT_DUE_DATE_FIELD_ID" "$due_date" && ok_due="true" || true
    fi

    if [[ "$ok_status" == "true" && "$ok_priority" == "true" && "$ok_owner" == "true" && "$ok_line" == "true" && "$ok_batch" == "true" && "$ok_blocked" == "true" && "$ok_next" == "true" && "$ok_due" == "true" ]]; then
      break
    fi
    sleep 1
  done

  log_process "project sync: issue=#${project_issue_number} result=status:${ok_status},priority:${ok_priority},owner:${ok_owner},line:${ok_line},batch:${ok_batch},blocked:${ok_blocked},next:${ok_next},due:${ok_due}"
}

issue_dep_numbers() {
  local issue_number="$1"
  local body
  body="$(cd "$ROOT_DIR" && gh issue view "$issue_number" --json body --jq '.body // ""' 2>/dev/null || true)"

  if [[ -z "$body" ]]; then
    echo ""
    return
  fi

  awk '
    /^##[[:space:]]+依存/ {in_dep=1; next}
    /^##[[:space:]]+/ {if (in_dep) exit}
    {if (in_dep) print}
  ' <<<"$body" | grep -oE '#[0-9]+' | tr -d '#' | xargs echo 2>/dev/null || true
}

issue_stage_number() {
  local title="$1"
  if [[ "$title" =~ ^M[0-9]+-([0-9]+): ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return
  fi
  printf '999'
}

issue_state_cached() {
  local issue_number="$1"
  cd "$ROOT_DIR" && gh issue view "$issue_number" --json state --jq '.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN"
}

ensure_line_state_file() {
  if [[ ! -f "$LINE_STATE_FILE" ]]; then
    cat >"$LINE_STATE_FILE" <<'EOF'
{
  "all": "idle",
  "lines": {}
}
EOF
  fi
}

next_hotfix_line_id() {
  ensure_line_state_file

  local max_idx
  max_idx="$(jq -r '[.lines | keys[]? | select(test("^hotfix-[0-9]+$")) | capture("hotfix-(?<n>[0-9]+)").n | tonumber] | max // 0' "$LINE_STATE_FILE" 2>/dev/null || echo 0)"
  if [[ ! "$max_idx" =~ ^[0-9]+$ ]]; then
    max_idx=0
  fi

  printf 'hotfix-%03d' "$((max_idx + 1))"
}

activate_hotfix_line() {
  local line_id="$1"
  ensure_line_state_file

  local tmp desired_auto_count
  tmp="$(mktemp)"
  jq --arg line "$line_id" '.all = "running" | .lines[$line] = "running"' "$LINE_STATE_FILE" >"$tmp"
  mv "$tmp" "$LINE_STATE_FILE"

  if [[ -f "$SLOTS_FILE" ]]; then
    desired_auto_count="$(jq -r '.desired_count // 2' "$SLOTS_FILE" 2>/dev/null || echo 2)"
  else
    desired_auto_count=2
  fi

  if [[ ! "$desired_auto_count" =~ ^[0-9]+$ ]]; then
    desired_auto_count=2
  fi

  if [[ -x "$LINE_SCALER" ]]; then
    WORKER_INTERVAL="$interval" MAX_LINE_WORKERS="$max_line_workers" "$LINE_SCALER" --count "$desired_auto_count" >/dev/null 2>&1 || true
  fi
}

compute_runnable_issue_count() {
  local rows
  rows="$(cd "$ROOT_DIR" && gh issue list --state open --label feature --json number,title,milestone --limit 200 --jq '.[] | [.number, .title, (.milestone.title // "none")] | @tsv' 2>/dev/null || true)"
  local open_issue_numbers
  open_issue_numbers="$(cd "$ROOT_DIR" && gh issue list --state open --json number --limit 500 --jq '.[].number' 2>/dev/null || true)"

  if [[ -z "$rows" ]]; then
    echo 1
    return
  fi

  declare -A issue_stage issue_ms issue_dep_ok ms_min_stage
  local number title milestone stage deps dep dep_ok

  while IFS=$'\t' read -r number title milestone; do
    [[ -z "$number" ]] && continue
    stage="$(issue_stage_number "$title")"
    issue_stage["$number"]="$stage"
    issue_ms["$number"]="$milestone"

    deps="$(issue_dep_numbers "$number")"
    dep_ok="true"
    for dep in $deps; do
      [[ -z "$dep" ]] && continue
      if printf '%s\n' "$open_issue_numbers" | grep -Fxq "$dep"; then
        dep_ok="false"
        break
      fi
    done
    issue_dep_ok["$number"]="$dep_ok"

    if [[ "$dep_ok" == "true" ]]; then
      if [[ -z "${ms_min_stage[$milestone]:-}" || "$stage" -lt "${ms_min_stage[$milestone]}" ]]; then
        ms_min_stage["$milestone"]="$stage"
      fi
    fi
  done <<<"$rows"

  local runnable=0 n ms min_stage
  for n in "${!issue_stage[@]}"; do
    if [[ "${issue_dep_ok[$n]}" != "true" ]]; then
      continue
    fi
    ms="${issue_ms[$n]}"
    min_stage="${ms_min_stage[$ms]:-999}"
    if [[ "${issue_stage[$n]}" -eq "$min_stage" ]]; then
      runnable=$((runnable + 1))
    fi
  done

  if (( runnable < 1 )); then
    runnable=1
  fi

  if (( runnable > max_line_workers )); then
    runnable="$max_line_workers"
  fi

  local available_runners
  available_runners="$(available_runner_capacity)"
  if [[ "$available_runners" =~ ^[0-9]+$ ]] && (( available_runners > 0 )) && (( runnable > available_runners )); then
    runnable="$available_runners"
  fi

  echo "$runnable"
}

available_runner_capacity() {
  local capacity_file available
  capacity_file="$RUNTIME_DIR/self-hosted-capacity.json"

  if [[ -f "$capacity_file" ]]; then
    available="$(jq -r '.available_runners // empty' "$capacity_file" 2>/dev/null || true)"
    if [[ "$available" =~ ^[0-9]+$ ]]; then
      echo "$available"
      return
    fi
  fi

  echo "$max_line_workers"
}

scale_line_workers_if_needed() {
  local reason="$1"
  local now desired
  now="$(now_epoch)"

  if [[ "$reason" == "periodic" ]]; then
    if (( now - last_scaled_epoch < scale_interval_seconds )); then
      return
    fi
  elif [[ "$reason" == "event" && "$event_driven_scale" != "true" ]]; then
    return
  fi

  desired="$(compute_runnable_issue_count)"

  if [[ -x "$LINE_SCALER" ]]; then
    if WORKER_INTERVAL="$interval" MAX_LINE_WORKERS="$max_line_workers" "$LINE_SCALER" --count "$desired" >/dev/null 2>&1; then
      log_process "scaled line workers: reason=$reason desired=$desired"
      last_scaled_epoch="$now"
      return
    fi
    log_process "line worker scaling failed: reason=$reason desired=$desired"
  fi
}

json_field() {
  local line="$1"
  local jq_expr="$2"
  printf '%s' "$line" | jq -r "$jq_expr" 2>/dev/null || true
}

action_id_from_line() {
  local line="$1"
  local id
  id="$(json_field "$line" '.routed_id // .id // empty')"
  if [[ -n "$id" ]]; then
    printf '%s' "$id"
    return
  fi
  printf '%s' "$line" | sha1sum | awk '{print "action-"$1}'
}

dispatch_script_path() {
  if [[ -x "$SCRIPT_DIR/command-dispatch.sh" ]]; then
    echo "$SCRIPT_DIR/command-dispatch.sh"
    return
  fi
  if [[ -x "$SCRIPT_DIR/../gate/command-dispatch.sh" ]]; then
    echo "$SCRIPT_DIR/../gate/command-dispatch.sh"
    return
  fi
  echo ""
}

ensure_consult_guard_file() {
  if [[ ! -f "$CONSULT_GUARD_FILE" ]]; then
    cat >"$CONSULT_GUARD_FILE" <<'EOF'
{
  "paused_lines": []
}
EOF
  fi
}

guard_contains_line() {
  local line_id="$1"
  ensure_consult_guard_file
  jq -e --arg line "$line_id" '.paused_lines | index($line) != null' "$CONSULT_GUARD_FILE" >/dev/null 2>&1
}

guard_add_line() {
  local line_id="$1"
  ensure_consult_guard_file
  local tmp
  tmp="$(mktemp)"
  jq --arg line "$line_id" '.paused_lines = ((.paused_lines // []) + [$line] | unique)' "$CONSULT_GUARD_FILE" >"$tmp"
  mv "$tmp" "$CONSULT_GUARD_FILE"
}

guard_clear_lines() {
  ensure_consult_guard_file
  local tmp
  tmp="$(mktemp)"
  jq '.paused_lines = []' "$CONSULT_GUARD_FILE" >"$tmp"
  mv "$tmp" "$CONSULT_GUARD_FILE"
}

guard_lines() {
  ensure_consult_guard_file
  jq -r '.paused_lines[]?' "$CONSULT_GUARD_FILE" 2>/dev/null || true
}

consult_state_active_and_blocking() {
  [[ -f "$CONSULT_STATE_FILE" ]] || return 1
  local state blocking
  state="$(jq -r '.state // "inactive"' "$CONSULT_STATE_FILE" 2>/dev/null || echo inactive)"
  blocking="$(jq -r '.blocking // false' "$CONSULT_STATE_FILE" 2>/dev/null || echo false)"
  [[ "$state" == "active" && "$blocking" == "true" ]]
}

consult_target_lines() {
  [[ -f "$CONSULT_STATE_FILE" ]] || {
    echo "all"
    return
  }

  local lines
  lines="$(jq -r '.lines[]?' "$CONSULT_STATE_FILE" 2>/dev/null | xargs echo)"
  if [[ -z "$lines" ]]; then
    echo "all"
  else
    echo "$lines"
  fi
}

dispatch_control_action() {
  local command="$1"
  local target_scope="$2"
  local dispatch_script
  dispatch_script="$(dispatch_script_path)"
  [[ -n "$dispatch_script" ]] || return 1

  bash "$dispatch_script" --issuer orchestrator --action "$command" --scope "$target_scope" --options '{"execute":true}' >/dev/null 2>&1
}

sync_blocking_consult_guard() {
  local line_id
  if consult_state_active_and_blocking; then
    for line_id in $(consult_target_lines); do
      if guard_contains_line "$line_id"; then
        continue
      fi

      if [[ "$line_id" == "all" ]]; then
        if dispatch_control_action "/pause" "all"; then
          guard_add_line "all"
          log_process "consult blocking: paused scope=all"
        else
          log_process "consult blocking: failed to pause scope=all"
        fi
      else
        if dispatch_control_action "/pause" "line:${line_id}"; then
          guard_add_line "$line_id"
          log_process "consult blocking: paused line=${line_id}"
        else
          log_process "consult blocking: failed to pause line=${line_id}"
        fi
      fi
    done
    return
  fi

  for line_id in $(guard_lines); do
    if [[ "$line_id" == "all" ]]; then
      if dispatch_control_action "/resume" "all"; then
        log_process "consult unblock: resumed scope=all"
      else
        log_process "consult unblock: failed to resume scope=all"
      fi
    else
      if dispatch_control_action "/resume" "line:${line_id}"; then
        log_process "consult unblock: resumed line=${line_id}"
      else
        log_process "consult unblock: failed to resume line=${line_id}"
      fi
    fi
  done
  guard_clear_lines
}

already_processed() {
  local id="$1"
  grep -Fxq "$id" "$PROCESSED_FILE"
}

mark_processed() {
  local id="$1"
  printf '%s\n' "$id" >>"$PROCESSED_FILE"
}

attempt_count() {
  local id="$1"
  awk -v key="$id" '$1==key {count=$2} END {print count+0}' "$ATTEMPT_FILE"
}

set_attempt_count() {
  local id="$1"
  local count="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v key="$id" '$1!=key {print $0}' "$ATTEMPT_FILE" >"$tmp"
  printf '%s\t%s\n' "$id" "$count" >>"$tmp"
  mv "$tmp" "$ATTEMPT_FILE"
}

clear_attempt_count() {
  local id="$1"
  local tmp
  tmp="$(mktemp)"
  awk -v key="$id" '$1!=key {print $0}' "$ATTEMPT_FILE" >"$tmp"
  mv "$tmp" "$ATTEMPT_FILE"
}

append_dead_letter() {
  local id="$1"
  local attempts="$2"
  local reason="$3"
  local line="$4"

  if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$line" | jq -c --arg id "$id" --arg failedAt "$(now_iso)" --arg reason "$reason" --argjson attempts "$attempts" '. + {dead_letter_id:$id, failed_at:$failedAt, failure_reason:$reason, attempts:$attempts}' >>"$DEAD_LETTER_FILE"
    return
  fi

  printf '{"dead_letter_id":"%s","failed_at":"%s","failure_reason":"%s","attempts":%s,"raw":"%s"}\n' \
    "$id" "$(now_iso)" "$reason" "$attempts" "$(printf '%s' "$line" | sed 's/"/\\"/g')" >>"$DEAD_LETTER_FILE"
}

extract_issue_number() {
  local scope="$1"
  if [[ "$scope" =~ ^issue:#?([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  if [[ "$scope" =~ ^#?([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

issue_has_label() {
  local issue_number="$1"
  local label_name="$2"
  (cd "$ROOT_DIR" && gh issue view "$issue_number" --json labels --jq '.labels[].name' 2>/dev/null | grep -Fxq "$label_name")
}

issue_has_type_marker() {
  local issue_number="$1"
  (cd "$ROOT_DIR" && gh issue view "$issue_number" --json body --jq '.body // ""' 2>/dev/null | grep -q 'type:[[:space:]]*orchestrator-intake')
}

is_valid_intake_issue() {
  local issue_number="$1"
  issue_has_type_marker "$issue_number" && issue_has_label "$issue_number" "orchestrator-intake"
}

issue_marker_exists() {
  local issue_number="$1"
  local marker="$2"
  (cd "$ROOT_DIR" && gh issue view "$issue_number" --json comments --jq '.comments[].body // ""' 2>/dev/null | grep -Fq "$marker")
}

decompose_queue_contains() {
  local issue_number="$1"
  grep -Fxq "$issue_number" "$DECOMPOSE_QUEUE_FILE"
}

decompose_queue_add() {
  local issue_number="$1"
  decompose_queue_contains "$issue_number" || printf '%s\n' "$issue_number" >>"$DECOMPOSE_QUEUE_FILE"
}

decompose_queue_remove() {
  local issue_number="$1"
  local tmp
  tmp="$(mktemp)"
  awk -v n="$issue_number" '$0!=n {print $0}' "$DECOMPOSE_QUEUE_FILE" >"$tmp"
  mv "$tmp" "$DECOMPOSE_QUEUE_FILE"
}

decompose_done_contains() {
  local issue_number="$1"
  grep -Fxq "$issue_number" "$DECOMPOSE_DONE_FILE"
}

decompose_done_add() {
  local issue_number="$1"
  decompose_done_contains "$issue_number" || printf '%s\n' "$issue_number" >>"$DECOMPOSE_DONE_FILE"
}

short_goal_from_issue() {
  local issue_number="$1"
  local body title goal
  body="$(cd "$ROOT_DIR" && gh issue view "$issue_number" --json body --jq '.body // ""' 2>/dev/null || true)"
  title="$(cd "$ROOT_DIR" && gh issue view "$issue_number" --json title --jq '.title // ""' 2>/dev/null || true)"

  goal="$(printf '%s\n' "$body" | awk -F':' '/^goal:[[:space:]]*/ {sub(/^goal:[[:space:]]*/, ""); print; exit}')"
  if [[ -z "$goal" ]]; then
    goal="$title"
  fi

  printf '%s' "$goal" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-72
}

create_issue() {
  local title="$1"
  local body="$2"
  local labels_csv="$3"

  local -a label_args
  local label
  IFS=',' read -r -a labels < <(printf '%s' "$labels_csv")
  for label in "${labels[@]}"; do
    label="$(printf '%s' "$label" | tr -d '\r\n' | xargs)"
    [[ -z "$label" ]] && continue
    label_args+=("--label" "$label")
  done

  cd "$ROOT_DIR" && gh issue create --title "$title" --body "$body" "${label_args[@]}"
}

find_issue_url_by_title_and_label() {
  local title="$1"
  local label="$2"
  cd "$ROOT_DIR" && gh issue list --state all --label "$label" --search "$title in:title" --json title,url --limit 50 --jq --arg t "$title" '.[] | select(.title == $t) | .url' 2>/dev/null | head -n 1
}

find_or_create_issue() {
  local title="$1"
  local body="$2"
  local labels_csv="$3"
  local primary_label existing_url

  primary_label="$(printf '%s' "$labels_csv" | cut -d',' -f1)"
  if [[ -n "$primary_label" ]]; then
    existing_url="$(find_issue_url_by_title_and_label "$title" "$primary_label")"
    if [[ -n "$existing_url" ]]; then
      printf '%s' "$existing_url"
      return 0
    fi
  fi

  create_issue "$title" "$body" "$labels_csv"
}

create_decomposition_issues() {
  local intake_issue_number="$1"
  local marker marker_queued milestone_title goal marker_text milestone_url milestone_number line_url line_title line target_lines
  local milestone_body line_body intake_comment_body
  local lock_file

  lock_file="$RUNTIME_DIR/decompose-intake-${intake_issue_number}.lock"
  exec {decompose_lock_fd}>"$lock_file"
  if ! flock -n "$decompose_lock_fd"; then
    log_process "skip decompose: lock busy intake issue #$intake_issue_number"
    exec {decompose_lock_fd}>&-
    return 0
  fi

  marker="decompose_completed_for_intake:#${intake_issue_number}"
  marker_queued="decompose_queued_for_intake:#${intake_issue_number}"
  if decompose_done_contains "$intake_issue_number"; then
    log_process "skip decompose: local done guard intake issue #$intake_issue_number"
    exec {decompose_lock_fd}>&-
    return 0
  fi
  if issue_marker_exists "$intake_issue_number" "$marker"; then
    decompose_done_add "$intake_issue_number"
    log_process "skip decompose: already processed intake issue #$intake_issue_number"
    exec {decompose_lock_fd}>&-
    return 0
  fi

  if ! is_valid_intake_issue "$intake_issue_number"; then
    log_process "ignored_invalid_intake: issue=#$intake_issue_number"
    exec {decompose_lock_fd}>&-
    return 0
  fi

  goal="$(short_goal_from_issue "$intake_issue_number")"
  milestone_title="INTAKE-${intake_issue_number} ${goal}"
  marker_text=""

  populate_project_fields "$intake_issue_number" "$intake_issue_number" "intake" "" || true

  milestone_body="Generated by orchestrator-worker from intake #$intake_issue_number

source_issue: #$intake_issue_number
type: milestone-breakdown"
  milestone_url="$(find_or_create_issue "$milestone_title" "$milestone_body" "from-intake,milestone-task")"
  milestone_number="$(printf '%s' "$milestone_url" | sed -E 's#^.*/issues/([0-9]+)$#\1#')"
  populate_project_fields "$milestone_number" "$intake_issue_number" "milestone" "milestone" || true

  target_lines="$(decompose_target_lines)"
  for line in $target_lines; do
    line_title="LINE-${line} [INTAKE-${intake_issue_number}] ${goal}"
    line_body="Generated by orchestrator-worker from intake #$intake_issue_number

parent_milestone_issue: #$milestone_number
source_issue: #$intake_issue_number
line: $line"
    line_url="$(find_or_create_issue "$line_title" "$line_body" "line-task,from-intake")"
    local line_number
    line_number="$(printf '%s' "$line_url" | sed -E 's#^.*/issues/([0-9]+)$#\1#')"
    populate_project_fields "$line_number" "$intake_issue_number" "line" "$line" || true
    marker_text+=$'\n'
    marker_text+="- ${line}: ${line_url}"
  done

  intake_comment_body="${marker}

created_milestone: ${milestone_url}${marker_text}"
  cd "$ROOT_DIR" && gh issue comment "$intake_issue_number" --body "$intake_comment_body" >/dev/null
  decompose_queue_remove "$intake_issue_number"
  decompose_done_add "$intake_issue_number"
  log_process "decompose completed: intake=#$intake_issue_number milestone=#$milestone_number"
  exec {decompose_lock_fd}>&-
}

decompose_target_lines() {
  local slots=()

  if [[ -f "$SLOTS_FILE" ]]; then
    mapfile -t slots < <(jq -r '.slots[]?' "$SLOTS_FILE" 2>/dev/null | grep -E '^auto-[0-9]{3}$' || true)
  fi

  if (( ${#slots[@]} == 0 )); then
    # Default slots when slot state is not initialized.
    printf 'auto-001 auto-002'
    return
  fi

  printf '%s\n' "${slots[@]}" | xargs echo
}

should_execute() {
  local line="$1"
  local opt_exec env_exec
  opt_exec="$(json_field "$line" '.options.execute // false')"
  env_exec="${ORCHESTRATOR_AUTO_EXECUTE:-false}"
  if [[ "$auto_execute" == "true" || "$env_exec" == "true" || "$opt_exec" == "true" ]]; then
    return 0
  fi
  return 1
}

handle_issue_action() {
  local command="$1"
  local scope="$2"
  local line="$3"
  local issue_number hotfix_line

  if ! issue_number="$(extract_issue_number "$scope")"; then
    log_process "invalid issue scope: command=$command scope=$scope"
    return 1
  fi

  if should_execute "$line"; then
    local body
    body="$(json_field "$line" '.options.comment // empty')"

    if [[ "$command" == "/hotfix" ]]; then
      hotfix_line="$(json_field "$line" '.options.hotfixLine // empty')"
      if [[ -z "$hotfix_line" ]]; then
        hotfix_line="$(next_hotfix_line_id)"
      fi
      activate_hotfix_line "$hotfix_line"

      if [[ -z "$body" ]]; then
        body="orchestrator-worker executed $command for $scope"
      fi

      body="${body}\n\nallocated_line: line:${hotfix_line}\nstate: running"
    fi

    if [[ -z "$body" ]]; then
      body="orchestrator-worker executed $command for $scope"
    fi

    if (cd "$ROOT_DIR" && gh issue comment "$issue_number" --body "$body" >/dev/null); then
      log_process "executed orchestrator action: command=$command scope=$scope"
      return 0
    fi

    log_process "failed orchestrator action: command=$command scope=$scope"
    return 1
  fi

  log_process "planned orchestrator action: command=$command scope=$scope"
  return 0
}

handle_intake_or_decompose() {
  local command="$1"
  local scope="$2"
  local issue_number

  # Normalize command format (handle_intake → /intake, decompose → /decompose)
  if [[ "$command" == "handle_intake" ]]; then
    command="/intake"
  elif [[ "$command" == "decompose" ]]; then
    command="/decompose"
  fi

  if ! issue_number="$(extract_issue_number "$scope")"; then
    log_process "invalid intake scope: command=$command scope=$scope"
    return 1
  fi

  if [[ "$command" == "/intake" ]]; then
    if ! is_valid_intake_issue "$issue_number"; then
      log_process "ignored_invalid_intake: issue=#$issue_number"
      return 0
    fi

    if issue_marker_exists "$issue_number" "decompose_completed_for_intake:#${issue_number}"; then
      decompose_done_add "$issue_number"
      log_process "intake skipped: already decomposed issue=#$issue_number"
      return 0
    fi
    if decompose_done_contains "$issue_number"; then
      log_process "intake skipped: local done guard issue=#$issue_number"
      return 0
    fi
    if issue_marker_exists "$issue_number" "decompose_queued_for_intake:#${issue_number}"; then
      decompose_queue_add "$issue_number"
      log_process "intake skipped: already queued issue=#$issue_number"
      return 0
    fi
    if decompose_queue_contains "$issue_number"; then
      log_process "intake skipped: local queue guard issue=#$issue_number"
      return 0
    fi

    # intake受領時に同一issueへ decompose を自動キュー投入
    local dispatch_script
    dispatch_script="$(dispatch_script_path)"
    if [[ -n "$dispatch_script" ]] && bash "$dispatch_script" --issuer orchestrator --action "/decompose" --scope "issue:#$issue_number" --options '{"execute":true}' >/dev/null 2>&1; then
      cd "$ROOT_DIR" && gh issue comment "$issue_number" --body "decompose_queued_for_intake:#${issue_number}" >/dev/null || true
      decompose_queue_add "$issue_number"
      log_process "intake accepted and decompose queued: issue=#$issue_number"
      return 0
    fi

    log_process "intake accepted but decompose queue failed: issue=#$issue_number"
    return 1
  fi

  if [[ "$command" == "/decompose" ]]; then
    create_decomposition_issues "$issue_number"
    return $?
  fi

  return 0
}

handle_action() {
  local line="$1"
  local command scope
  command="$(json_field "$line" '.command // ""')"
  scope="$(json_field "$line" '.scope // ""')"

  case "$command" in
    "/intake"|"handle_intake"|"/decompose"|"decompose")
      handle_intake_or_decompose "$command" "$scope"
      ;;
    "/add line"|"/reassign"|"/escalate"|"/hotfix"|"/backlog")
      handle_issue_action "$command" "$scope" "$line"
      ;;
    "/consult"|"/log"|"/apply"|"/defer")
      log_process "handled consult action: command=$command scope=$scope"
      return 0
      ;;
    *)
      log_process "unhandled orchestrator command: command=$command scope=$scope"
      return 0
      ;;
  esac
}

process_once() {
  [[ -f "$QUEUE_FILE" ]] || return 0

  local processed_any="false"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local id
    id="$(action_id_from_line "$line")"

    if already_processed "$id"; then
      continue
    fi

    if handle_action "$line"; then
      mark_processed "$id"
      clear_attempt_count "$id"
      processed_any="true"
      continue
    fi

    local attempts
    attempts="$(( $(attempt_count "$id") + 1 ))"
    set_attempt_count "$id" "$attempts"

    if (( attempts > max_retries )); then
      append_dead_letter "$id" "$attempts" "action_failed" "$line"
      mark_processed "$id"
      clear_attempt_count "$id"
      log_process "dead-lettered id=$id attempts=$attempts"
    else
      log_process "retry scheduled id=$id attempt=$attempts/$max_retries"
    fi
  done <"$QUEUE_FILE"

  if [[ "$processed_any" == "true" ]]; then
    scale_line_workers_if_needed "event"
  fi

  compact_queue_file
}

compact_queue_file() {
  local tmp_queue
  local lock_fd
  tmp_queue="$(mktemp)"
  exec {lock_fd}>"$QUEUE_LOCK_FILE"
  flock "$lock_fd"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local id
    id="$(action_id_from_line "$line")"
    if ! already_processed "$id"; then
      printf '%s\n' "$line" >>"$tmp_queue"
    fi
  done <"$QUEUE_FILE"

  mv "$tmp_queue" "$QUEUE_FILE"
  exec {lock_fd}>&-
}

log_process "worker started"

while true; do
  sync_blocking_consult_guard
  process_once
  scale_line_workers_if_needed "periodic"

  if [[ "$once" == "true" ]]; then
    break
  fi

  sleep "$interval"
done

log_process "worker stopped"
