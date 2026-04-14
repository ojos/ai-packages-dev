#!/usr/bin/env bash
# verify-install.sh — agent-swarm-framework テンプレート適用検証スクリプト
# 目的: install.sh / init.sh の適用結果を自動検証する
# 使い方: bash packages/agent-swarm-framework/tests/verify-install.sh [--target-dir <path>]
set -euo pipefail

TARGET_DIR="${1:-}"
TARGET_DIR_EXPLICIT="false"
PASS=0
FAIL=0
ERRORS=()

# ---- 引数解析 ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir)
      TARGET_DIR="$2"
      TARGET_DIR_EXPLICIT="true"
      shift 2
      ;;
    -h|--help)
      echo "usage: bash verify-install.sh [--target-dir <path>]"
      echo "  --target-dir <path>  検証対象ディレクトリ (default: \$PWD)"
      exit 0
      ;;
    *) echo "error: unknown option: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$TARGET_DIR" ]] && TARGET_DIR="$PWD"

if [[ ! -d "$TARGET_DIR" ]]; then
  echo "error: target directory does not exist: $TARGET_DIR" >&2
  exit 1
fi

# よくある誤用対策:
# ソースリポジトリ直下で実行すると、適用済み成果物がないため全項目FAILになりやすい。
if [[ "$TARGET_DIR_EXPLICIT" != "true" ]] && [[ "$TARGET_DIR" == "$PWD" ]]; then
  if [[ -d "$TARGET_DIR/packages/agent-swarm-framework" ]] && [[ ! -f "$TARGET_DIR/.agent-swarm-framework.config.json" ]]; then
    cat >&2 <<EOF
error: verify-install.sh is intended for an initialized target workspace, not the source repository root.
hint: run one of the following:
  1) bash packages/agent-swarm-framework/tests/e2e-init.sh
  2) bash packages/agent-swarm-framework/tests/verify-install.sh --target-dir <initialized-target-dir>
EOF
    exit 2
  fi
fi

# ---- ヘルパー ----
pass() {
  echo "  [PASS] $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  [FAIL] $1"
  FAIL=$((FAIL + 1))
  ERRORS+=("$1")
}
section() { echo; echo "=== $1 ==="; }

check_file() {
  local path="$1"
  local desc="${2:-$1}"
  if [[ -f "$TARGET_DIR/$path" ]]; then
    pass "$desc"
  else
    fail "$desc が存在しない"
  fi
}

check_dir() {
  local path="$1"
  local desc="${2:-$1}"
  if [[ -d "$TARGET_DIR/$path" ]]; then
    pass "$desc"
  else
    fail "$desc が存在しない"
  fi
}

check_executable() {
  local path="$1"
  if [[ -x "$TARGET_DIR/$path" ]]; then
    pass "$path は実行可能"
  else
    fail "$path が実行不可能"
  fi
}

# ---- テスト ----

section "マニフェスト・設定ファイル"
check_file ".agent-swarm-framework.config.json" "config.json"
check_file ".agent-swarm-framework.manifest.json" "manifest.json"

if [[ -f "$TARGET_DIR/.agent-swarm-framework.config.json" ]]; then
  # config JSON が valid か確認
  if jq . "$TARGET_DIR/.agent-swarm-framework.config.json" >/dev/null 2>&1; then
    pass "config.json は valid JSON"
  else
    fail "config.json が invalid JSON"
  fi

  # version フィールドが存在するか確認
  VERSION="$(jq -r '.version // empty' "$TARGET_DIR/.agent-swarm-framework.config.json" 2>/dev/null || true)"
  if [[ -n "$VERSION" ]]; then
    pass "config.version = $VERSION"
  else
    fail "config.json に version フィールドがない"
  fi
fi

section "agent-skills"
check_dir ".multi-agent/skills" ".multi-agent/skills/ ディレクトリ"
for role in orchestrator planner implementer reviewer closer; do
  check_file ".multi-agent/skills/${role}.md" "skill: $role"
done

section "runtime-core / scripts"
check_dir "scripts/gate" "scripts/gate/"
check_dir "scripts/monitor" "scripts/monitor/"
check_dir "scripts/worker" "scripts/worker/"
check_file ".multi-agent/engine-routing.json" "engine-routing.json"

for script in \
  scripts/gate/auto-gate.sh \
  scripts/gate/command-dispatch.sh \
  scripts/gate/command-validate.sh \
  scripts/gate/workflow.sh \
  scripts/monitor/monitor-overview.sh \
  scripts/worker/line-worker.sh \
  scripts/worker/closer-worker.sh; do
  check_file "$script"
  [[ -f "$TARGET_DIR/$script" ]] && check_executable "$script"
done

section "template-project"
check_file ".multi-agent/labels.json" "labels.json"

section "manifest 内容確認"
if [[ -f "$TARGET_DIR/.agent-swarm-framework.manifest.json" ]]; then
  GEN_AT="$(jq -r '.generatedAt // empty' "$TARGET_DIR/.agent-swarm-framework.manifest.json" 2>/dev/null || true)"
  if [[ -n "$GEN_AT" ]]; then
    pass "manifest.generatedAt = $GEN_AT"
  else
    fail "manifest.json に generatedAt がない"
  fi
fi

# ---- 結果 ----
echo
echo "=============================="
echo "結果: PASS=$PASS  FAIL=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "失敗した項目:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
  echo "=============================="
  exit 1
else
  echo "すべてのチェックが通過しました"
  echo "=============================="
  exit 0
fi
