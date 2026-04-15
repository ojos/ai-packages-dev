#!/usr/bin/env bash
# conversation-gate.sh — 会話ゲート判定スクリプトの検証
# 使い方: bash packages/agent-swarm-framework/tests/conversation-gate.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/gate/conversation-gate.sh"
TARGET_PACKAGE_SCRIPT="$REPO_ROOT/packages/agent-swarm-framework/runtime-core/files/scripts/gate/conversation-gate.sh"

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

section() {
  echo
  echo "=== $1 ==="
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

assert_has_field() {
  local json="$1"
  local field="$2"
  local label="$3"
  if printf '%s' "$json" | jq -e --arg f "$field" 'has($f)' >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label (missing field=$field)"
  fi
}

run_case() {
  "$TARGET_SCRIPT" "$@"
}

if [[ ! -x "$TARGET_SCRIPT" ]]; then
  echo "error: target script not executable: $TARGET_SCRIPT" >&2
  exit 1
fi

if [[ ! -x "$TARGET_PACKAGE_SCRIPT" ]]; then
  echo "error: package target script not executable: $TARGET_PACKAGE_SCRIPT" >&2
  exit 1
fi

section "基本契約"
OUT="$(run_case \
  --input-text "この機能を実装して" \
  --intent-type implement \
  --has-edit-request true \
  --draft-fields '{"goal":{"filled":false},"acceptance":{"filled":false},"scope":{"in":{"filled":true}},"priority":{"filled":true}}' \
  --channel-type vscode_chat \
  --bypass-requested false)"

assert_has_field "$OUT" "intake_required" "intake_required フィールドが存在"
assert_has_field "$OUT" "reason_code" "reason_code フィールドが存在"
assert_has_field "$OUT" "reason_message" "reason_message フィールドが存在"
assert_has_field "$OUT" "missing_fields" "missing_fields フィールドが存在"

CODE="$(printf '%s' "$OUT" | jq -r '.reason_code')"
REQ="$(printf '%s' "$OUT" | jq -r '.intake_required')"
MISSING_COUNT="$(printf '%s' "$OUT" | jq -r '.missing_fields | length')"
assert_eq "$REQ" "true" "実装依頼は intake_required=true"
assert_eq "$CODE" "IMPLEMENTATION_MISSING_GOAL_ACCEPTANCE" "goal/acceptance 同時不足コード"
assert_eq "$MISSING_COUNT" "2" "不足項目が2件"

section "Exempt 判定"
OUT="$(run_case \
  --input-text "この仕様を説明して" \
  --intent-type explain \
  --has-edit-request false \
  --draft-fields '{}' \
  --channel-type vscode_chat \
  --bypass-requested false)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.intake_required')" "false" "explain は intake 不要"
assert_eq "$(printf '%s' "$OUT" | jq -r '.reason_code')" "EXPLAIN_EXEMPT" "explain exempt コード"

OUT="$(run_case \
  --input-text "軽微修正して" \
  --intent-type small_fix \
  --has-edit-request true \
  --draft-fields '{}' \
  --is-small-task-candidate true \
  --channel-type vscode_editor \
  --bypass-requested false)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.intake_required')" "false" "small_fix 条件一致は intake 不要"
assert_eq "$(printf '%s' "$OUT" | jq -r '.reason_code')" "SMALL_FIX_EXEMPT_MEETS_CRITERIA" "small_fix exempt コード"

OUT="$(run_case \
  --input-text "軽微修正して" \
  --intent-type small_fix \
  --has-edit-request true \
  --draft-fields '{}' \
  --is-small-task-candidate false \
  --channel-type vscode_editor \
  --bypass-requested false)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.intake_required')" "true" "small_fix 条件不一致は intake 必須"
assert_eq "$(printf '%s' "$OUT" | jq -r '.reason_code')" "SMALL_FIX_REQUIRES_INTAKE" "small_fix requires code"

section "Bypass 判定"
OUT="$(run_case \
  --input-text "今すぐ障害対応して" \
  --intent-type implement \
  --has-edit-request true \
  --draft-fields '{}' \
  --channel-type vscode_chat \
  --bypass-requested true \
  --bypass-reason emergency)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.intake_required')" "false" "緊急 bypass は intake 不要"
assert_eq "$(printf '%s' "$OUT" | jq -r '.reason_code')" "BYPASS_APPROVED_EMERGENCY" "緊急 bypass コード"

OUT="$(run_case \
  --input-text "bypass して" \
  --intent-type implement \
  --has-edit-request true \
  --draft-fields '{}' \
  --channel-type vscode_chat \
  --bypass-requested true \
  --bypass-reason unknown)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.intake_required')" "true" "不正 bypass は intake 必須"
assert_eq "$(printf '%s' "$OUT" | jq -r '.reason_code')" "BYPASS_REJECTED_INVALID_REASON" "不正 bypass コード"

section "既存 issue 流用判定"
OUT="$(run_case \
  --input-text "#123 の続き実装" \
  --intent-type implement \
  --existing-issue-number 123 \
  --has-edit-request true \
  --draft-fields '{"goal":{"filled":true},"acceptance":{"filled":true},"scope":{"in":{"filled":true}},"priority":{"filled":true}}' \
  --channel-type vscode_chat \
  --bypass-requested false)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.intake_required')" "false" "既存 issue 充足時は intake 不要"
