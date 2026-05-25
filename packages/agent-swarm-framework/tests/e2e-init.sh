#!/usr/bin/env bash
# e2e-init.sh — init.sh の最小 E2E テスト
# 目的: 一時ディレクトリに非インタラクティブ適用を行い、verify-install.sh で検証する
# 使い方: bash packages/agent-swarm-framework/tests/e2e-init.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PACKAGE_ROOT/../.." && pwd)"
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

# runtime-core / agent-definitions は適用される
for expected in \
  "scripts/gate/workflow.sh" \
  "scripts/monitor/monitor-overview.sh" \
  ".multi-agent/role-contracts/orchestrator.md"; do
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
# ---- Step 6: dotfiles 同時導入テスト ----
echo
echo "--- Step 6: dotfiles 同時導入テスト（--with-dotfiles）---"
TARGET_DOTFILES="$TMPDIR_BASE/target-dotfiles"
mkdir -p "$TARGET_DOTFILES"

bash "$INSTALL_SCRIPT" \
  --non-interactive \
  --config "$CONFIG_FILE" \
  --target-dir "$TARGET_DOTFILES" \
  --skip-github \
  --with-dotfiles \
  --dotfiles-from "$REPO_ROOT/dotfiles/ai/common/shared-ai-rules.md" \
  --dotfiles-conflict-policy skip

for expected in \
  "dotfiles/ai/common/shared-ai-rules.md" \
  ".github/project-ai-rules.md" \
  ".github/copilot-instructions.md" \
  "CLAUDE.md"; do
  if [[ -f "$TARGET_DOTFILES/$expected" ]]; then
    echo "  [PASS] dotfiles 導入: $expected"
  else
    echo "  [FAIL] dotfiles 導入漏れ: $expected"
    exit 1
  fi
done

# ---- Step 7: dotfiles 衝突ポリシーテスト ----
echo
echo "--- Step 7: dotfiles 衝突ポリシーテスト（skip / overwrite）---"
echo "custom-claude-entry" > "$TARGET_DOTFILES/CLAUDE.md"

bash "$INSTALL_SCRIPT" \
  --non-interactive \
  --config "$CONFIG_FILE" \
  --target-dir "$TARGET_DOTFILES" \
  --skip-github \
  --with-dotfiles \
  --dotfiles-from "$REPO_ROOT/dotfiles/ai/common/shared-ai-rules.md" \
  --dotfiles-conflict-policy skip

if grep -q "custom-claude-entry" "$TARGET_DOTFILES/CLAUDE.md"; then
  echo "  [PASS] conflict policy skip: 既存ファイル維持"
else
  echo "  [FAIL] conflict policy skip: 既存ファイルが維持されなかった"
  exit 1
fi

bash "$INSTALL_SCRIPT" \
  --non-interactive \
  --config "$CONFIG_FILE" \
  --target-dir "$TARGET_DOTFILES" \
  --skip-github \
  --with-dotfiles \
  --dotfiles-from "$REPO_ROOT/dotfiles/ai/common/shared-ai-rules.md" \
  --dotfiles-conflict-policy overwrite

if grep -q "Claude 実行環境向け入口ファイル" "$TARGET_DOTFILES/CLAUDE.md"; then
  echo "  [PASS] conflict policy overwrite: 既存ファイル上書き"
else
  echo "  [FAIL] conflict policy overwrite: 上書きされなかった"
  exit 1
fi

# ---- Step 8: dotfiles 衝突ポリシーテスト（prompt）----
echo
echo "--- Step 8: dotfiles 衝突ポリシーテスト（prompt）---"
echo "custom-claude-entry-prompt" > "$TARGET_DOTFILES/CLAUDE.md"

# prompt テスト: カテゴリ適用は y、dotfiles 上書き確認は n を送る
PROMPT_INPUT=$'y\ny\ny\ny\nn\nn\nn\nn\n'
printf '%s' "$PROMPT_INPUT" | bash "$INSTALL_SCRIPT" \
  --config "$CONFIG_FILE" \
  --target-dir "$TARGET_DOTFILES" \
  --skip-github \
  --with-dotfiles \
  --dotfiles-from "$REPO_ROOT/dotfiles/ai/common/shared-ai-rules.md" \
  --dotfiles-conflict-policy prompt

if grep -q "custom-claude-entry-prompt" "$TARGET_DOTFILES/CLAUDE.md"; then
  echo "  [PASS] conflict policy prompt: 上書き確認で拒否したため既存ファイル維持"
else
  echo "  [FAIL] conflict policy prompt: 既存ファイルが維持されなかった"
  exit 1
fi

# prompt テスト: dotfiles 側の上書き確認を y で承認
echo "custom-claude-entry-prompt-yes" > "$TARGET_DOTFILES/CLAUDE.md"
PROMPT_INPUT_YES=$'y\ny\ny\ny\ny\ny\ny\ny\n'
printf '%s' "$PROMPT_INPUT_YES" | bash "$INSTALL_SCRIPT" \
  --config "$CONFIG_FILE" \
  --target-dir "$TARGET_DOTFILES" \
  --skip-github \
  --with-dotfiles \
  --dotfiles-from "$REPO_ROOT/dotfiles/ai/common/shared-ai-rules.md" \
  --dotfiles-conflict-policy prompt

if grep -q "Claude 実行環境向け入口ファイル" "$TARGET_DOTFILES/CLAUDE.md"; then
  echo "  [PASS] conflict policy prompt: 上書き確認で承認したためファイル上書き"
else
  echo "  [FAIL] conflict policy prompt: 上書き承認時に更新されなかった"
  exit 1
fi

echo
echo "=== E2E テスト完了: すべて PASS ==="
