#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/../orchestration/runtime"
QUEUE_FILE="$RUNTIME_DIR/pending-actions.jsonl"
PROCESSED_FILE="$RUNTIME_DIR/coordinator-processed.ids"
COORDINATOR_LOG="$RUNTIME_DIR/worker-coordinator.log"
PID_DIR="$RUNTIME_DIR/pids"
PID_FILE="$PID_DIR/worker-coordinator.pid"
SLOTS_FILE="$RUNTIME_DIR/line-worker-slots.json"

interval="15"
once="false"

usage() {
  cat <<'EOF'
usage: ./scripts/worker-coordinator.sh [--interval <sec>] [--once]
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
touch "$PROCESSED_FILE" "$COORDINATOR_LOG"

printf '%s\n' "$BASHPID" >"$PID_FILE"

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_line() {
  printf '[%s] %s\n' "$(now_iso)" "$1" >>"$COORDINATOR_LOG"
}

action_id_from_line() {
  local line="$1"
  local id
  id="$(printf '%s' "$line" | jq -r '.id // empty' 2>/dev/null || true)"
  if [[ -n "$id" ]]; then
    printf '%s' "$id"
    return
  fi

  printf '%s' "$line" | sha1sum | awk '{print "action-"$1}'
}

already_processed() {
  local id="$1"
  grep -Fxq "$id" "$PROCESSED_FILE"
}

mark_processed() {
  local id="$1"
  printf '%s\n' "$id" >>"$PROCESSED_FILE"
}

infer_target_from_scope() {
  local command="$1"
  local scope="$2"
  local line_id

  case "$scope" in
    all)
      if [[ -f "$SLOTS_FILE" ]]; then
        local dyn_targets
        dyn_targets="$(jq -r '.slots[]? | "line-" + .' "$SLOTS_FILE" 2>/dev/null | xargs echo)"
        if [[ -n "$dyn_targets" ]]; then
          echo "$dyn_targets"
        else
          echo "line-auto-001"
        fi
      else
        echo "line-auto-001"
      fi
      return
      ;;
    line:*)
      line_id="${scope#line:}"
      if [[ "$line_id" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        echo "line-${line_id}"
      else
        echo "orchestrator"
      fi
      return
      ;;
    pr:#*)
      echo "closer"
      return
      ;;
    issue:#*)
      echo "orchestrator"
      return
      ;;
    consult|plan)
      echo "orchestrator"
      return
      ;;
  esac

  case "$command" in
    "/review"|"/merge"|"/close pr") echo "closer" ;;
    *) echo "orchestrator" ;;
  esac
}

append_target_queue() {
  local target="$1"
  local line="$2"
  local id="$3"
  local lock_file lock_fd

  local target_file
  target_file="$RUNTIME_DIR/${target}-queue.jsonl"
  lock_file="$RUNTIME_DIR/${target}-queue.lock"
  exec {lock_fd}>"$lock_file"
  flock "$lock_fd"
  printf '%s\n' "$line" | jq -c --arg routedAt "$(now_iso)" --arg target "$target" --arg id "$id" '. + {routed_at:$routedAt, target:$target, routed_id:$id}' >>"$target_file"
  exec {lock_fd}>&-
}

process_once() {
  [[ -f "$QUEUE_FILE" ]] || return 0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local id scope command targets target
    id="$(action_id_from_line "$line")"

    if already_processed "$id"; then
      continue
    fi

    scope="$(printf '%s' "$line" | jq -r '.scope // ""' 2>/dev/null || true)"
    command="$(printf '%s' "$line" | jq -r '.command // ""' 2>/dev/null || true)"
    targets="$(infer_target_from_scope "$command" "$scope")"

    for target in $targets; do
      append_target_queue "$target" "$line" "$id"
      log_line "routed id=$id command=$command scope=$scope target=$target"
    done

    mark_processed "$id"
  done <"$QUEUE_FILE"
}

while true; do
  process_once

  if [[ "$once" == "true" ]]; then
    break
  fi

  sleep "$interval"
done
