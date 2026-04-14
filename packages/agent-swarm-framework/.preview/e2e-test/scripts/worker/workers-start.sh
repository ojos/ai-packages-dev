#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/../orchestration/runtime"
PID_DIR="$RUNTIME_DIR/pids"
LINE_SCALER="$SCRIPT_DIR/line-workers-scale.sh"

interval="15"

usage() {
  cat <<'EOF'
usage: ./scripts/workers-start.sh [--interval <sec>]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      interval="$2"
      shift 2
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

start_worker() {
  local name="$1"
  local cmd="$2"
  local pid_file="$PID_DIR/${name}.pid"
  local log_file="$RUNTIME_DIR/${name}.stdout.log"

  if [[ -f "$pid_file" ]]; then
    local existing_pid
    existing_pid="$(cat "$pid_file")"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "already running: $name (pid=$existing_pid)"
      return
    fi
  fi

  nohup bash -lc "$cmd" >>"$log_file" 2>&1 &
  local pid=$!
  echo "$pid" >"$pid_file"
  echo "started: $name (pid=$pid)"
}

start_worker "worker-coordinator" "$SCRIPT_DIR/worker-coordinator.sh --interval $interval"
start_worker "orchestrator-worker" "$SCRIPT_DIR/orchestrator-worker.sh --interval $interval"
start_worker "closer-worker" "$SCRIPT_DIR/closer-worker.sh --interval $interval"

initial_count="${INITIAL_LINE_WORKERS:-2}"
WORKER_INTERVAL="$interval" "$LINE_SCALER" --count "$initial_count"
