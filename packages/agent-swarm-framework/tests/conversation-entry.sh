#!/usr/bin/env bash
# conversation-entry.sh — 会話入口連携スクリプトの検証
# 使い方: bash packages/agent-swarm-framework/tests/conversation-entry.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENTRY_SCRIPT="$REPO_ROOT/scripts/gate/conversation-entry.sh"
ENTRY_PACKAGE_SCRIPT="$REPO_ROOT/packages/agent-swarm-framework/runtime-core/files/scripts/gate/conversation-entry.sh"

PASS=0
FAIL=0

pass() {
  echo "  [PASS] $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  [FAIL] $1"
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (actual=$actual expected=$expected)"
  fi
}

section() {
  echo
  echo "=== $1 ==="
}

if [[ ! -x "$ENTRY_SCRIPT" ]]; then
  echo "error: entry script not executable: $ENTRY_SCRIPT" >&2
  exit 1
fi

if [[ ! -x "$ENTRY_PACKAGE_SCRIPT" ]]; then
  echo "error: package entry script not executable: $ENTRY_PACKAGE_SCRIPT" >&2
  exit 1
fi

section "intake不要時の継続判定"
OUT="$("$ENTRY_SCRIPT" \
  --input-text "この仕様を説明して" \
  --intent-type explain \
  --has-edit-request false \
  --draft-fields '{}' \
  --channel-type vscode_chat \
  --bypass-requested false)"

assert_eq "$(printf '%s' "$OUT" | jq -r '.status')" "continue" "exempt は continue"
assert_eq "$(printf '%s' "$OUT" | jq -r '.reason_code')" "EXPLAIN_EXEMPT" "exempt reason_code"

section "intake必要時の確認ブロック出力"
OUT_RAW="$("$ENTRY_SCRIPT" \
  --input-text "この機能を実装して" \
  --intent-type implement \
  --has-edit-request true \
  --draft-fields '{"goal":{"filled":false},"acceptance":{"filled":false},"scope":{"in":{"filled":true}},"priority":{"filled":true}}' \
  --channel-type vscode_chat \
  --bypass-requested false)"

if printf '%s' "$OUT_RAW" | grep -q '=== INTAKE_CONFIRMATION_BLOCK_BEGIN ==='; then
  pass "固定フォーマット確認ブロックを出力"
else
  fail "固定フォーマット確認ブロックを出力"
fi

OUT_JSON="$(printf '%s' "$OUT_RAW" | tail -n 1)"
assert_eq "$(printf '%s' "$OUT_JSON" | jq -r '.status')" "needs_confirmation" "intake必要時は確認待ち"
assert_eq "$(printf '%s' "$OUT_JSON" | jq -r '.reason_code')" "IMPLEMENTATION_MISSING_GOAL_ACCEPTANCE" "実装不足 reason_code"

section "confirm + dry-run で dispatch 準備"
OUT_RAW="$("$ENTRY_SCRIPT" \
  --input-text "この機能を実装して" \
  --intent-type implement \
  --has-edit-request true \
  --draft-fields '{"goal":{"filled":false},"acceptance":{"filled":false},"scope":{"in":{"filled":false}},"priority":{"filled":false}}' \
  --channel-type vscode_chat \
  --bypass-requested false \
  --confirm true \
  --dry-run true)"

OUT_JSON="$(printf '%s' "$OUT_RAW" | tail -n 1)"
assert_eq "$(printf '%s' "$OUT_JSON" | jq -r '.status')" "ready_to_dispatch" "dry-run は dispatch 準備状態"
assert_eq "$(printf '%s' "$OUT_JSON" | jq -r '.dispatch_scope')" "issue:#DRY_RUN_NEW_ISSUE" "新規 issue の dry-run dispatch scope"

section "配布スクリプトとの同値性（confirm=false 経路）"
ARGS=(
  --input-text "この機能を実装して"
  --intent-type implement
  --has-edit-request true
  --draft-fields '{"goal":{"filled":false},"acceptance":{"filled":false},"scope":{"in":{"filled":true}},"priority":{"filled":true}}'
  --channel-type vscode_chat
  --bypass-requested false
)

OUT_ROOT="$("$ENTRY_SCRIPT" "${ARGS[@]}" | tail -n 1)"
OUT_PKG="$("$ENTRY_PACKAGE_SCRIPT" "${ARGS[@]}" | tail -n 1)"
if [[ "$OUT_ROOT" == "$OUT_PKG" ]]; then
  pass "root/runtime-core 入口スクリプト同値性"
else
  fail "root/runtime-core 入口スクリプト同値性"
fi

echo
echo "=============================="
echo "結果: PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "すべてのチェックが通過しました"
echo "=============================="
