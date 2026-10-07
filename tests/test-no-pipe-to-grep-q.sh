#!/usr/bin/env bash
# test-no-pipe-to-grep-q.sh — リポジトリ全体に「パイプの後ろの grep -q」が無いことを検証する。
#
# `set -o pipefail` の下で `producer | grep -q PAT` と書くと、grep が一致した時点で
# 終了し、生産側が SIGPIPE で失敗する。pipefail はそれをパイプ全体の失敗として扱うため、
# 「一致したのに不一致」と誤判定される。そうでなくても、生産側が
# `printf: write error: Broken pipe` を標準エラーへ出す（#470 の CI で bootstrap.sh の
# 配布スクリプトに実際に起きた。issue #471）。
#
# 直し方は `-q` を外して `>/dev/null` を付けること。-q が無ければ grep は入力を最後まで
# 読むので、生産側は SIGPIPE を受けない。終了コードは変わらず、否定の `!` もそのまま効く。
#
# 対象は、追跡ファイルの *.sh（bootstrap.sh・scripts/・tests/・packages/・
# .ai-playbook/templates/ を含む）と .github/workflows/*.yml。Markdown は対象外。
# packages/devcontainer-bootstrap/tests/test-no-pipe-to-grep-q.sh は同じ検出を
# DCB の tests/ に限って持つ（DCB のテストは単体で配布・実行できる必要があるため
# 残す）。検出の正規表現・除外・自己検査は同じものを使う。
#
# 検査は 2 つ持つ。(1) 実ファイルに該当が無いこと。(2) 該当を混ぜた一時ファイルでは
# 検出できること。(2) が無いと、検出の正規表現が壊れても (1) が黙って緑になる。
#
# このファイル自身が例として書くパターンで落ちないよう、検査対象の綴りは変数で組み立てる。
#
# bash 3.2 互換を維持する（mapfile を使わない）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-no-pipe-to-grep-q (repo-wide)"

G="gre"
G="${G}p"
BAR="|"

# パイプの直後（空白可）の grep が、-q を含む短いオプションの束または --quiet を持つ行。
# `||` の後ろは別のコマンドの連結なので除く（find_offenders 側で前置条件を持つ）。
PATTERN="[|][[:space:]]*${G}[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(-[A-Za-z]*q|--quiet)"

# find_offenders <ファイル...> — 該当行を「ファイル:行番号:本文」で出す。
# コメント行と `# bsd-ok:` を付けた行は除く。パイプで折り返した書き方（`x |` の
# 次の行が grep -q）も、前の行が単独のパイプで終わるときに「| 」を前置して拾う。
find_offenders() {
  local f
  for f in "$@"; do
    awk '
      { cont = (prev ~ /(^|[^|])[|][[:space:]]*\\?[[:space:]]*$/) }
      { print NR ":" (cont ? "| " : "") $0; prev = $0 }
    ' "$f" 2>/dev/null \
      | grep -E "^[0-9]+:(.*[^|])?$PATTERN" \
      | sed -E 's/^([0-9]+):\| /\1:/' \
      | grep -vE '^[0-9]+:[[:space:]]*#' \
      | grep -v '# bsd-ok:' \
      | sed "s|^|$f:|"
  done
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

it "追跡ファイルの *.sh と workflow の YAML に、パイプの後ろの grep -q が無い"
offenders=""
nfiles=0
while IFS= read -r rel; do
  [[ -f "$REPO_ROOT/$rel" ]] || continue
  nfiles=$((nfiles + 1))
  out="$(find_offenders "$REPO_ROOT/$rel")"
  [[ -n "$out" ]] && offenders="${offenders}${out#"$REPO_ROOT/"}
"
done < <(git -C "$REPO_ROOT" ls-files '*.sh' '.github/workflows/*.yml' '.github/workflows/*.yaml')
if [[ "$nfiles" -lt 50 ]]; then
  fail "対象ファイルが ${nfiles} 本しか拾えていない（git ls-files が働いていない）"
elif [[ -z "$offenders" ]]; then
  pass
else
  fail "pipefail 下で SIGPIPE により誤判定する形が残っている（-q を外して >/dev/null を付ける）:
$offenders"
fi

it "検出は -q の綴り違い（-qE / -Fxq / -q -- / --quiet）と行頭の空白を拾う"
tmp="$WORK/fixture.sh"
{
  printf '%s\n' "x | ${G} -q a"
  printf '%s\n' "x | ${G} -qE 'a|b'"
  printf '%s\n' "x | ${G} -Fxq a"
  printf '%s\n' "x | ${G} -q -- -a"
  printf '%s\n' "x | ${G} --quiet a"
  printf '%s\n' "x |${G} -q a"
  printf '%s\n' "x |"
  printf '%s\n' "  ${G} -q a"
  printf '%s\n' "x | \\"
  printf '%s\n' "  ${G} -qF a"
} > "$tmp"
found="$(find_offenders "$tmp" | wc -l | tr -d ' ')"
if [[ "$found" == "8" ]]; then pass; else fail "8 行を期待したが ${found} 行"; fi

it "検出は -q を持たない grep・連結の ||・コメント行・bsd-ok の行を拾わない"
tmp="$WORK/fixture-ok.sh"
{
  printf '%s\n' "x | ${G} a >/dev/null"
  printf '%s\n' "x | ${G} -E a"
  printf '%s\n' "x ${BAR}${BAR} ${G} -q a"
  printf '%s\n' "${G} -q a file"
  printf '%s\n' "x ${BAR}${BAR}"
  printf '%s\n' "  ${G} -q a file"
  printf '%s\n' "# x | ${G} -q a"
  printf '%s\n' "x | ${G} -q a  # bsd-ok: フィクスチャ"
} > "$tmp"
found="$(find_offenders "$tmp" | wc -l | tr -d ' ')"
if [[ "$found" == "0" ]]; then pass; else fail "0 行を期待したが ${found} 行"; fi

it "該当を 1 行だけ混ぜた一時ファイルは検出して落とす（検査が死んでいない）"
tmp="$WORK/fixture-one.sh"
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
