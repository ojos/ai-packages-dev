#!/usr/bin/env bash
# CONTRIBUTING.md が「外部 PR を受け付けない」方針を述べていることを機械照合する。
#
# ## なぜ要るか
#
# この方針は identity-guard（既定ブランチの author を許可した identity に限定する機構）
# と対になっている。**文書の側だけが消えると、外部の人は赤いチェックや保留の理由を
# 推測することになる。** 方針を緩める判断をするときは、この検査も一緒に直すことになり、
# 「文書だけ消える」経路を塞ぐ。
#
# ## この検査が見ないこと
#
# **方針が正しいかは見ない。** 述べられているかだけを見る。方針の変更は人の判断であり、
# そのときはこの検査の期待値も変える。
#
# 依存はコアユーティリティ（grep）のみ。bash 3.2 互換を維持する。

set -uo pipefail
export LC_ALL=C
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-contributing-policy"

DOC="$REPO_ROOT/CONTRIBUTING.md"

# states <ファイル> <固定文字列>
#   その文字列を含む行を列挙する。**判定はここ 1 つに置き、本番の文書と負例を
#   同じ経路へ通す。** 0 件は正常な結果になりうるので、grep の終了コードを畳む。
states() {
  { grep -nF "$2" "$1" || true; }
}

it "CONTRIBUTING.md がある"
if [[ -f "$DOC" ]]; then
  pass
else
  fail "CONTRIBUTING.md が無い（外部 PR の方針を述べる場所が消えている）"
fi

# 述べていなければならない要素。**一覧を書き写すだけにしない**ため、下で
# 「負例には 1 つも当たらない」ことも確かめる。
REQUIRED='Pull Request を受け付けていません
issue は歓迎
identity-guard.yml'

while IFS= read -r phrase; do
  [[ -z "$phrase" ]] && continue
  it "方針の要素「$phrase」を述べている"
  if [[ -n "$(states "$DOC" "$phrase")" ]]; then
    pass
  else
    fail "CONTRIBUTING.md が「$phrase」を述べていない"
  fi
done <<REQEOF
$REQUIRED
REQEOF

it "同じ判定が、方針を述べていない文書には当たらない（意図的な負例）"
# 「判定が存在する」ことと「判定が効いている」ことは別である。方針を書いていない
# 文書を同じ関数へ通し、1 つも当たらないことを見る。フィクスチャ側で grep を
# 書き直すと、判定を無効化しても緑を返す。
NEG="$(mktemp "${TMPDIR:-/tmp}/contrib.XXXXXX")"
printf '%s\n' '# 貢献について' 'PR をお待ちしています。お気軽にどうぞ。' > "$NEG"
NEG_HITS=0
while IFS= read -r phrase; do
  [[ -z "$phrase" ]] && continue
  [[ -n "$(states "$NEG" "$phrase")" ]] && NEG_HITS=$((NEG_HITS + 1))
done <<REQEOF2
$REQUIRED
REQEOF2
rm -f "$NEG"
if [[ "$NEG_HITS" -eq 0 ]]; then
  pass
else
  fail "方針を述べていない文書へ $NEG_HITS 件当たった（判定が緩すぎる）"
fi

it "同じ判定が、要素を 1 つでも欠いた文書を見逃さない（意図的な負例）"
# 全要素を書いた文書から 1 つだけ削り、当たる件数が減ることを見る。
# 「どれかがあれば緑」の形になっていないことの固定である。
PARTIAL="$(mktemp "${TMPDIR:-/tmp}/contrib.XXXXXX")"
{
  printf '%s\n' 'Pull Request を受け付けていません'
  printf '%s\n' 'issue は歓迎します'
} > "$PARTIAL"
PARTIAL_HITS=0
while IFS= read -r phrase; do
  [[ -z "$phrase" ]] && continue
  [[ -n "$(states "$PARTIAL" "$phrase")" ]] && PARTIAL_HITS=$((PARTIAL_HITS + 1))
done <<REQEOF3
$REQUIRED
REQEOF3
rm -f "$PARTIAL"
REQ_COUNT="$(printf '%s\n' "$REQUIRED" | grep -c . || true)"
if [[ "$PARTIAL_HITS" -lt "$REQ_COUNT" ]]; then
  pass
else
  fail "1 要素を欠いた文書でも全 $REQ_COUNT 件当たった（要素ごとに見ていない）"
fi

exit_with_result
