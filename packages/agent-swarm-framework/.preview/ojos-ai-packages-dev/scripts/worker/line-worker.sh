#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/../orchestration/runtime"
PID_DIR="$RUNTIME_DIR/pids"
ROOT_DIR="$SCRIPT_DIR/.."

line_id=""
interval="15"
once="false"
max_retries="${LINE_WORKER_MAX_RETRIES:-${WORKER_MAX_RETRIES:-3}}"
mesh_pull_enabled="${LINE_WORKER_MESH_PULL:-true}"
mesh_pull_interval="${LINE_WORKER_MESH_PULL_INTERVAL:-120}"
last_mesh_pull_epoch=0

usage() {
  cat <<'EOF'
usage: ./scripts/line-worker.sh --line <line-id> [--interval <sec>] [--once]

example line-id: auto-001
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --line)
      line_id="$2"
      shift 2
      ;;
    --interval)
      interval="$2"
      shift 2
      ;;
    --once)
      once="true"
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

if [[ -z "$line_id" || ! "$line_id" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "error: --line must match ^[a-z0-9][a-z0-9-]*$" >&2
  exit 1
fi

mkdir -p "$RUNTIME_DIR" "$PID_DIR"

QUEUE_FILE="$RUNTIME_DIR/line-${line_id}-queue.jsonl"
QUEUE_LOCK_FILE="$RUNTIME_DIR/line-${line_id}-queue.lock"
PROCESSED_FILE="$RUNTIME_DIR/line-${line_id}-processed.ids"
EVENT_FILE="$RUNTIME_DIR/line-${line_id}-events.jsonl"
PROCESS_LOG="$RUNTIME_DIR/line-${line_id}-process.log"
PID_FILE="$PID_DIR/line-${line_id}-worker.pid"
WORKTREE_DIR="$RUNTIME_DIR/worktrees/line-${line_id}"
ATTEMPT_FILE="$RUNTIME_DIR/line-${line_id}-attempts.tsv"
DEAD_LETTER_FILE="$RUNTIME_DIR/line-${line_id}-dead-letter.jsonl"
MESH_LOCK_FILE="$RUNTIME_DIR/mesh-pull.lock"
MESH_ACTIVE_FILE="$RUNTIME_DIR/line-${line_id}-mesh-active.issue"

ensure_single_instance() {
  if [[ -f "$PID_FILE" ]]; then
    local existing_pid
    existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "error: line-worker already running for ${line_id} (pid=${existing_pid})" >&2
      exit 1
    fi
  fi
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

touch "$QUEUE_FILE" "$PROCESSED_FILE" "$EVENT_FILE" "$PROCESS_LOG" "$ATTEMPT_FILE" "$DEAD_LETTER_FILE"
ensure_single_instance
printf '%s\n' "$BASHPID" >"$PID_FILE"

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_process() {
  printf '[%s] %s\n' "$(now_iso)" "$1" >>"$PROCESS_LOG"
}

log_event() {
  local command="$1"
  local scope="$2"
  local note="$3"

  printf '{"timestamp":"%s","line":"%s","issuer":"line-worker","command":"%s","scope":"%s","event_type":"worker_executed","state":"unchanged","note":"%s"}\n' \
    "$(now_iso)" "$line_id" "$command" "$scope" "$note" >>"$EVENT_FILE"
}

priority_rank_from_body() {
  local body="$1"
  local raw
  raw="$(printf '%s\n' "$body" | awk -F':' '/^priority:[[:space:]]*/ {sub(/^priority:[[:space:]]*/, ""); print; exit}' | tr '[:lower:]' '[:upper:]')"
  case "$raw" in
    P0|HIGH) echo 0 ;;
    P1) echo 1 ;;
    P2|MEDIUM) echo 2 ;;
    P3|LOW) echo 3 ;;
    *) echo 5 ;;
  esac
}

