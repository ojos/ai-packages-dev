#!/usr/bin/env bash
# 衝突ポリシーと dry-run を検証する。
#
# dry-run が「配置する」と言った内容と実際の書き込みが一致しない状態は、
# 利用者が計画を信用できなくなることを意味する。v0.2.0 では dry-run は 16 件を
# 計画したが実際には 0 件しか配置されなかった。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-conflict-and-dryrun"

# ── 衝突ポリシー ──────────────────────────────────────────────────────────────

it "skip（既定）は既存ファイルを保護する"
out="$(new_workdir)/p"
mkdir -p "$out/.ai-playbook"
printf 'CUSTOM\n' > "$out/.ai-playbook/shared-ai-rules.md"
run_bootstrap "$out" --with-playbook >/dev/null 2>&1
assert_eq "$(cat "$out/.ai-playbook/shared-ai-rules.md")" "CUSTOM" "既存ファイルの内容"

it "skip でも未配置のファイルは配置される"
assert_file_exists "$out/.ai-playbook/role-contracts/planner.md"

it "overwrite は既存ファイルを置き換える"
out="$(new_workdir)/p"
mkdir -p "$out/.ai-playbook"
printf 'CUSTOM\n' > "$out/.ai-playbook/shared-ai-rules.md"
run_bootstrap "$out" --with-playbook --playbook-conflict-policy overwrite >/dev/null 2>&1
if grep -q 'CUSTOM' "$out/.ai-playbook/shared-ai-rules.md"; then
  fail "上書きされていない"
else
  pass
fi

it "不正な衝突ポリシーは拒否される"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --playbook-conflict-policy bogus 2>&1)"
code=$?
if [[ $code -ne 0 ]]; then
  assert_contains "$output" "must be one of" "エラー出力"
else
  fail "不正なポリシーが通ってしまった"
fi

it "不正な衝突ポリシーは副作用を残さない"
assert_file_absent "$out"

# ── dry-run ───────────────────────────────────────────────────────────────────

it "dry-run はファイルを書き込まない"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-playbook --dry-run >/dev/null 2>&1
assert_file_absent "$out"

it "dry-run の計画と実際の書き込みが一致する"
# plan: 行には出力先パス以外の情報行も混じるため、出力ディレクトリ配下の
# パスを示す行だけを対象にする。.gitignore は追記更新で扱いが異なるため除く。
base="$(new_workdir)"
planned="$(run_bootstrap "$base/p" --with-playbook --dry-run 2>/dev/null \
  | sed -n "s|^plan: $base/p/||p" \
  | grep -v '^\.gitignore' \
  | sort)"
run_bootstrap "$base/p" --with-playbook >/dev/null 2>&1
actual="$(cd "$base/p" && find . -type f | sed 's|^\./||' | grep -v '^\.gitignore$' | sort)"
if [[ "$planned" == "$actual" ]]; then
  pass
else
  fail "計画と実際が不一致:
$(diff <(printf '%s\n' "$planned") <(printf '%s\n' "$actual") | head -10)"
fi

it "dry-run でもソース不在は検出される"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-playbook --playbook-from /nonexistent --dry-run >/dev/null 2>&1
assert_eq "$?" "1" "終了コード"

exit_with_result