assert_eq "$(printf '%s' "$OUT" | jq -r '.reason_code')" "IMPLEMENTATION_EXISTING_ISSUE_REUSABLE" "既存 issue 流用コード"

OUT="$(run_case \
  --input-text "#123 の続き実装" \
  --intent-type implement \
  --existing-issue-number 123 \
  --has-edit-request true \
  --draft-fields '{"goal":{"filled":false},"acceptance":{"filled":true},"scope":{"in":{"filled":true}},"priority":{"filled":true}}' \
  --channel-type vscode_chat \
  --bypass-requested false)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.intake_required')" "true" "既存 issue 不足時は intake 必須"
assert_eq "$(printf '%s' "$OUT" | jq -r '.reason_code')" "IMPLEMENTATION_EXISTING_ISSUE_UNCLEAR" "既存 issue 不明瞭コード"

OUT="$(run_case \
  --input-text "#123 の続き実装" \
  --intent-type implement \
  --existing-issue-number 123 \
  --existing-issue-body $'goal: 既存の不具合修正\nscope.in: API のエラーハンドリング\nacceptance: エラー時に 4xx を返す\npriority: high' \
  --has-edit-request true \
  --draft-fields '{"goal":{"filled":false},"acceptance":{"filled":false},"scope":{"in":{"filled":false}},"priority":{"filled":false}}' \
  --channel-type vscode_chat \
  --bypass-requested false)"
assert_eq "$(printf '%s' "$OUT" | jq -r '.intake_required')" "false" "issue本文補完で流用可能なら intake 不要"
assert_eq "$(printf '%s' "$OUT" | jq -r '.reason_code')" "IMPLEMENTATION_EXISTING_ISSUE_REUSABLE" "issue本文補完後の流用コード"

section "配布スクリプトとの同値性"
ARGS=(
  --input-text "この機能を実装して"
  --intent-type implement
  --has-edit-request true
  --draft-fields '{"goal":{"filled":false},"acceptance":{"filled":false},"scope":{"in":{"filled":true}},"priority":{"filled":true}}'
  --channel-type vscode_chat
  --bypass-requested false
)

OUT_ROOT="$("$TARGET_SCRIPT" "${ARGS[@]}")"
OUT_PKG="$("$TARGET_PACKAGE_SCRIPT" "${ARGS[@]}")"
if [[ "$OUT_ROOT" == "$OUT_PKG" ]]; then
  pass "root/runtime-core スクリプトの出力同値性"
else
  fail "root/runtime-core スクリプトの出力が不一致"
fi

echo
echo "=============================="
echo "結果: PASS=$PASS FAIL=$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
echo "すべてのチェックが通過しました"
echo "=============================="
