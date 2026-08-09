#!/usr/bin/env bash
# project-ai-rules.md の第二意見オプション表が、second-opinion-review.sh の実装と一致して
# いることを検査する。
#
# この表は規範側に置かれた実装の写しで、ローカル事前ゲートの第二意見をどう調整
# できるかを人が知る唯一の一覧になっている。オプションや環境変数を実装へ足した
# ときに表を更新し忘れると、使える調整が規範から見えないまま残る。逆に表から
# 消し忘れると、存在しない指定が規範として案内され続ける。どちらも目視では
# 気づけないため機械で突き合わせる。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-review-options"

RULES="$REPO_ROOT/.github/project-ai-rules.md"
REVIEW="$REPO_ROOT/scripts/second-opinion-review.sh"

# ── 規範側 ────────────────────────────────────────────────────────────────────

table_rows() {
  awk '
    /^\| オプション \| 環境変数 \| 既定 \| 意味 \|/ { inside = 1; next }
    inside && /^\|/ { print }
    inside && !/^\|/ { exit }
  ' "$RULES" | grep -v '^|---'
}

ROWS="$(table_rows)"

it "project-ai-rules に第二意見オプション表がある"
if [[ -n "$ROWS" ]]; then pass; else fail "第二意見オプション表を抽出できなかった"; fi

# オプション列は `--runs <n>` の形で書かれる。引数のプレースホルダを落として
# オプション名だけにする。
DOC_OPTS="$(printf '%s\n' "$ROWS" | awk -F'|' '{print $2}' | grep -o '`--[a-z-]*' | tr -d '`' | sort -u)"

# 環境変数列。対応する環境変数を持たないオプションの欄は — で、抽出結果は空になる。
DOC_ENVS="$(printf '%s\n' "$ROWS" | awk -F'|' '{print $3}' | grep -oE 'SECOND_OPINION_[A-Z_]+' | sort -u)"

# 旧名（後方互換で受理する環境変数）は表ではなく本文の箇条書きが持つ。表に載せると
# 「これも正の指定方法」に見えるが、実際は移行のための受け皿でしかない。ただし
# 実装が受理する旧名と本文の記述がずれると、消えた互換が案内され続ける（逆も同じ）
# ため、表とは別の集合として照合する。
DOC_LEGACY_ENVS="$(grep -oE 'GEMINI_REVIEW_[A-Z_]+' "$RULES" | sort -u)"

# --runs の既定値。表の既定列に書かれた値をそのまま取る。
DOC_RUNS_DEFAULT="$(printf '%s\n' "$ROWS" | awk -F'|' '$2 ~ /--runs/ {print $4}' | grep -o '`[^`]*`' | tr -d '`' | head -n 1)"

# --engine の既定値。エンジンの既定が変わると、どの CLI で第二意見を取っているかが
# 黙って変わる。認証手段ごと変わるため、値まで見る。
DOC_ENGINE_DEFAULT="$(printf '%s\n' "$ROWS" | awk -F'|' '$2 ~ /--engine/ {print $4}' | grep -o '`[^`]*`' | tr -d '`' | head -n 1)"

# ── 実装側 ────────────────────────────────────────────────────────────────────

# 引数解析の case 分岐からオプションを取る。-h / --help は表の対象外とする。
# この表は「第二意見の挙動を変える指定」の一覧で、ヘルプ表示は全スクリプト共通の
# 慣行だから載っていない。除外をここに明示しておかないと、次に表を読む人が
# 「載せ忘れ」と誤解して表へ足し、この検査が落ちる。
IMPL_OPTS="$(sed -n '/^while \[\[ \$# -gt 0 \]\]; do/,/^done$/p' "$REVIEW" \
  | grep -v '^[[:space:]]*#' \
  | grep -oE '^[[:space:]]+--[a-z-]+\)' \
  | tr -d ' )' \
  | grep -v '^--help$' \
  | sort -u)"