dep_numbers_from_body() {
  local body="$1"
  local refs line_refs
  refs="$(awk '/^##[[:space:]]+依存/ {in_dep=1; next} /^##[[:space:]]+/ {if (in_dep) exit} {if (in_dep) print}' <<<"$body" | grep -oE '#[0-9]+' | tr -d '#' | xargs echo 2>/dev/null || true)"
  line_refs="$(printf '%s\n' "$body" | awk -F':' '/^depends-on:[[:space:]]*/ {sub(/^depends-on:[[:space:]]*/, ""); print; exit}' | grep -oE '[0-9]+' | xargs echo 2>/dev/null || true)"
  if [[ -n "$line_refs" ]]; then
    echo "$line_refs"
    return
  fi
  echo "$refs"
}

deps_closed_for_issue() {
  local body="$1"
  local open_issue_numbers="$2"
  local dep
  for dep in $(dep_numbers_from_body "$body"); do
    [[ -z "$dep" ]] && continue
    if printf '%s\n' "$open_issue_numbers" | grep -Fxq "$dep"; then
      return 1
    fi
  done
  return 0
}

select_mesh_candidate_issue() {
  local best_issue=""
  local best_rank=999
  local best_number=999999
  local row decoded issue_number body rank blocked
  local open_issue_numbers

  open_issue_numbers="$(cd "$ROOT_DIR" && gh issue list --state open --limit 500 --json number --jq '.[].number' 2>/dev/null || true)"

  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    decoded="$(printf '%s' "$row" | base64 -d)"
    issue_number="$(printf '%s' "$decoded" | jq -r '.number')"
    body="$(printf '%s' "$decoded" | jq -r '.body // ""')"
    blocked="$(printf '%s' "$decoded" | jq -r '[.labels[].name] | any(. == "blocked")')"

    if [[ "$blocked" == "true" ]]; then
      continue
    fi

    if ! deps_closed_for_issue "$body" "$open_issue_numbers"; then
      continue
    fi

    rank="$(priority_rank_from_body "$body")"
    if (( rank < best_rank )) || { (( rank == best_rank )) && (( issue_number < best_number )); }; then
      best_issue="$issue_number"
      best_rank="$rank"
      best_number="$issue_number"
    fi
  done < <(cd "$ROOT_DIR" && gh issue list --state open --label line-task --limit 50 --json number,body,labels --jq '.[] | @base64' 2>/dev/null || true)

  if [[ -n "$best_issue" ]]; then
    echo "$best_issue"
  fi
}

enqueue_mesh_pull_action() {
  local issue_number="$1"
  local mesh_event_id
  local lock_fd
  mesh_event_id="mesh-${line_id}-${issue_number}-$(date -u +%s)"
  exec {lock_fd}>"$QUEUE_LOCK_FILE"
  flock "$lock_fd"
  printf '%s\n' "$(jq -nc --arg id "$mesh_event_id" --arg scope "issue:#${issue_number}" --argjson issueNumber "$issue_number" '{id:$id, issuer:"line-worker", command:"/mesh-pull", scope:$scope, options:{issueNumber:$issueNumber, execute:true}}')" >>"$QUEUE_FILE"
  exec {lock_fd}>&-
}

claim_issue_for_line() {
  local issue_number="$1"
  local claim_token="$2"
  local first_claim

  if ! (cd "$ROOT_DIR" && gh issue comment "$issue_number" --body "mesh_claimed_by: line:${line_id} token:${claim_token}" >/dev/null 2>&1); then
    return 1
  fi

  first_claim="$(cd "$ROOT_DIR" && gh issue view "$issue_number" --json comments --jq '.comments[].body // ""' 2>/dev/null | grep '^mesh_claimed_by: line:' | head -n 1 || true)"
  if [[ -z "$first_claim" ]]; then
    return 1
  fi

  if printf '%s' "$first_claim" | grep -Fq "token:${claim_token}"; then
    return 0
  fi

  return 1
}

