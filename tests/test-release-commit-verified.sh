#!/usr/bin/env bash
# 配ろうとしているコミットの CI が緑で完了しているかの判定の回帰テスト。
#
# ## なぜ要るか
#
# release.yml は actions/checkout に ref を渡さないため、起動時点の main の head を
# そのまま配る。ci.yml は push: branches: [main] で走るので、マージで生まれた
# コミットには新しい実行が作られる。**その実行が終わる前に起動すると、検証されて
# いない内容を公開する。**
#
# これまでこの窓を塞いでいたのは手順書の文章だけだった。
#
# ## 合図だけでなく「赤くなった理由」を見る
#
# **UNVERIFIED と rc=1 だけを見ると、3 つの赤（実行なし / 未完了 / 結論が success で
# ない）を区別できない。** 区別しないまま緑を並べると、「success 以外はすべて赤」へ
# 潰す変異が通ってしまう——これは ojos/ai-packages-dev#334 で踏んだ
# 「アサーションが、区別したい 2 つの状態を区別していない」と同じ形である。
#
# したがって赤の各件で、**その赤に固有の理由の行**まで突き合わせる。
#
# ## 判定は本番と同じ関数を通す
#
# 検査本体を source して judge_release_commit を呼ぶ。**フィクスチャ側で同じ判断を
# 書き直さない**（ojos/ai-packages-dev#328 で、負例が判定を自前で書き直していたため
# 本番の判定を無効化しても緑のままだった）。
#
# 依存はコアユーティリティのみ。bash 3.2 互換を維持する。

set -uo pipefail
export LC_ALL=C
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-release-commit-verified"

# ── 判定の本体を本番から取り込む（負例もここを通る）──────────────────────────
. "$REPO_ROOT/scripts/check-release-commit-verified.sh"

# run_judge <入力>
#   判定を呼び、標準出力と終了コードを大域へ置く。標準エラーは混ぜない
#   （形の崩れた行の報告は stderr で、合図とは別の経路であることを保つ）。
JUDGE_OUT=""
JUDGE_RC=0
run_judge() {
  JUDGE_OUT="$(printf '%s' "$1" | judge_release_commit 2>/dev/null)"
  JUDGE_RC=$?
}

# signal_line
#   合図（最終行）。何も出ていなければ空を返す。
signal_line() {
  printf '%s\n' "$JUDGE_OUT" | awk 'NF { last = $0 } END { print last }'
}

# has_line <部分文字列>
#   判定の出力にその文言を含む行があるか。あれば yes。
#
# **grep をパイプの読み手に置かない**（pipefail 下で SIGPIPE により反転する）。
has_line() {
  awk -v needle="$1" 'index($0, needle) { found = 1 } END { print (found ? "yes" : "no") }' \
    <<< "$JUDGE_OUT"
}

# ── 緑になる入力 ──────────────────────────────────────────────────────────────

it "success 1 件なら緑"
run_judge '101 completed success'
assert_eq "$(signal_line)/$JUDGE_RC" "RELEASE_COMMIT_VERIFIED/0" "合図と終了コード"

it "緑のとき、最新として選んだ実行を示す"
run_judge '101 completed success'
assert_eq "$(has_line '最新の実行: id=101 conclusion=success')" "yes" "最新の実行の表示"

it "再実行で緑にした場合は通す（failure のあと success）"
run_judge '101 completed failure
102 completed success'
assert_eq "$(signal_line)/$JUDGE_RC" "RELEASE_COMMIT_VERIFIED/0" "合図と終了コード"

# ── 赤になる入力（理由まで区別する）──────────────────────────────────────────

it "failure 1 件なら赤"
run_judge '101 completed failure'
assert_eq "$(signal_line)/$JUDGE_RC" "RELEASE_COMMIT_UNVERIFIED/1" "合図と終了コード"

it "failure の赤は「結論が success でない」を理由に出す"
run_judge '101 completed failure'
assert_eq "$(has_line '最新の実行が success ではありません')" "yes" "赤の理由"

it "cancelled 1 件なら赤"
run_judge '101 completed cancelled'
assert_eq "$(signal_line)/$JUDGE_RC" "RELEASE_COMMIT_UNVERIFIED/1" "合図と終了コード"

it "実行が 1 件も無ければ赤"
run_judge ''
assert_eq "$(signal_line)/$JUDGE_RC" "RELEASE_COMMIT_UNVERIFIED/1" "合図と終了コード"

