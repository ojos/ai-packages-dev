#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

STRICT="false"
FAIL_COUNT=0
WARN_COUNT=0

usage() {
  cat <<'EOF'
usage: bash scripts/gate/asf-doctor.sh [--strict]

checks:
  - required files/scripts
  - command availability (bash/git/jq/gh required)
  - gh auth status (required)
  - hooksPath sanity

exit codes:
  0: all checks passed
  1: one or more checks failed
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT="true"
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

ok() { echo "[ok] $1"; }
warn() {
  echo "[warn] $1"
  WARN_COUNT=$((WARN_COUNT + 1))
  if [[ "$STRICT" == "true" ]]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}
fail() {
  echo "[fail] $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

check_file() {
  local p="$1"
  if [[ -f "$ROOT_DIR/$p" ]]; then
    ok "file exists: $p"
  else
    fail "missing file: $p"
  fi
}

check_exec() {
  local p="$1"
  if [[ -x "$ROOT_DIR/$p" ]]; then
    ok "executable exists: $p"
  else
    fail "missing executable: $p"
  fi
}

check_cmd_required() {
  local c="$1"
  if command -v "$c" >/dev/null 2>&1; then
    ok "command available: $c"
  else
    fail "command missing: $c"
  fi
}

check_cmd_recommended() {
  local c="$1"
  if command -v "$c" >/dev/null 2>&1; then
    ok "command available: $c"
  else
    warn "recommended command missing: $c"
  fi
}

check_file ".agent-swarm-framework.config.json"
check_file ".agent-swarm-framework.manifest.json"
check_file ".multi-agent/engine-routing.json"
check_file ".github/workflows/multi-agent-planner-implementer.yml"

check_exec "scripts/asf-workflow.sh"
check_exec "scripts/gate/workflow.sh"
check_exec "scripts/gate/command-dispatch.sh"
check_exec "scripts/gate/command-validate.sh"
check_exec "scripts/worker/workers-start.sh"
check_exec "scripts/worker/workers-stop.sh"

check_cmd_required bash
check_cmd_required git
check_cmd_required jq
check_cmd_required gh

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "gh auth status: OK"
  else
    fail "gh auth missing (run: gh auth login)"
  fi
fi

HOOKS_PATH="$(git -C "$ROOT_DIR" config --get core.hooksPath 2>/dev/null || true)"
if [[ -z "$HOOKS_PATH" || "$HOOKS_PATH" == ".githooks" ]]; then
  ok "core.hooksPath: ${HOOKS_PATH:-<unset>}"
else
  warn "core.hooksPath is custom: $HOOKS_PATH"
fi

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo "[summary] fail=$FAIL_COUNT warn=$WARN_COUNT strict=$STRICT"
  exit 1
fi

echo "[summary] fail=0 warn=$WARN_COUNT strict=$STRICT"

