#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
HOOK_NAME="${1:-unknown-hook}"
MARKER_FILE="$ROOT_DIR/scripts/orchestration/runtime/asf-last-run.json"
MAX_AGE_SECONDS="${ASF_ENFORCE_MAX_AGE_SECONDS:-43200}"

if [[ "${ASF_ENFORCE_BYPASS:-false}" == "true" ]]; then
  echo "[asf-enforce] bypassed by ASF_ENFORCE_BYPASS=true"
  exit 0
fi

if [[ ! -f "$ROOT_DIR/.agent-swarm-framework.config.json" ]]; then
  exit 0
fi

if [[ ! "$MAX_AGE_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "[asf-enforce] invalid ASF_ENFORCE_MAX_AGE_SECONDS: $MAX_AGE_SECONDS" >&2
  exit 2
fi

if [[ ! -f "$MARKER_FILE" ]]; then
  echo "[asf-enforce] blocked by $HOOK_NAME: ASF marker missing" >&2
  echo "[asf-enforce] run: bash scripts/asf-workflow.sh preflight" >&2
  exit 2
fi

ts="$(jq -r '.timestamp // empty' "$MARKER_FILE" 2>/dev/null || true)"
cmd="$(jq -r '.command // empty' "$MARKER_FILE" 2>/dev/null || true)"

if [[ -z "$ts" || -z "$cmd" ]]; then
  echo "[asf-enforce] blocked by $HOOK_NAME: ASF marker is invalid" >&2
  echo "[asf-enforce] run: bash scripts/asf-workflow.sh preflight" >&2
  exit 2
fi

marker_epoch="$(date -u -d "$ts" +%s 2>/dev/null || true)"
now_epoch="$(date -u +%s)"
if [[ -z "$marker_epoch" ]]; then
  echo "[asf-enforce] blocked by $HOOK_NAME: ASF marker timestamp is invalid" >&2
  echo "[asf-enforce] run: bash scripts/asf-workflow.sh preflight" >&2
  exit 2
fi

age="$((now_epoch - marker_epoch))"
if (( age < 0 )); then
  age=0
fi

if (( age > MAX_AGE_SECONDS )); then
  echo "[asf-enforce] blocked by $HOOK_NAME: last ASF run is stale (${age}s > ${MAX_AGE_SECONDS}s)" >&2
  echo "[asf-enforce] run: bash scripts/asf-workflow.sh preflight" >&2
  exit 2
fi

exit 0
