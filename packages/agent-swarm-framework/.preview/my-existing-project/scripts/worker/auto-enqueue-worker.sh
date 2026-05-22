#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/../orchestration/runtime"
PID_DIR="$RUNTIME_DIR/pids"
PID_FILE="$PID_DIR/auto-enqueue-worker.pid"
PROCESS_LOG="$RUNTIME_DIR/auto-enqueue-worker.log"
ENQUEUE_SCRIPT="$SCRIPT_DIR/auto-enqueue-issues.sh"

interval="60"
once="false"
dry_run="false"

usage() {
  cat <<'EOF'
usage: ./scripts/worker/auto-enqueue-worker.sh [--interval <sec>] [--once] [--dry-run <true|false>]
EOF
}

require_bool() {
  local value="$1"
  local name="$2"
  if [[ "$value" != "true" && "$value" != "false" ]]; then
    echo "error: $name must be true or false" >&2
    exit 1
  fi
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
    --dry-run)
      dry_run="$2"
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

require_bool "$dry_run" "--dry-run"

mkdir -p "$RUNTIME_DIR" "$PID_DIR"
touch "$PROCESS_LOG"

if [[ -f "$PID_FILE" ]]; then
  existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "error: auto-enqueue-worker already running (pid=$existing_pid)" >&2
    exit 1
  fi
fi

printf '%s\n' "$BASHPID" >"$PID_FILE"

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_line() {
  printf '[%s] %s\n' "$(now_iso)" "$1" >>"$PROCESS_LOG"
}

if [[ ! -x "$ENQUEUE_SCRIPT" ]]; then
  log_line "enqueue script missing: $ENQUEUE_SCRIPT"
  exit 1
fi

log_line "auto-enqueue worker started"

while true; do
  if [[ "$dry_run" == "true" ]]; then
    "$ENQUEUE_SCRIPT" --dry-run true >>"$PROCESS_LOG" 2>&1 || true
  else
    "$ENQUEUE_SCRIPT" >>"$PROCESS_LOG" 2>&1 || true
  fi

  if [[ "$once" == "true" ]]; then
    break
  fi

  sleep "$interval"
done

log_line "auto-enqueue worker stopped"
