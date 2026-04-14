#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PID_DIR="$SCRIPT_DIR/../orchestration/runtime/pids"

if [[ ! -d "$PID_DIR" ]]; then
  echo "no pid directory: $PID_DIR"
  exit 0
fi

for pid_file in "$PID_DIR"/*.pid; do
  [[ -f "$pid_file" ]] || continue

  pid="$(cat "$pid_file")"
  name="$(basename "$pid_file" .pid)"

  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    echo "stopped: $name (pid=$pid)"
  else
    echo "already stopped: $name"
  fi

  rm -f "$pid_file"
done

# Fallback cleanup: terminate stray worker processes that are not tracked by pid files.
stop_by_pattern() {
  local label="$1"
  local pattern="$2"
  local pids
  pids="$(pgrep -f "$pattern" || true)"
  [[ -z "$pids" ]] && return

  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    kill "$pid" 2>/dev/null || true
    echo "stopped stray: $label (pid=$pid)"
  done <<<"$pids"
}

stop_by_pattern "worker-coordinator" "/workspaces/ojos-ai-packages-dev/scripts/worker/worker-coordinator.sh"
stop_by_pattern "orchestrator-worker" "/workspaces/ojos-ai-packages-dev/scripts/worker/orchestrator-worker.sh"
stop_by_pattern "line-worker" "/workspaces/ojos-ai-packages-dev/scripts/worker/line-worker.sh --line"
stop_by_pattern "closer-worker" "/workspaces/ojos-ai-packages-dev/scripts/worker/closer-worker.sh"