it "実行なしの赤は「1 件もありません」を理由に出す（未完了・failure と区別する）"
run_judge ''
assert_eq "$(has_line '実行が 1 件もありません')" "yes" "赤の理由"

it "未完了が混ざれば、他が success でも赤"
run_judge '101 completed success
102 in_progress -'
assert_eq "$(signal_line)/$JUDGE_RC" "RELEASE_COMMIT_UNVERIFIED/1" "合図と終了コード"

it "未完了の赤は件数つきの理由を出す（実行なし・failure と区別する）"
run_judge '101 completed success
102 in_progress -'
assert_eq "$(has_line '完了していない実行が 1 件あります')" "yes" "赤の理由"

it "再実行で赤くなった場合は止める（success のあと failure）"
run_judge '101 completed success
102 completed failure'
assert_eq "$(signal_line)/$JUDGE_RC" "RELEASE_COMMIT_UNVERIFIED/1" "合図と終了コード"

# ── 最新の選び方（呼び出し側の並びに依存しない）──────────────────────────────

it "入力の並びが逆でも、実行 ID の大きいほうを最新とする"
run_judge '102 completed failure
101 completed success'
assert_eq "$(has_line '最新の実行: id=102 conclusion=failure')" "yes" "最新の選択"

it "実行 ID は数値として比べる（桁数が違っても取り違えない）"
run_judge '9 completed failure
10 completed success'
assert_eq "$(has_line '最新の実行: id=10 conclusion=success')" "yes" "最新の選択"

# ── 入力の形 ──────────────────────────────────────────────────────────────────

it "形の崩れた行があれば、何も判定せず 2 で終わる"
run_judge 'abc completed success'
assert_eq "$JUDGE_RC" "2" "終了コード"

it "形が崩れているときは合図を出さない（赤の合図と取り違えない）"
run_judge 'abc completed success'
assert_eq "$(signal_line)" "" "合図"

it "一部だけ崩れていても、崩れていない行を判定して通さない"
run_judge '101 completed success
これは行ではない'
assert_eq "$JUDGE_RC" "2" "終了コード"

it "行末の CR を落として判定する"
run_judge "$(printf '101 completed success\r')"
assert_eq "$(signal_line)/$JUDGE_RC" "RELEASE_COMMIT_VERIFIED/0" "合図と終了コード"

# ── 配線（release.yml がこの判定を実際に通るか）──────────────────────────────
#
# **判定スクリプトの単体検査だけでは、配線が外れたことに気づけない。** 変異の網は
# フィクスチャが到達する範囲しか覆わないので、ワークフロー側の記述もここで見る。
# 見るのは綴りの一致ではなく、**判定へ到達する経路が保たれているか**である。

RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"

# yml_has <部分文字列>
#   release.yml にその文言を含む行があるか。
yml_has() {
  awk -v needle="$1" 'index($0, needle) { found = 1 } END { print (found ? "yes" : "no") }' \
    "$RELEASE_YML"
}

# yml_line_of <部分文字列>
#   最初に一致した行の番号。無ければ 0。
yml_line_of() {
  awk -v needle="$1" 'index($0, needle) { print NR; exit } END { if (!NR) print 0 }' \
    "$RELEASE_YML"
}

it "release.yml が判定スクリプトを呼ぶ"
assert_eq "$(yml_has 'bash scripts/check-release-commit-verified.sh')" "yes" "呼び出し"

it "実行の一覧を読む権限がある（actions: read）"
assert_eq "$(yml_has 'actions: read')" "yes" "permissions"

it "判定は execute: true のときだけ走る（dry-run は任意のブランチで回せる）"
assert_eq "$(yml_has 'if: inputs.execute')" "yes" "if 条件"

it "判定は ci.yml の実行だけを対象にする"
assert_eq "$(yml_has 'select(.path == ".github/workflows/ci.yml")')" "yes" "jq の絞り込み"

it "判定は、外部状態へ触れるトークン発行より前に置く"
JUDGE_AT="$(yml_line_of 'bash scripts/check-release-commit-verified.sh')"
TOKEN_AT="$(yml_line_of 'Generate a release bot token')"
if [[ "$JUDGE_AT" -gt 0 && "$TOKEN_AT" -gt 0 && "$JUDGE_AT" -lt "$TOKEN_AT" ]]; then
  assert_eq "ok" "ok" "順序"
else
  assert_eq "判定=$JUDGE_AT / トークン発行=$TOKEN_AT" "判定がトークン発行より前" "順序"
fi

exit_with_result