# 実装が読む環境変数。変数参照（$ 始まり。波括弧は任意）だけを拾い、行頭コメントは
# 落とす。
#
# 変数名の出現をそのまま数えると、usage() のヘルプ文言やコメントで名前に言及して
# いるだけの箇所まで「実装が読んでいる」ことになる。その形だと、実装が env を
# 読まなくなってもヘルプに名前が残っている限り緑のままで、規範と実装の乖離を
# 検出するというこのテストの目的を満たさない。
#
# 波括弧を必須にしないのは逆向きの取りこぼしを防ぐため。$GEMINI_REVIEW_X の形で
# 追加された変数を拾えないと、文書に無い変数が実装に増えても両者の集合が一致した
# ままになり、検出できない。数字を含む変数名も同じ理由で許す。
#
# GEMINI_API_KEY はここでは対象にしない。表の環境変数列は「オプションを環境変数
# でも指定できる」対応関係の一覧であって、実行前提そのものではない。前提は表の
# 下の箇条書きが扱っている。
IMPL_ENVS="$(grep -v '^[[:space:]]*#' "$REVIEW" \
  | grep -oE '\$\{?SECOND_OPINION_[A-Z0-9_]+' \
  | sed -E 's/^\$\{?//' \
  | sort -u)"

# 実装が後方互換で受理する旧名。
IMPL_LEGACY_ENVS="$(grep -v '^[[:space:]]*#' "$REVIEW" \
  | grep -oE '\$\{?GEMINI_REVIEW_[A-Z0-9_]+' \
  | sed -E 's/^\$\{?//' \
  | sort -u)"

# 実装の既定値。RUNS の解決は新名 → 旧名 → 既定の入れ子なので、行中の最後の整数を取る。
# 対象は代入行（RUNS="..."）に限る。基数固定の RUNS=$((10#$RUNS)) を含めると、
# そちらの 10 を既定値として拾ってしまう。
IMPL_RUNS_DEFAULT="$(grep -E '^RUNS="' "$REVIEW" | grep -oE '[0-9]+' | tail -n 1)"

# 実装のエンジン既定。${SECOND_OPINION_ENGINE:-name} の name を取る。
IMPL_ENGINE_DEFAULT="$(grep -oE 'ENGINE="\$\{SECOND_OPINION_ENGINE:-[a-z]+\}"' "$REVIEW" \
  | sed -E 's/.*:-([a-z]+)\}"/\1/' | head -n 1)"

# ── 照合 ──────────────────────────────────────────────────────────────────────

it "オプションの一覧が規範と実装で一致する"
assert_same_set "$DOC_OPTS" "$IMPL_OPTS" "project-ai-rules" "second-opinion-review.sh"

it "環境変数の一覧が規範と実装で一致する"
assert_same_set "$DOC_ENVS" "$IMPL_ENVS" "project-ai-rules" "second-opinion-review.sh"

it "後方互換で受理する旧名の環境変数が規範と実装で一致する"
# 旧名を実装から外したのに規範が案内し続ける（設定しても効かない）、逆に実装だけが
# 受理して規範に無い（移行期限が読めない）、のどちらも起きうる。
assert_same_set "$DOC_LEGACY_ENVS" "$IMPL_LEGACY_ENVS" "project-ai-rules" "second-opinion-review.sh"

it "--engine の既定値が規範と実装で一致する"
# 既定のエンジンが変わると、どの CLI で第二意見を取るかが黙って変わる。認証手段も
# 一緒に変わるため、集合の照合では足りない。
if [[ -z "$IMPL_ENGINE_DEFAULT" ]]; then
  fail "second-opinion-review.sh から --engine の既定値を抽出できなかった"
else
  assert_eq "$DOC_ENGINE_DEFAULT" "$IMPL_ENGINE_DEFAULT" "--engine の既定値"
fi

it "--runs の既定値が規範と実装で一致する"
# 既定値の乖離は集合の照合では捕まらない。「回数を増やしたつもりで既定のまま」
# という誤解に直結するため、値まで見る。
if [[ -z "$IMPL_RUNS_DEFAULT" ]]; then
  fail "second-opinion-review.sh から --runs の既定値を抽出できなかった"
else
  assert_eq "$DOC_RUNS_DEFAULT" "$IMPL_RUNS_DEFAULT" "--runs の既定値"
fi

exit_with_result
