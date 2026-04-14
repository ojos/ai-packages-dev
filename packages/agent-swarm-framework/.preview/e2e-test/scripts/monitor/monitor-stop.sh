#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

patterns=(
  "$ROOT_DIR/scripts/monitor/monitor-overview.sh"
  "$ROOT_DIR/scripts/monitor/monitor-line.sh"
  "$ROOT_DIR/scripts/monitor/monitor-incident.sh"
  "$ROOT_DIR/scripts/monitor/monitor-merge-queue.sh"
  "$ROOT_DIR/scripts/gate/auto-gate.sh"
)

stopped=0
for pattern in "${patterns[@]}"; do
  if pgrep -f "$pattern" >/dev/null 2>&1; then
    pkill -f "$pattern"
    stopped=1
  fi
done

if [[ "$stopped" -eq 1 ]]; then
  echo 'monitor and auto-gate processes stopped'
else
  echo 'no monitor or auto-gate processes found'
fi