mesh_pull_once() {
  local current_issue issue_number state now claim_token

  if [[ "$mesh_pull_enabled" != "true" ]]; then
    return 0
  fi

  now="$(date -u +%s)"
  if [[ "$mesh_pull_interval" =~ ^[0-9]+$ ]] && (( now - last_mesh_pull_epoch < mesh_pull_interval )); then
    return 0
  fi
  last_mesh_pull_epoch="$now"

  if [[ -s "$QUEUE_FILE" ]]; then
    return 0
  fi

  if [[ -f "$MESH_ACTIVE_FILE" ]]; then
    current_issue="$(cat "$MESH_ACTIVE_FILE" 2>/dev/null || true)"
    if [[ -n "$current_issue" ]]; then
      state="$(cd "$ROOT_DIR" && gh issue view "$current_issue" --json state --jq '.state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")"
      if [[ "$state" != "CLOSED" ]]; then
        if [[ ! -s "$QUEUE_FILE" ]]; then
          enqueue_mesh_pull_action "$current_issue"
        fi
        return 0
      fi
    fi
    rm -f "$MESH_ACTIVE_FILE"
  fi

  exec {mesh_lock_fd}>"$MESH_LOCK_FILE"
  if ! flock -n "$mesh_lock_fd"; then
    exec {mesh_lock_fd}>&-
    return 0
  fi

  issue_number="$(select_mesh_candidate_issue)"
  if [[ -z "$issue_number" ]]; then
    exec {mesh_lock_fd}>&-
    return 0
  fi

  claim_token="${line_id}-$(date -u +%s)-$$"
  if claim_issue_for_line "$issue_number" "$claim_token"; then
    printf '%s\n' "$issue_number" >"$MESH_ACTIVE_FILE"
    enqueue_mesh_pull_action "$issue_number"
    log_process "mesh-pull claimed issue=#${issue_number} line=${line_id}"
    log_event "/mesh-pull" "issue:#${issue_number}" "line worker claimed backlog issue via mesh pull"
  else
    log_process "mesh-pull skipped: lost claim race issue=#${issue_number} line=${line_id}"
  fi

  exec {mesh_lock_fd}>&-
}

handle_mesh_pull_action() {
  local line="$1"
  local issue_number
  local dispatch_script
  issue_number="$(json_field "$line" '.options.issueNumber // empty')"
  if [[ -z "$issue_number" || ! "$issue_number" =~ ^[0-9]+$ ]]; then
    log_process "mesh-pull action skipped: missing issueNumber"
    return 1
  fi

  dispatch_script="$(dispatch_script_path)"
  if [[ -n "$dispatch_script" ]]; then
    if "$dispatch_script" --issuer orchestrator --action "/backlog" --scope "issue:#${issue_number}" --options "{\"execute\":true,\"comment\":\"mesh picked by line:${line_id}\"}" >/dev/null 2>&1; then
      log_process "mesh-pull notified orchestrator: issue=#${issue_number}"
      return 0
    fi
  fi

  log_process "mesh-pull notification failed: issue=#${issue_number}"
  return 1
}

json_field() {
  local line="$1"
  local jq_expr="$2"
  printf '%s' "$line" | jq -r "$jq_expr" 2>/dev/null || true
}

ensure_worktree() {
  local branch="$1"
  local base="$2"
  local attempt=1
  local max_attempts=5

  mkdir -p "$RUNTIME_DIR/worktrees"

  if [[ -d "$WORKTREE_DIR/.git" || -f "$WORKTREE_DIR/.git" ]]; then
    git -C "$ROOT_DIR" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
  fi

  # If git metadata still remains, forcefully clean stale worktree directory.
  if [[ -e "$WORKTREE_DIR" ]]; then
    rm -rf "$WORKTREE_DIR" >/dev/null 2>&1 || true
  fi

  git -C "$ROOT_DIR" worktree prune >/dev/null 2>&1 || true

  git -C "$ROOT_DIR" fetch origin >/dev/null 2>&1 || true

  # Parallel line workers may contend on .git/config lock.
  while (( attempt <= max_attempts )); do
    if git -C "$ROOT_DIR" worktree add -B "$branch" "$WORKTREE_DIR" "origin/$base" >/dev/null 2>&1; then
      break
    fi
    sleep 1
    attempt=$((attempt + 1))
  done

  if [[ ! -d "$WORKTREE_DIR" ]]; then
    log_process "implement failed: could not prepare worktree branch=$branch base=$base"
    return 1
  fi
}

