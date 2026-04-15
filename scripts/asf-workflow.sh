#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_SCRIPT="$ROOT_DIR/scripts/gate/workflow.sh"
MARKER_DIR="$ROOT_DIR/scripts/orchestration/runtime"
MARKER_FILE="$MARKER_DIR/asf-last-run.json"

write_last_run_marker() {
  local command_name="$1"
  mkdir -p "$MARKER_DIR"
  printf '{"timestamp":"%s","command":"%s"}\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "$command_name" >"$MARKER_FILE"
}

usage() {
  cat <<'EOF'
usage:
  bash scripts/asf-workflow.sh preflight
  bash scripts/asf-workflow.sh status [--line <all|line-id>]
  bash scripts/asf-workflow.sh up [--interval <sec>]
  bash scripts/asf-workflow.sh down
  bash scripts/asf-workflow.sh restart [--interval <sec>]
  bash scripts/asf-workflow.sh dead-letter [options]

notes:
  - This wrapper enforces ASF prerequisite checks before running workflow commands.
  - Actual workflow execution is delegated to scripts/gate/workflow.sh.
EOF
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || {
    echo "error: required file is missing: $path" >&2
    exit 1
  }
}

check_preflight() {
  require_file "$ROOT_DIR/.agent-swarm-framework.config.json"
  require_file "$ROOT_DIR/.agent-swarm-framework.manifest.json"
  require_file "$ROOT_DIR/.multi-agent/engine-routing.json"
  require_file "$ROOT_DIR/.github/workflows/multi-agent-planner-implementer.yml"
  require_file "$ROOT_DIR/scripts/gate/command-validate.sh"
  require_file "$ROOT_DIR/scripts/gate/command-dispatch.sh"
  require_file "$WORKFLOW_SCRIPT"

  command -v gh >/dev/null 2>&1 || {
    echo "error: gh is required but not found" >&2
    exit 1
  }
  gh auth status >/dev/null 2>&1 || {
    echo "error: gh auth is missing. run: bash scripts/on-attach.sh or gh auth login" >&2
    exit 1
  }

  bash -n "$WORKFLOW_SCRIPT"
  echo "[ok] ASF preflight passed"
}

main() {
  local subcommand="${1:-}"
  [[ -n "$subcommand" ]] || {
    usage
    exit 1
  }
  shift || true

  case "$subcommand" in
    -h|--help)
      usage
      ;;
    preflight)
      check_preflight
      write_last_run_marker "preflight"
      ;;
    status|up|down|restart|dead-letter)
      check_preflight
      bash "$WORKFLOW_SCRIPT" "$subcommand" "$@"
      write_last_run_marker "$subcommand"
      ;;
    *)
      echo "error: unknown subcommand: $subcommand" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
