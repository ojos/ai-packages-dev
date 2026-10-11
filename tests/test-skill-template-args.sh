#!/usr/bin/env bash
# Claude Code のスキルの本文に、引数で置き換えられる「$数字」が無いことを検査する。
#
# ## 背景
#
# Claude Code は、スキルを起動するとき、本文の「$ の直後に数字」（`/\$(\d+)(?!\w)/`）を、
# 0 から数えた引数に置き換える（その番号の引数が無ければ、そのまま残す）。land スキルの雛形の
# awk に書いた `$0` が、`/land 29` で起動したときに `29` に置き換わり、CI の待ちが誤動作した
# （利用側のプロジェクトからの報告。ファイルの中身は正しく、スキルとして読み込んだ本文だけが壊れる）。
# 引数を 2 つ渡せば、`$1` などの awk の欄や、シェルの関数の引数も同じく置き換わる。
#
# 雛形では、awk の欄を `$(0)` の形、シェルの引数を `${1}` の形で書く。どちらも置き換えの規則に
# 一致しないので、スキルとして読み込んでも、ファイルから取り出して実行しても、同じに動く。
#
# バックスラッシュを付けた `\$0` は置き換えられない。Claude Code は `$数字` を置き換える前に、
# 直前にバックスラッシュの無い `\$`（`$` の前に `\`）に数字などが続くものを退避用の印へ
# 置き換え、置き換えのあとで `$` に戻す（Claude Code 2.1.296 の実装で確認。正規表現は
# `(?<!\\)\\\$(?=\d|ARGUMENTS|…)`）。ただし、ファイルの中身にもバックスラッシュが残り、
# ファイルから取り出して実行するテストで壊れるため、雛形では使わない。この検査も、その形を
# 置き換えられないものとして拾わない（Claude Code と同じ扱い）。
#
# ## 対象
#
#   .ai-playbook/templates/claude-skill-*.md（雛形）と .claude/skills/*/SKILL.md（写し）。
#   同じ置き換えを受けるスラッシュコマンド（.claude/commands/*.md と、その雛形
#   .ai-playbook/templates/claude-command-*.md）も対象にする（いまは無い）。
#
# 名前を決め打ちせず、ディレクトリを走査する（新しいスキルを足しても、この検査が追随する）。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0
RUN=0

echo "test-skill-template-args"

# ファイルの中で、置き換えの規則に一致する「$数字」を含む行を「行番号: 行」で出す。
# 規則は `\$(\d+)(?!\w)`。ただし Claude Code は、直前がバックスラッシュ 1 つの `\$` は置き換えない
# （バックスラッシュが 2 つ続く `\\$` は退避されず、置き換えられる）。
# grep -P は BSD 系に無いので、awk で同じ判定をする。
find_args() { # ファイル
  awk '
    {
      line = $(0); rest = line
      while (match(rest, /\$[0-9]+/)) {
        pre = (RSTART > 1) ? substr(rest, RSTART - 1, 1) : ""
        pre2 = (RSTART > 2) ? substr(rest, RSTART - 2, 1) : ""
        escaped = (pre == "\\" && pre2 != "\\")
        nxt = substr(rest, RSTART + RLENGTH, 1)
        if (!escaped && nxt !~ /[A-Za-z0-9_]/) { print NR ": " line; break }
        rest = substr(rest, RSTART + RLENGTH)
      }
    }' "$1"
}

files=()
while IFS= read -r f; do files+=("$f"); done < <(
  cd "$ROOT" && {
    ls .ai-playbook/templates/claude-skill-*.md .ai-playbook/templates/claude-command-*.md 2>/dev/null
    ls .claude/skills/*/SKILL.md .claude/commands/*.md 2>/dev/null
  } | sort
)

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "  FAIL スキルの雛形も写しも見つからない（走査の誤り）"
  exit 1
fi

for f in "${files[@]}"; do
  RUN=$((RUN + 1))
  hits="$(find_args "$ROOT/$f")"
  if [[ -z "$hits" ]]; then
    echo "  ok   $f に、引数で置き換えられる \$数字 が無い"
  else
    FAILED=$((FAILED + 1))
    echo "  FAIL $f に、引数で置き換えられる \$数字 がある（awk の欄は \$(0)、シェルの引数は \${1} の形で書く）"
    printf '%s\n' "$hits" | sed 's/^/       /'
  fi
done

# 判定そのものの自己試験。置き換えられる形を拾い、置き換えられない形を拾わないこと。
RUN=$((RUN + 1))
probe="$(mktemp "${TMPDIR:-/tmp}/skill-args.XXXXXX")"
printf '%s\n' 'v = $0;' 'x = $(0); y = ${1}; z = \$3; w = $ARGUMENTS; q = $1a' 'u = \\$4;' >"$probe"
got="$(find_args "$probe")"
rm -f "$probe"
want="$(printf '%s\n' '1: v = $0;' '3: u = \\$4;')"
if [[ "$got" == "$want" ]]; then
  echo "  ok   判定は \$0 と \\\\\$4 を拾い、\$(0)・\${1}・\\\$3・\$ARGUMENTS・\$1a を拾わない"
else
  FAILED=$((FAILED + 1))
  echo "  FAIL 判定の自己試験: $got"
fi

printf '  %s 件中 %s 件失敗\n' "$RUN" "$FAILED"
[[ "$FAILED" -eq 0 ]]