run_implement_action() {
  local line="$1"
  local branch base commit_message pr_title pr_body task_command

  branch="$(json_field "$line" '.options.branch // empty')"
  base="$(json_field "$line" '.options.base // "main"')"
  commit_message="$(json_field "$line" '.options.commitMessage // empty')"
  pr_title="$(json_field "$line" '.options.prTitle // empty')"
  pr_body="$(json_field "$line" '.options.prBody // "Automated PR by line worker"')"
  task_command="$(json_field "$line" '.options.taskCommand // empty')"

  if [[ -z "$branch" || -z "$commit_message" || -z "$pr_title" || -z "$task_command" ]]; then
    log_process "implement skipped: missing required options (branch/commitMessage/prTitle/taskCommand)"
    return 1
  fi

  if ! ensure_worktree "$branch" "$base"; then
    return 1
  fi

  if ! (cd "$WORKTREE_DIR" && bash -lc "$task_command"); then
    log_process "implement failed: task command failed branch=$branch"
    return 1
  fi

  (cd "$WORKTREE_DIR" && git add -A)

  if (cd "$WORKTREE_DIR" && git diff --cached --quiet); then
    log_process "implement no-op: no file changes branch=$branch"
    return 0
  fi

  (cd "$WORKTREE_DIR" && git commit -m "$commit_message" >/dev/null)
  (cd "$WORKTREE_DIR" && git push -u origin "$branch" >/dev/null)

  local pr_url
  pr_url="$(cd "$WORKTREE_DIR" && gh pr create --base "$base" --head "$branch" --title "$pr_title" --body "$pr_body" 2>/dev/null || true)"
  if [[ -n "$pr_url" ]]; then
    log_process "implement completed: branch=$branch pr=$pr_url"
  else
    log_process "implement completed: branch=$branch (pr create skipped/failed)"
  fi

  return 0
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

action_id_from_line() {
  local line="$1"
  local id
  id="$(printf '%s' "$line" | jq -r '.routed_id // .id // empty' 2>/dev/null || true)"
  if [[ -n "$id" ]]; then
    printf '%s' "$id"
    return
  fi

  printf '%s' "$line" | sha1sum | awk '{print "action-"$1}'
}

handle_action() {
  local line="$1"
  local command scope
  command="$(json_field "$line" '.command // ""')"
  scope="$(json_field "$line" '.scope // ""')"

  case "$command" in
    "/implement")
      if run_implement_action "$line"; then
        log_event "$command" "$scope" "line worker implemented task and attempted PR creation"
        return 0
      else
        log_event "$command" "$scope" "line worker failed or skipped implement action"
        return 1
      fi
      ;;
    "/mesh-pull")
      if handle_mesh_pull_action "$line"; then
        log_event "$command" "$scope" "mesh pull claim was forwarded to orchestrator"
        return 0
      else
        log_event "$command" "$scope" "mesh pull claim forwarding failed"
        return 1
      fi
      ;;
    *)
      log_process "handled command=$command scope=$scope"
      log_event "$command" "$scope" "line worker observed routed action"
      return 0
      ;;
  esac
}

process_once() {
  [[ -f "$QUEUE_FILE" ]] || return 0

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
  process_once
  mesh_pull_once

  if [[ "$once" == "true" ]]; then
    break
  fi

  sleep "$interval"
done

log_process "worker stopped"
