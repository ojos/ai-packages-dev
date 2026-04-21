#!/usr/bin/env bash
# dashboard.sh — tput in-place terminal dashboard for ASF monitoring
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/monitor-common.sh"

RUNTIME_DIR="$ROOT_DIR/orchestration/runtime"
REFRESH="${MONITOR_DASHBOARD_INTERVAL:-3}"

# terminal cleanup on exit
_cleanup() {
  tput rmcup 2>/dev/null || true
  tput cnorm 2>/dev/null || true
}
trap _cleanup EXIT INT TERM

# helper: read queue size for a line
queue_size() {
  local line="$1"
  local qfile="$RUNTIME_DIR/line-${line}-queue.jsonl"
  [[ -f "$qfile" ]] && wc -l < "$qfile" | tr -d " " || echo "0"
}

# helper: worker state for a line
worker_state() {
  local line="$1"
  local pids_dir="$RUNTIME_DIR/pids"
  local pid_file="$pids_dir/line-${line}-worker.pid"
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      printf "running(pid=%s)" "$pid"
      return
    fi
  fi
  echo "stopped"
}

# helper: last 5 gate log lines for one line
gate_log_tail() {
  local line_id="$1"
  local logfile="$RUNTIME_DIR/line-${line_id}-events.jsonl"
  if [[ ! -f "$logfile" ]]; then
    printf "  [%s] (no gate log)\n" "$line_id"
    return
  fi
  printf "  [%s]\n" "$line_id"
  tail -5 "$logfile" | while IFS= read -r line; do
    local ts cmd note
    ts="$(printf '%s' "$line" | jq -r '.timestamp // ""')"
    cmd="$(printf '%s' "$line" | jq -r '.command // ""')"
    note="$(printf '%s' "$line" | jq -r '.note // ""' | cut -c1-60)"
    printf "  %s %s — %s\n" "$ts" "$cmd" "$note"
  done
}

# helper: open PR count
open_prs() {
  if command -v gh >/dev/null 2>&1; then
    gh pr list --json number --jq "length" 2>/dev/null || echo "?"
  else
    echo "n/a"
  fi
}

render() {
  local lines
  lines="$(runtime_line_ids 2>/dev/null || echo "auto-001 auto-002")"

  tput home 2>/dev/null || true

  printf "\033[1;36m=== ASF Terminal Dashboard ===\033[0m  (refresh: %ss  exit: Ctrl-C)\n" "$REFRESH"
  printf "updated: %s\n\n" "$(date "+%Y-%m-%d %H:%M:%S %Z")"

  printf "\033[1m[overview]\033[0m\n"
  printf "%-12s %-26s %-12s\n" "line" "worker_state" "queue_size"
  printf "%s\n" "------------------------------------------------------------"
  for line in $lines; do
    local ws qs
    ws="$(worker_state "$line")"
    qs="$(queue_size "$line")"
    printf "%-12s %-26s %-12s\n" "$line" "$ws" "$qs"
  done

  printf "\n\033[1m[open PRs]\033[0m\n"
  printf "count: %s\n" "$(open_prs)"

  printf "\n\033[1m[gate log (last 5)]\033[0m\n"
  for line in $lines; do
    gate_log_tail "$line"
  done

  tput ed 2>/dev/null || true
}

# This dashboard uses cursor movement and alternate screen, so require TTY.
if [[ ! -t 1 ]]; then
  echo "error: dashboard.sh requires an interactive terminal (TTY)." >&2
  exit 1
fi

# enter alternate screen, hide cursor
tput smcup 2>/dev/null || true
tput civis 2>/dev/null || true

while true; do
  render
  sleep "$REFRESH"
done

