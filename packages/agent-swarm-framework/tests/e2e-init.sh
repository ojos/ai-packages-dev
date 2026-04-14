#!/usr/bin/env bash
# e2e-init.sh — init.sh の最小 E2E テスト
# 目的: 一時ディレクトリに非インタラクティブ適用を行い、verify-install.sh で検証する
# 使い方: bash packages/agent-swarm-framework/tests/e2e-init.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERIFY_SCRIPT="$SCRIPT_DIR/verify-install.sh"
INIT_SCRIPT="$PACKAGE_ROOT/init.sh"
INSTALL_SCRIPT="$PACKAGE_ROOT/install.sh"

# ---- テスト用設定ファイル ----
TMPDIR_BASE="$(mktemp -d)"
CONFIG_FILE="$TMPDIR_BASE/test-config.json"
TARGET_DIR="$TMPDIR_BASE/target"

cleanup() {
  rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

mkdir -p "$TARGET_DIR"

cat > "$CONFIG_FILE" << 'CONFIG'
{
  "version": "1.0",
  "displayName": "E2E Test Project",
  "projectSlug": "e2e-test",
  "executionMode": "hybrid",
  "remoteProvider": "github-actions",
  "automationStage": "implement",
  "mergePolicy": "manual",
  "lineStrategy": "fixed2",
  "orchestratorMode": "remote",
  "stateBackend": "hybrid"
}
CONFIG

echo "=== E2E テスト開始 ==="
echo "target: $TARGET_DIR"
echo "config: $CONFIG_FILE"

# ---- Step 1: 初回適用 ----
echo
echo "--- Step 1: 初回適用（--non-interactive / --skip-github）---"
bash "$INIT_SCRIPT" \
  --target-dir "$TARGET_DIR" \
  --config "$CONFIG_FILE" \
  --non-interactive \
  --skip-github

# ---- Step 2: 検証 ----
echo
echo "--- Step 2: 適用結果の検証 ---"
bash "$VERIFY_SCRIPT" --target-dir "$TARGET_DIR"

# ---- Step 3: 冪等性テスト ----
echo
echo "--- Step 3: 冪等性テスト（2回目の適用はスキップされるか）---"
OUTPUT="$(bash "$INIT_SCRIPT" \
  --target-dir "$TARGET_DIR" \
  --config "$CONFIG_FILE" \
  --non-interactive \
  --skip-github 2>&1)"

if echo "$OUTPUT" | grep -q "既に適用済みです"; then
  echo "  [PASS] 冪等性: 2回目の適用はスキップされた"
else
  echo "  [FAIL] 冪等性: スキップされなかった"
  echo "  output: $OUTPUT"
  exit 1
fi

# ---- Step 4: dry-run テスト ----
echo
echo "--- Step 4: dry-run テスト ---"
TARGET_DRY="$TMPDIR_BASE/target-dry"
mkdir -p "$TARGET_DRY"
DRY_OUTPUT="$(bash "$INIT_SCRIPT" \
  --target-dir "$TARGET_DRY" \
  --config "$CONFIG_FILE" \
  --non-interactive \
  --skip-github \
  --dry-run 2>&1)"

if echo "$DRY_OUTPUT" | grep -q "dry-run"; then
  echo "  [PASS] dry-run: ドライランメッセージが出力された"
else
  echo "  [FAIL] dry-run: 期待するメッセージが見つからない"
  echo "  output: $DRY_OUTPUT"
  exit 1
fi

# dry-run では manifest が生成されていないことを確認
if [[ ! -f "$TARGET_DRY/.agent-swarm-framework.manifest.json" ]]; then
  echo "  [PASS] dry-run: manifest は生成されなかった"
else
  echo "  [FAIL] dry-run: manifest が生成されてしまった"
  exit 1
fi

echo
# ---- Step 5: retrofit-safe テスト ----
echo
echo "--- Step 5: retrofit-safe テスト（非対話・安全適用）---"
TARGET_RETROFIT="$TMPDIR_BASE/target-retrofit"
mkdir -p "$TARGET_RETROFIT"

bash "$INSTALL_SCRIPT" \
  --retrofit-safe \
  --non-interactive \
  --config "$PACKAGE_ROOT/retrofit-config.sample.json" \
  --target-dir "$TARGET_RETROFIT"

# runtime-core / agent-skills は適用される
for expected in \
  "scripts/gate/workflow.sh" \
  "scripts/monitor/monitor-overview.sh" \
  ".multi-agent/skills/orchestrator.md"; do
  if [[ -f "$TARGET_RETROFIT/$expected" ]]; then
    echo "  [PASS] retrofit-safe 適用: $expected"
  else
    echo "  [FAIL] retrofit-safe 適用漏れ: $expected"
    exit 1
  fi
done

# template-project は既定スキップされる
for skipped in \
  ".multi-agent/labels.json" \
  ".multi-agent/project-overrides.example.json"; do
  if [[ ! -f "$TARGET_RETROFIT/$skipped" ]]; then
    echo "  [PASS] retrofit-safe スキップ: $skipped"
  else
    echo "  [FAIL] retrofit-safe で本来スキップすべきファイルが存在: $skipped"
    exit 1
  fi
done

echo
echo "=== E2E テスト完了: すべて PASS ==="
