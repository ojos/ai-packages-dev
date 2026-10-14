#!/usr/bin/env bash
# ブランチ名から issue 番号を取る規則が、2 つの仕組みで同じであることを照合する。
#
#   セッション協調のフック: scripts/session-coord-hook.sh の ISSUE_BRANCH_RE
#   第二意見              : scripts/second-opinion-review.sh と
#                           .ai-playbook/templates/second-opinion-review.sh の BRANCH_ISSUE_RE
#
# 2 つは別のパッケージ（DCB の生成物と ai-playbook）なので実装は共有しない。食い違えば
# 利用者がどちらの形で枝を切っても同じ番号を読む、という約束が黙って崩れるため、
# 同じ見本を両方の規則に通して一致を確かめる（shared-ai-rules 12 章「一覧の複製は機械照合で担保する」）。
# 規則は各ファイルから取り出して使い、このテストへ写さない。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-branch-issue-regex"

HOOK="$REPO_ROOT/scripts/session-coord-hook.sh"
REVIEW_COPY="$REPO_ROOT/scripts/second-opinion-review.sh"
REVIEW_TEMPLATE="$REPO_ROOT/.ai-playbook/templates/second-opinion-review.sh"

# 1 行の単一引用符つき代入 NAME='...' から値を取り出す。
extract_re() { # ファイル 変数名
  sed -n "s/^$2='\\(.*\\)'\$/\\1/p" "$1" | head -n 1
}

# 規則 re で枝 b から番号を取る（取れなければ空）。判定は両実装と同じ最初の一致の 3 つ目の括弧。
number_by() { # 規則 ブランチ名
  if [[ "$2" =~ $1 ]]; then printf '%s' "${BASH_REMATCH[3]}"; fi
}

HOOK_RE="$(extract_re "$HOOK" ISSUE_BRANCH_RE)"
COPY_RE="$(extract_re "$REVIEW_COPY" BRANCH_ISSUE_RE)"
TEMPLATE_RE="$(extract_re "$REVIEW_TEMPLATE" BRANCH_ISSUE_RE)"

it "3 つのファイルから規則を取り出せる"
if [[ -n "$HOOK_RE" && -n "$COPY_RE" && -n "$TEMPLATE_RE" ]]; then
  pass
else
  fail "取り出せない: hook='$HOOK_RE' copy='$COPY_RE' template='$TEMPLATE_RE'"
fi

# ブランチ名<TAB>期待する番号（空は取れない）
# 末尾の 2 つは、日付を番号と読む既知の限界（second-opinion-review.sh の冒頭の説明）。
# 両方の仕組みが同じく読むことを固定し、規則を締めるときに、どの形の扱いが変わるかを示す。
SAMPLES=$'feat/123-x\t123
123-x\t123
issue-123\t123
gh-123_x\t123
fix/issue-45-y\t45
feat/sub/123-x\t123
123\t123
feat/123\t123
main\t
feature/no-number\t
feat/0123-x\t
0-x\t
feat/1234567-x\t
feat/123abc\t
release-123\t
fix/589-shellcheck\t589
2026-10-14-hotfix\t2026
user/alice/2026_q4\t2026'

while IFS=$'\t' read -r branch expected; do
  it "枝 '$branch' はフックと第二意見（写し・雛形）で同じ番号 '${expected:-なし}' になる"
  h="$(number_by "$HOOK_RE" "$branch")"
  c="$(number_by "$COPY_RE" "$branch")"
  t="$(number_by "$TEMPLATE_RE" "$branch")"
  if [[ "$h" == "$c" && "$h" == "$t" && "$h" == "$expected" ]]; then
    pass
  else
    fail "hook='$h' copy='$c' template='$t' 期待='$expected'"
  fi
done <<< "$SAMPLES"

it "規則そのものが 3 つで一致している"
if [[ "$HOOK_RE" == "$COPY_RE" && "$HOOK_RE" == "$TEMPLATE_RE" ]]; then
  pass
else
  fail "hook='$HOOK_RE' copy='$COPY_RE' template='$TEMPLATE_RE'"
fi

exit_with_result
