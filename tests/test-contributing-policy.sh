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

# ── 文書の主張と workflow の実態を突き合わせる ────────────────────────────────
#
# CONTRIBUTING.md は「fork からの PR で CI は通り、review-gate / copilot-review は
# 落ちる」と述べている。**その根拠は workflow の宣言である**（fork からの PR には
# 読み取り専用のトークンしか渡らず、secrets も渡らない）。
#
# **宣言が変われば文書は古くなる。** 数え上げた説明が実態から離れる形
# （`.ai-playbook/shared-ai-rules.md` 13 章 (c)）は `git grep` では拾えないので、
# ここで機械的に突き合わせる。

WF_DIR="$REPO_ROOT/.github/workflows"

# permissions_block <ファイル>
#   permissions: の配下だけを取り出す。**ファイル全体へ当ててはいけない。**
#   コメントや run: の中に `statuses: write` のような綴りがあり（実測: review-gate.yml に
#   3 箇所）、権限を外しても当たり続けて偽陰性になる。ブロックの終わりは、宣言より
#   浅いか同じ字下げの非空行で判定する。
permissions_block() {
  awk '
    /^[[:space:]]*permissions:[[:space:]]*$/ {
      inblock = 1
      indent = match($0, /[^ ]/)
      next
    }
    inblock {
      if ($0 ~ /^[[:space:]]*$/) next
      cur = match($0, /[^ ]/)
      if (cur <= indent) { inblock = 0; next }
      print
    }
  ' "$1"
}

# declares_write <ファイル>
#   permissions の配下で `: write` を宣言しているか。**判定はここ 1 つに置く。**
declares_write() {
  # **コメントを落としてから見る。** permissions の配下にも説明のコメントが書かれて
  # おり（実測: review-gate.yml）、そこに `: write` の綴りがあると権限と取り違える。
  { permissions_block "$1" | sed 's/#.*$//' | grep -nE ':[[:space:]]*write' || true; }
}

# uses_secrets <ファイル>
uses_secrets() {
  { grep -noE 'secrets\.[A-Z_]+' "$1" || true; }
}

it "CI が通るという主張の根拠: ci.yml が書き込み権限も secrets も要さない"
if [[ ! -f "$WF_DIR/ci.yml" ]]; then
  fail "ci.yml が無い（文書の主張の根拠が消えている）"
elif [[ -n "$(declares_write "$WF_DIR/ci.yml")" ]]; then
  fail "ci.yml が書き込み権限を宣言している。fork PR で通るという記述が古い: $(declares_write "$WF_DIR/ci.yml")"
elif [[ -n "$(uses_secrets "$WF_DIR/ci.yml")" ]]; then
  fail "ci.yml が secrets を参照している。fork PR で通るという記述が古い: $(uses_secrets "$WF_DIR/ci.yml")"
else
  pass
fi

it "落ちるという主張の根拠: review-gate / copilot-review が書き込み権限を要する"
MISSING_WRITE=""
for wf in review-gate.yml copilot-review.yml; do
  if [[ ! -f "$WF_DIR/$wf" ]]; then
    MISSING_WRITE="$MISSING_WRITE $wf(無い)"
  elif [[ -z "$(declares_write "$WF_DIR/$wf")" ]]; then
    MISSING_WRITE="$MISSING_WRITE $wf(書き込み権限を宣言していない)"
  fi
done
if [[ -z "$MISSING_WRITE" ]]; then
  pass
else
  fail "文書は落ちると述べているが、根拠が失われている:$MISSING_WRITE"
fi

it "同じ判定が、書き込み権限を宣言するものとしないものを区別する（対照群）"
# 「常に空」でも「常に当たる」でも上の 2 件は通ってしまう形にしないための対照群。
# ci.yml は宣言しない側、review-gate.yml は宣言する側で、同じ関数を通す。
if [[ -z "$(declares_write "$WF_DIR/ci.yml")" ]] && [[ -n "$(declares_write "$WF_DIR/review-gate.yml")" ]]; then
  pass
else
  fail "判定が区別できていない（ci.yml と review-gate.yml で同じ結果になった）"
fi

# fork からの PR に secrets が渡らない前提そのものを固定する。
it "pull_request_target を使っていない（fork PR へ secrets が渡る形を作らない）"
PRT="$( { grep -rln 'pull_request_target' "$WF_DIR" || true; } )"
if [[ -z "$PRT" ]]; then
  pass
else
  fail "pull_request_target を使っている: $PRT（fork PR へ secrets が渡るため、文書の前提が崩れる）"
fi

it "同じ判定が、コメントの中の write 指定を権限とみなさない（意図的な負例）"
# **この負例が無いと、ファイル全体へ grep する緩い実装と区別できない**（実測で踏んだ）。
# review-gate.yml にはコメント・run: の中に `statuses: write` 等が 3 箇所あり、
# 権限を read へ落としても当たり続ける。判定が permissions の配下だけを見ている
# ことを、ここで固定する。
FAKE="$(mktemp "${TMPDIR:-/tmp}/wf.XXXXXX")"
{
  printf '%s\n' 'name: fake'
  printf '%s\n' 'permissions:'
  printf '%s\n' '  contents: read'
  printf '%s\n' '  # `statuses: write` と書いてあるが、これはコメントである'
  printf '%s\n' 'jobs:'
  printf '%s\n' '  x:'
  printf '%s\n' '    steps:'
  printf '%s\n' '      - run: echo "statuses: write"'
} > "$FAKE"
FAKE_HITS="$(declares_write "$FAKE")"
rm -f "$FAKE"
if [[ -z "$FAKE_HITS" ]]; then
  pass
else
  fail "コメントや run: の中の綴りを権限とみなした: $FAKE_HITS"
fi

it "同じ判定が、permissions の配下の write は拾う（負例の対照群）"
FAKE2="$(mktemp "${TMPDIR:-/tmp}/wf.XXXXXX")"
{
  printf '%s\n' 'name: fake'
  printf '%s\n' 'permissions:'
  printf '%s\n' '  contents: read'
  printf '%s\n' '  statuses: write'
  printf '%s\n' 'jobs:'
} > "$FAKE2"
FAKE2_HITS="$(declares_write "$FAKE2")"
rm -f "$FAKE2"
if [[ -n "$FAKE2_HITS" ]]; then
  pass
else
  fail "permissions の配下の write を拾えなかった（判定が厳しすぎる）"
fi

exit_with_result
