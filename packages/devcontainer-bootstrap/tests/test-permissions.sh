#!/usr/bin/env bash
# 生成ファイルのパーミッションを検証する。
#
# mktemp は 0600 で作成し mv/cp がそれを引き継ぐ。この正規化を忘れると、
# 生成した .gitignore が -rw------- に、スクリプトが chmod +x 後に -rwx--x--x に
# なる。さらに既存ファイルを上書きする経路では、利用者が設定したモードを
# 壊してしまう。git は実行ビットしか記録しないためコミット後は見えにくく、
# 生成直後の作業ツリーでのみ表面化する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-permissions"

# ── 新規生成 ──────────────────────────────────────────────────────────────────

out="$(new_workdir)/p"
run_bootstrap "$out" --with-playbook >/dev/null 2>&1

it "生成された .gitignore は 644"
assert_mode "$out/.gitignore" "644"

it "生成された devcontainer.json は 644"
assert_mode "$out/.devcontainer/devcontainer.json" "644"

it "生成されたスクリプトは 755"
assert_mode "$out/scripts/on-attach.sh" "755"

it "生成された gemini-review.sh は 755"
assert_mode "$out/scripts/gemini-review.sh" "755"

it "配置された規範は 644"
assert_mode "$out/.ai-playbook/shared-ai-rules.md" "644"

it "生成された入口ファイルは 644"
assert_mode "$out/CLAUDE.md" "644"

it "所有者以外が読めないファイルは生成されない"
unreadable="$(find "$out" -type f ! -perm -004 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$unreadable" "0" "world-readable でないファイル数"

# ── 既存ファイルのモードを壊さない ────────────────────────────────────────────

it "既存 .gitignore のモードを保持する"
out="$(new_workdir)/p"
mkdir -p "$out"
printf 'node_modules\n' > "$out/.gitignore"
chmod 664 "$out/.gitignore"
run_bootstrap "$out" --force >/dev/null 2>&1
assert_mode "$out/.gitignore" "664"

it "既存 .gitignore の内容を保持する"
grep -q 'node_modules' "$out/.gitignore" && pass || fail "既存の内容が失われた"

it "overwrite でも既存規範ファイルのモードを保持する"
out="$(new_workdir)/p"
mkdir -p "$out/.ai-playbook"
printf 'old\n' > "$out/.ai-playbook/shared-ai-rules.md"
chmod 664 "$out/.ai-playbook/shared-ai-rules.md"
run_bootstrap "$out" --with-playbook --playbook-conflict-policy overwrite >/dev/null 2>&1
assert_mode "$out/.ai-playbook/shared-ai-rules.md" "664"

it "overwrite で内容は置き換わる"
grep -q 'AI 共通開発ガイドライン' "$out/.ai-playbook/shared-ai-rules.md" \
  && pass || fail "内容が上書きされていない"

exit_with_result
