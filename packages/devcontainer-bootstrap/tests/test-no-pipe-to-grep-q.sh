#!/usr/bin/env bash
# test-no-pipe-to-grep-q.sh — tests/ 配下に「パイプの後ろの grep -q」が無いことを検証する。
#
# `set -o pipefail` の下で `producer | grep -q PAT` と書くと、grep が一致した時点で
# 終了し、生産側が SIGPIPE で失敗する。pipefail はそれをパイプ全体の失敗として扱うため、
# 「一致したのに不一致」と誤判定される（CI で実際に起きた。issue #464）。生産側が小さい
# 間は書き込みが先に終わって再現しないので、環境や出力量で突然落ちる。
#
# 直し方は `-q` を外して `>/dev/null` を付けること。-q が無ければ grep は入力を最後まで
# 読むので、生産側は SIGPIPE を受けない。終了コードは変わらず、否定の `!` もそのまま効く。
#
# 検査は 2 つ持つ。(1) 実ファイルに該当が無いこと。(2) 該当を混ぜた一時ファイルでは
# 検出できること。(2) が無いと、検出の正規表現が壊れても (1) が黙って緑になる。
#
# このファイル自身が例として書くパターンで落ちないよう、検査対象の綴りは変数で組み立てる
# （リテラルを書くと自分自身が該当する）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-no-pipe-to-grep-q"

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 検査対象の綴りを分割して持つ（このファイルの行が自分の検出に掛からないようにする）
G="gre"
G="${G}p"
BAR="|"

# パイプの直後（空白可）の grep が、-q を含む短いオプションの束または --quiet を持つ行。
# `||` の後ろは別のコマンドの連結なので除く（先頭がパイプ 1 本のものだけを対象にする）。
# `# bsd-ok:` を付けた行（検出器のフィクスチャとして綴りを持つ行）とコメント行は除く。
PATTERN="(^|[^|])[|][[:space:]]*${G}[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(-[A-Za-z]*q|--quiet)"

# find_offenders <ファイル...> — 該当行を「ファイル:行番号:本文」で出す。
find_offenders() {
  local f
  for f in "$@"; do
    grep -nE "$PATTERN" "$f" 2>/dev/null \
      | grep -vE '^[0-9]+:[[:space:]]*#' \
      | grep -v '# bsd-ok:' \
      | sed "s|^|$f:|"
  done
}

it "tests/ 配下の *.sh に、パイプの後ろの grep -q が無い"
offenders="$(find_offenders "$TESTS_DIR"/*.sh)"
if [[ -z "$offenders" ]]; then
  pass
else
  fail "pipefail 下で SIGPIPE により誤判定する形が残っている（-q を外して >/dev/null を付ける）:
$offenders"
fi

it "検出は -q の綴り違い（-qE / -Fq / -q -- / --quiet）と行頭の空白を拾う"
tmp="$(new_workdir)/fixture.sh"
{
  printf '%s\n' "x | ${G} -q a"
  printf '%s\n' "x | ${G} -qE 'a|b'"
  printf '%s\n' "x | ${G} -Fq a"
  printf '%s\n' "x | ${G} -q -- -a"
  printf '%s\n' "x | ${G} --quiet a"
  printf '%s\n' "x |${G} -q a"
} > "$tmp"
found="$(find_offenders "$tmp" | wc -l | tr -d ' ')"
if [[ "$found" == "6" ]]; then pass; else fail "6 行を期待したが ${found} 行"; fi

it "検出は -q を持たない grep・連結の ||・コメント行・bsd-ok の行を拾わない"
tmp="$(new_workdir)/fixture-ok.sh"
{
  printf '%s\n' "x | ${G} a >/dev/null"
  printf '%s\n' "x | ${G} -E a"
  printf '%s\n' "x ${BAR}${BAR} ${G} -q a"
  printf '%s\n' "${G} -q a file"
  printf '%s\n' "# x | ${G} -q a"
  printf '%s\n' "x | ${G} -q a  # bsd-ok: フィクスチャ"
} > "$tmp"
found="$(find_offenders "$tmp" | wc -l | tr -d ' ')"
if [[ "$found" == "0" ]]; then pass; else fail "0 行を期待したが ${found} 行"; fi

it "該当を 1 行だけ混ぜた一時ファイルは検出して落とす（検査が死んでいない）"
tmp="$(new_workdir)/fixture-one.sh"
{
  printf '%s\n' 'echo ok'
  printf '%s\n' "printf '%s' \"\$x\" | ${G} -q foo"
  printf '%s\n' 'echo done'
} > "$tmp"
found="$(find_offenders "$tmp")"
case "$found" in
  *":2:"*) pass ;;
  *) fail "2 行目が検出されない: ${found}" ;;
esac

exit_with_result
