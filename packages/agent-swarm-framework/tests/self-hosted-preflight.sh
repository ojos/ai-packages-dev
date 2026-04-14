#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${PWD}"
CONFIG_FILE=""
STRICT_ENGINES="true"

usage() {
  cat <<'EOF'
usage: bash packages/agent-swarm-framework/tests/self-hosted-preflight.sh [options]

options:
  --repo-root <path>          対象リポジトリルート (default: current directory)
  --config <json-file>        設定ファイルを明示指定
  --no-strict-engines         CLIエンジン未導入を警告扱いにする
  -h, --help                  Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --no-strict-engines)
      STRICT_ENGINES="false"
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

pass_count=0
warn_count=0
fail_count=0

pass() {
  echo "[PASS] $1"
  pass_count=$((pass_count + 1))
}

warn() {
  echo "[WARN] $1"
  warn_count=$((warn_count + 1))
}

fail() {
  echo "[FAIL] $1"
  fail_count=$((fail_count + 1))
}

require_cmd() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "command available: $cmd"
  else
    fail "required command missing: $cmd"
  fi
}

echo "== ASF self-hosted preflight =="
echo "repo_root: $REPO_ROOT"

require_cmd git
require_cmd jq
require_cmd gh

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    pass "gh authentication is available"
  else
    fail "gh authentication is not available"
  fi
fi

if [[ -z "$CONFIG_FILE" ]]; then
  if [[ -f "$REPO_ROOT/.agent-swarm-framework.config.json" ]]; then
    CONFIG_FILE="$REPO_ROOT/.agent-swarm-framework.config.json"
  fi
fi

if [[ -z "$CONFIG_FILE" ]]; then
  fail "config file not found (use --config or place .agent-swarm-framework.config.json)"
else
  if [[ -f "$CONFIG_FILE" ]]; then
    pass "config file found: $CONFIG_FILE"
  else
    fail "config file missing: $CONFIG_FILE"
  fi
fi

if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  if jq -e . "$CONFIG_FILE" >/dev/null 2>&1; then
    pass "config json is valid"
  else
    fail "config json is invalid"
  fi
fi

for path in \
  "scripts/gate/command-dispatch.sh" \
  "scripts/worker/worker-coordinator.sh" \
  "scripts/worker/orchestrator-worker.sh" \
  "scripts/worker/line-worker.sh"; do
  if [[ -f "$REPO_ROOT/$path" ]]; then
    pass "required runtime file exists: $path"
  else
    fail "required runtime file missing: $path"
  fi
done

if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  all_engines="$({
    jq -r '.agentEngines.roles? // {} | .[]?' "$CONFIG_FILE"
    jq -r '.taskEngineOverrides? // {} | .[]? | .[]?' "$CONFIG_FILE"
  } | sort -u | xargs echo 2>/dev/null || true)"

  if [[ -z "$all_engines" ]]; then
    all_engines="copilot claude gemini"
  fi

  exec_engines="$({
    jq -r '(.agentEngines.roles.implementer // "claude"), (.agentEngines.roles.reviewer // "gemini")' "$CONFIG_FILE"
    jq -r '.taskEngineOverrides? // {} | .[]? | .implementer?, .reviewer?' "$CONFIG_FILE"
  } | sed '/^null$/d' | sort -u | xargs echo 2>/dev/null || true)"

  echo "engine targets (all): $all_engines"
  for engine in $all_engines; do
    case "$engine" in
      copilot)
        pass "engine '$engine' allowed for non-execution roles"
        ;;
      claude|gemini|codex)
        if command -v "$engine" >/dev/null 2>&1; then
          pass "engine CLI available: $engine"
        else
          if [[ "$STRICT_ENGINES" == "true" ]]; then
            fail "engine CLI missing: $engine"
          else
            warn "engine CLI missing: $engine"
          fi
        fi
        ;;
      *)
        warn "unknown engine value in config: $engine"
        ;;
    esac
  done

  if [[ -n "$exec_engines" ]]; then
    echo "execution role engines: $exec_engines"
    for engine in $exec_engines; do
      case "$engine" in
        copilot)
          if [[ "$STRICT_ENGINES" == "true" ]]; then
            fail "execution role uses unsupported engine: copilot"
          else
            warn "execution role uses unsupported engine: copilot"
          fi
          ;;
        claude|gemini|codex)
          :
          ;;
        *)
          if [[ "$STRICT_ENGINES" == "true" ]]; then
            fail "execution role uses unknown engine: $engine"
          else
            warn "execution role uses unknown engine: $engine"
          fi
          ;;
      esac
    done
  fi
fi

echo
echo "summary: pass=$pass_count warn=$warn_count fail=$fail_count"

if (( fail_count > 0 )); then
  exit 1
fi

exit 0
