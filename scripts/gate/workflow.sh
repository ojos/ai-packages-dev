#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/../orchestration/runtime"
PID_DIR="$RUNTIME_DIR/pids"
SLOTS_FILE="$RUNTIME_DIR/line-worker-slots.json"

DISPATCH="$SCRIPT_DIR/command-dispatch.sh"
WORKERS_START="$SCRIPT_DIR/workers-start.sh"
WORKERS_STOP="$SCRIPT_DIR/workers-stop.sh"
DEAD_LETTER="$SCRIPT_DIR/worker-dead-letter.sh"

subcommand=""
interval="15"
line="all"
worker=""
mode=""
limit="20"
dead_id=""
dry_run="false"

usage() {
  cat <<'EOF'
usage: ./scripts/workflow.sh <up|down|restart|status|dead-letter> [options]

subcommands:
  up       Start worker processes and set logical state to running (all)
  down     Set logical state to stopped (all) and stop worker processes
  restart  down + up
  status   Show unified logical/worker health
  dead-letter  List or replay dead-letter entries

options:
  --interval <sec>   Worker poll interval for up/restart (default: 15)
  --line <all|line-id> status target line (default: all)
  --worker <line-<id>|line:<id>|closer|orchestrator> dead-letter target worker
  --mode <list|replay> dead-letter mode
  --limit <n>      dead-letter list limit (default: 20)
  --id <dead_id>   dead-letter replay target id
  --dry-run        dead-letter replay dry-run
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

subcommand="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      interval="$2"
      shift 2
      ;;
    --line)
      line="$2"
      shift 2
      ;;
    --worker)
      worker="$2"
      shift 2
      ;;
    --mode)
      mode="$2"
      shift 2
      ;;
    --limit)
      limit="$2"
      shift 2
      ;;
    --id)
      dead_id="$2"
      shift 2
      ;;
    --dry-run)
      dry_run="true"
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

ensure_runtime() {
  mkdir -p "$RUNTIME_DIR" "$PID_DIR"
}

logical_state() {
  local line_id="$1"
  local state_file="$RUNTIME_DIR/line-states.json"

  if [[ ! -f "$state_file" ]]; then
    echo "unknown"
    return
  fi

  local s
  s="$(jq -r --arg l "$line_id" '.lines[$l] // .all // "unknown"' "$state_file" 2>/dev/null || echo "unknown")"
  echo "$s"
}

worker_state() {
  local line_id="$1"
  local pid_file="$PID_DIR/line-${line_id}-worker.pid"

  if [[ ! -f "$pid_file" ]]; then
    echo "stopped"
    return
  fi

  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"

  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "running"
  else
    echo "stopped"
  fi
}

queue_size() {
  local line_id="$1"
  local q="$RUNTIME_DIR/line-${line_id}-queue.jsonl"

  if [[ ! -f "$q" ]]; then
    echo "0"
    return
  fi

  wc -l <"$q" | tr -d ' '
}

last_transition() {
  local line_id="$1"
  local e="$RUNTIME_DIR/line-${line_id}-events.jsonl"

  if [[ ! -f "$e" ]]; then
    echo "none"
    return
  fi

  local l
  l="$(tail -n 1 "$e" 2>/dev/null || true)"
  [[ -z "$l" ]] && echo "none" && return

  printf '%s' "$l" | jq -r '"\(.timestamp) \(.command) \(.event_type) \(.state)"' 2>/dev/null || echo "none"
}

health_state() {
  local logical="$1"
  local worker="$2"

  if [[ "$logical" == "running" && "$worker" == "running" ]]; then
    echo "healthy"
    return
  fi

  if [[ "$logical" == "stopped" && "$worker" == "stopped" ]]; then
    echo "stopped"
    return
  fi

  if [[ "$logical" == "running" && "$worker" == "stopped" ]]; then
    echo "degraded"
    return
  fi

  if [[ "$logical" == "stopped" && "$worker" == "running" ]]; then
    echo "mismatch"
    return
  fi

  echo "unknown"
}

show_status() {
  local targets
  local state_file
  state_file="$RUNTIME_DIR/line-states.json"

  case "$line" in
    all)
      if [[ -f "$SLOTS_FILE" ]]; then
        targets="$(jq -r '.slots[]?' "$SLOTS_FILE" 2>/dev/null | xargs echo)"
      elif [[ -f "$state_file" ]]; then
        targets="$(jq -r '.lines | keys[]?' "$state_file" 2>/dev/null | xargs echo)"
      else
        targets=""
      fi

      if [[ -z "$targets" ]]; then
        targets="auto-001"
      fi
      ;;
    *) targets="$line" ;;
  esac

  if [[ -z "$targets" ]]; then
    echo "error: no line targets available" >&2
    exit 1
  fi

  echo 'line | logical_state | worker_state | health | queue_size | last_transition'

  local line_id logical worker health queue transition
  for line_id in $targets; do
    logical="$(logical_state "$line_id")"
    worker="$(worker_state "$line_id")"
    health="$(health_state "$logical" "$worker")"
    queue="$(queue_size "$line_id")"
    transition="$(last_transition "$line_id")"

    printf '%s | %s | %s | %s | %s | %s\n' \
      "$line_id" \
      "$logical" \
      "$worker" \
      "$health" \
      "$queue" \
      "$transition"
  done
}

run_up() {
  ensure_runtime
  "$WORKERS_START" --interval "$interval"
  "$DISPATCH" --issuer orchestrator --action "/start" --scope all
  echo "workflow up completed"
}

run_down() {
  ensure_runtime
  "$DISPATCH" --issuer orchestrator --action "/stop" --scope all
  "$WORKERS_STOP"
  echo "workflow down completed"
}

run_restart() {
  run_down
  run_up
}

run_dead_letter() {
  if [[ -z "$worker" || -z "$mode" ]]; then
    echo "error: dead-letter requires --worker and --mode" >&2
    exit 1
  fi

  cmd=("$DEAD_LETTER" "$mode" "--worker" "$worker" "--limit" "$limit")

  if [[ -n "$dead_id" ]]; then
    cmd+=("--id" "$dead_id")
  fi

  if [[ "$dry_run" == "true" ]]; then
    cmd+=("--dry-run")
  fi

  "${cmd[@]}"
}

case "$subcommand" in
  up)
    run_up
    ;;
  down)
    run_down
    ;;
  restart)
    run_restart
    ;;
  dead-letter)
    run_dead_letter
    ;;
  status)
    show_status
    ;;
  *)
    echo "error: unknown subcommand: $subcommand" >&2
    usage
    exit 1
    ;;
esac
