#!/usr/bin/env bash
# .claude/rules/（paths: 付きの規則）と、それを案内する地図（.github/project-ai-rules.md）が
# 設計どおりの形を保っていることを検査する（#676）。
#
# 設計: 常時載る地図は禁止事項・既定の動作・実行時に要る手順だけを持ち、理由・経緯・
# 詳しい手順は .claude/rules/*.md へ本文を直接置く。規則は paths: に一致するファイルに
# 触れたときだけ載る。次の 4 つが崩れると設計が黙って無効になるため、機械で落とす。
#
#   1. 規則が 1 つ以上追跡されている（.gitignore の再包含が外れると配られない）
#   2. 各規則が frontmatter に paths: を持ち、本文に @ の取り込みの行を含まない
#      （paths: 付きの規則の中の @ は起動時から載り、条件付きにならない。実測は #676）
#   3. 地図が各規則ファイルへリンクしている（道案内が無い規則は読まれない）
#   4. 地図が行数の上限以下（地図が育つと、常時の文脈を縮める目的が失われる）
#
# 例外: .claude/rules/ai-playbook*.md は手で書かず、共通規範の正本（.ai-playbook/shared-ai-rules.md）の
# 印から bootstrap.sh --render-claude-rules で生成したものである（#678）。生成物は
#   - paths: を持つ規則だけではない（常時の ai-playbook.md は paths: を持たない。起動時に載る）
#   - 地図からリンクしない（正本の側が道案内を持つ）
# ので上の 2 と 3 から外し、代わりに
#   5. 正本から作り直したものと一致する（手で直した生成物、正本の変更に追随していない生成物を落とす）
# を検査する。@ なし・追跡済み・glob の実在は生成物にも掛ける。
#
# 生成物かどうかは、名前の決め打ちではなく、生成物の先頭に付く断りの行で見分ける
# （bootstrap.sh の dcb_claude_rules_awk が書く、接頭辞「> 生成物:」で始まる行）。
# 名前で決め打つと、手で書いた規則が ai-playbook で始まる名前になったとき、検査から黙って外れる。
#
# 検査は「ルートを受け取る関数」にしてあり、末尾で壊したフィクスチャへも同じ関数を
# 当てる。検査が実際に落ちることを確かめないと、常に緑の検査が緑のまま残る。
#
# bash 3.2 互換を維持する（連想配列・mapfile を使わない）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-claude-rules"

MAP_REL=".github/project-ai-rules.md"
MAP_MAX_LINES=150
# 作り直しの一時置き場（check_generated_match）と、末尾の壊したフィクスチャの置き場。
FIX="$(mktemp -d "${TMPDIR:-/tmp}/test-claude-rules.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
SOURCE_REL=".ai-playbook/shared-ai-rules.md"
BOOTSTRAP_REL="packages/devcontainer-bootstrap/bootstrap.sh"
# 生成物の断りの行の接頭辞（bootstrap.sh の CLAUDE_RULES_NOTICE_PREFIX と同じ。この接頭辞だけで見分ける）。
GEN_NOTICE='> 生成物:'

# is_generated <file> — 正本から生成した規則か（先頭の断りの行で見分ける）。
is_generated() {
  # frontmatter（あれば）の直後の最初の空でない行が接頭辞で始まるときだけ生成物とする。
  awk -v p="$GEN_NOTICE" 'BEGIN { r = 1 }
      NR == 1 && $0 == "---" { fm = 1; next }
      fm && $0 == "---" { fm = 0; next }
      fm || $0 ~ /^[ \t\r]*$/ { next }
      { if (index($0, p) == 1) r = 0; exit }
      END { exit r }' "$1"
}

# list_rules_by_origin <root> <hand|generated> — 手で書いた規則、または生成物の規則を 1 行ずつ出す。
list_rules_by_origin() {
  local root="$1" want="$2" f kind
  while IFS= read -r f; do
    if is_generated "$root/$f"; then kind=generated; else kind=hand; fi
    [[ "$kind" == "$want" ]] && printf '%s\n' "$f"
  done < <(list_rules "$root")
}

# list_rules <root> — 規則ファイル（root からの相対パス）を 1 行ずつ出す。
list_rules() {
  local root="$1" f
  for f in "$root"/.claude/rules/*.md; do
    [[ -f "$f" ]] && printf '%s\n' "${f#"$root"/}"
  done
}

# frontmatter <file> — 先頭の --- から次の --- までを出す。先頭行が --- でなければ何も出さない。
# 行末の CR を落とす（CRLF で取り出した規則で、--- を見落として paths: を読めなくならないように。
# tests/test-subagent-roles.sh の agent_field と同じ理由）。
# 閉じの --- が無いまま終わるものは frontmatter として成り立たない（Claude Code が条件付きの規則と
# して読まない）ので、何も出さない。
frontmatter() {
  awk '{ sub(/\r$/, "") } NR == 1 { if ($0 != "---") exit; next } $0 == "---" { closed = 1; exit } { buf = buf $0 "\n" }
       END { if (closed) printf "%s", buf }' "$1"
}

# check_rules_exist <root> — 規則が 1 つ以上ある。
check_rules_exist() {
  [[ -n "$(list_rules "$1")" ]] || { printf '.claude/rules/ に規則がありません' ; return 1; }
}

# path_globs <file> — frontmatter の paths: の下の項目（glob）を、引用符を外して 1 行ずつ出す。
# paths: の後、字下げの無い次のキーまでだけを読む（ほかのキーの一覧を paths と取り違えない）。
path_globs() {
  frontmatter "$1" | awk '
    /^paths:[[:space:]]*$/ { inp = 1; next }
    /^[^[:space:]]/ { inp = 0 }
    inp && /^[[:space:]]+-[[:space:]]+[^[:space:]]/ {
      v = $0; sub(/^[[:space:]]+-[[:space:]]+/, "", v); gsub(/^["'\'']|["'\'']$/, "", v); print v
    }'
}

# check_paths <root> — 手で書いた各規則が frontmatter の paths: に 1 つ以上の glob を持つ。
# 生成物は対象外（常時の ai-playbook.md は paths: を持たない。条件付きの生成物が paths: を
# 持つことは check_generated_match が、正本から作り直したものとの一致で見る）。
check_paths() {
  local root="$1" f bad=""
  while IFS= read -r f; do
    [[ -n "$(path_globs "$root/$f")" ]] || bad="$bad $f"
  done < <(list_rules_by_origin "$root" hand)
  [[ -z "$bad" ]] || { printf 'paths: を持たない規則:%s' "$bad"; return 1; }
}

# check_no_import <root> — @ の取り込み（行頭でも行の途中でも、括弧の直後でも）が無い。メールアドレス
# （英数字などの直後の @）は取り込みではないので数えない。
# Claude Code はコードスパン（バッククォート）の中の @ を取り込まないので、それを除いてから見る。
# frontmatter は paths: と glob の行だけなので、ファイル全体を見ても同じ結果になる。
check_no_import() {
  local root="$1" f bad=""
  while IFS= read -r f; do
    # grep -q はパイプを読み切らずに終わり、pipefail の下で sed が SIGPIPE で落ちうるので、出力を捨てる形で読み切る
    if sed 's/`[^`]*`//g' "$root/$f" | grep -E '(^|[^A-Za-z0-9_.+-])@[A-Za-z0-9_./~-]+' >/dev/null; then
      bad="$bad $f"
    fi
  done < <(list_rules "$root")
  [[ -z "$bad" ]] || { printf '@ の取り込みを含む規則:%s' "$bad"; return 1; }
}

# check_map_links <root> — 地図が、手で書いた各規則ファイルへリンクしている（生成物は対象外）。
check_map_links() {
  local root="$1" f bad=""
  [[ -f "$root/$MAP_REL" ]] || { printf '地図がありません: %s' "$MAP_REL"; return 1; }
  while IFS= read -r f; do
    grep -qF "$f" "$root/$MAP_REL" || bad="$bad $f"
  done < <(list_rules_by_origin "$root" hand)
  [[ -z "$bad" ]] || { printf '地図からリンクされていない規則:%s' "$bad"; return 1; }
}

# check_map_size <root> — 地図が上限行数以下。
check_map_size() {
  local root="$1" n
  [[ -f "$root/$MAP_REL" ]] || { printf '地図がありません: %s' "$MAP_REL"; return 1; }
  n="$(wc -l < "$root/$MAP_REL" | tr -d ' ')"
  [[ "$n" -le "$MAP_MAX_LINES" ]] || { printf '地図が %s 行（上限 %s 行）' "$n" "$MAP_MAX_LINES"; return 1; }
}

# check_generated_match <root> — 生成物の規則が、正本から作り直したものと一致する。
# 作り直しは bootstrap.sh の --render-claude-rules を使う（--with-claude と同じ処理）。
# 正本が無いのに生成物がある、作り直した規則の一部が置かれていない、置かれている生成物が
# 作り直しに無い（正本から題が消えたのに残っている）、中身が違う、のいずれも落とす。
# 生成物が 1 つも無く正本も無いルートは、検査するものが無いので通す。
check_generated_match() {
  local root="$1" tmp gen f bad=""
  gen="$(list_rules_by_origin "$root" generated)"
  if [[ ! -f "$root/$SOURCE_REL" ]]; then
    [[ -z "$gen" ]] || { printf '正本 %s が無いのに生成物があります: %s' "$SOURCE_REL" "$(printf '%s' "$gen" | tr '\n' ' ')"; return 1; }
    return 0
  fi
  tmp="$(mktemp -d "$FIX/render.XXXXXX")" || return 1
  if ! bash "$REPO_ROOT/$BOOTSTRAP_REL" --render-claude-rules "$root/$SOURCE_REL" "$tmp" >/dev/null 2>"$tmp.err"; then
    printf '正本から規則を作り直せません: %s' "$(head -c 200 "$tmp.err")"
    return 1
  fi
  for f in "$tmp"/*.md; do
    [[ -f "$f" ]] || continue
    if [[ ! -f "$root/.claude/rules/$(basename "$f")" ]]; then
      bad="$bad 未生成:$(basename "$f")"
    elif ! diff -q "$f" "$root/.claude/rules/$(basename "$f")" >/dev/null; then
      bad="$bad 不一致:$(basename "$f")"
    fi
  done
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -f "$tmp/$(basename "$f")" ]] || bad="$bad 正本に無い生成物:$(basename "$f")"
  done <<< "$gen"
  [[ -z "$bad" ]] || { printf '正本から作り直したものと一致しません（%s を実行して置き直す）:%s' "bash $BOOTSTRAP_REL --render-claude-rules $SOURCE_REL .claude/rules" "$bad"; return 1; }
}

# check_all <root> — 全検査を通す（失敗したら、最初に落ちた検査のメッセージを出す）。
check_all() {
  check_rules_exist "$1" && check_paths "$1" && check_no_import "$1" \
    && check_map_links "$1" && check_map_size "$1" && check_generated_match "$1"
}

# run_check <関数名> <root> — 結果を pass / fail へ変換する。
run_check() {
  local msg
  if msg="$("$1" "$2")"; then pass; else fail "$msg"; fi
}

# expect_fail <関数名> <root> — 検査が落ちることを確かめる。
expect_fail() {
  if "$1" "$2" >/dev/null; then fail "壊したフィクスチャで $1 が通った（検査が効いていない）"; else pass; fi
}

# ── 現行ツリー ───────────────────────────────────────────────────────────────

it ".claude/rules/ の規則がすべて追跡されている（git add し忘れた規則は配られない）"
untracked=""
while IFS= read -r f; do
  git -C "$REPO_ROOT" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || untracked="$untracked $f"
done < <(list_rules "$REPO_ROOT")
if [[ -z "$untracked" ]]; then pass; else fail "追跡されていない規則:$untracked（.gitignore の !.claude/rules/ と git add を確認）"; fi

it "規則が 1 つ以上ある"
run_check check_rules_exist "$REPO_ROOT"

it "各規則が frontmatter に paths: を持つ"
run_check check_paths "$REPO_ROOT"

it "規則の本文に @ の取り込みの行が無い"
run_check check_no_import "$REPO_ROOT"

it "各規則の paths: の glob が、追跡されたファイルに 1 つ以上一致する（綴りの誤りで規則が黙って載らなくならない）"
nomatch=""
while IFS= read -r f; do
  while IFS= read -r g; do
    [[ -n "$(git -C "$REPO_ROOT" ls-files -- ":(glob)$g" | head -n 1)" ]] || nomatch="$nomatch $f:$g"
  done < <(path_globs "$REPO_ROOT/$f")
done < <(list_rules "$REPO_ROOT")
if [[ -z "$nomatch" ]]; then pass; else fail "一致するファイルが無い glob:$nomatch"; fi

it "生成物（ai-playbook*.md）が、正本から作り直したものと一致する（正本を直したら置き直す）"
run_check check_generated_match "$REPO_ROOT"

it "生成物が 1 つ以上ある（断りの行で見分けられなくなると、検査が黙って空になる）"
if [[ -n "$(list_rules_by_origin "$REPO_ROOT" generated)" ]]; then pass; else fail "生成物の断りの行を持つ規則が無い（GEN_NOTICE と bootstrap.sh の文言のずれ、または生成物の置き忘れ）"; fi

it "地図が、手で書いた各規則ファイルへリンクしている"
run_check check_map_links "$REPO_ROOT"

it "地図が ${MAP_MAX_LINES} 行以下"
run_check check_map_size "$REPO_ROOT"

# ── 意図的に壊したフィクスチャ ───────────────────────────────────────────────


# make_fixture <名前> — 正常な最小構成を作って、そのルートを出力する。
make_fixture() {
  local d="$FIX/$1"
  mkdir -p "$d/.claude/rules" "$d/.github"
  printf -- '---\npaths:\n  - "src/**"\n---\n\n# 規則\n\n本文です。\n' > "$d/.claude/rules/a.md"
  printf '# 地図\n\n- `.claude/rules/a.md`\n' > "$d/$MAP_REL"
  printf '%s' "$d"
}

it "（健全性）正常なフィクスチャは全検査を通る"
run_check check_all "$(make_fixture good)"

it "（健全性）CRLF の規則も paths: を読める"
D="$(make_fixture crlf)"
printf -- '---\r\npaths:\r\n  - "src/**"\r\n---\r\n\r\n本文\r\n' > "$D/.claude/rules/a.md"
run_check check_paths "$D"

it "規則が無いと落ちる"
D="$(make_fixture none)"; rm -f "$D"/.claude/rules/*.md
expect_fail check_rules_exist "$D"

it "paths: が無い規則は落ちる"
D="$(make_fixture nopaths)"
printf -- '---\ndescription: x\n---\n\n本文\n' > "$D/.claude/rules/a.md"
expect_fail check_paths "$D"

it "frontmatter が無い規則は落ちる"
D="$(make_fixture nofm)"
printf '本文だけ\n' > "$D/.claude/rules/a.md"
expect_fail check_paths "$D"

it "paths: が空（glob が 1 つも無い）の規則は落ちる"
D="$(make_fixture emptypaths)"
printf -- '---\npaths:\n---\n\n本文\n' > "$D/.claude/rules/a.md"
expect_fail check_paths "$D"

it "paths: が空で、別のキーの一覧がある規則は落ちる"
D="$(make_fixture otherlist)"
printf -- '---\npaths:\ntags:\n  - x\n---\n\n本文\n' > "$D/.claude/rules/a.md"
expect_fail check_paths "$D"

it "行の途中の @ の取り込みも落ちる（コードスパンの中の @ は通す）"
D="$(make_fixture midimport)"
printf -- '---\npaths:\n  - "src/**"\n---\n\n書き方は `@パス` です。\n' > "$D/.claude/rules/a.md"
run_check check_no_import "$D"
printf -- '---\npaths:\n  - "src/**"\n---\n\n詳しくは @docs/x.md を参照。\n' > "$D/.claude/rules/a.md"
expect_fail check_no_import "$D"

it "括弧の直後の @ の取り込みも落ちる（メールアドレスは通す）"
D="$(make_fixture parenimport)"
printf -- '---\npaths:\n  - "src/**"\n---\n\n連絡先は ido@example.com です。\n' > "$D/.claude/rules/a.md"
run_check check_no_import "$D"
printf -- '---\npaths:\n  - "src/**"\n---\n\n詳細は（@docs/guide.md）。\n' > "$D/.claude/rules/a.md"
expect_fail check_no_import "$D"

it "frontmatter の閉じの --- が無い規則は落ちる"
D="$(make_fixture unclosed)"
printf -- '---\npaths:\n  - "src/**"\n\n本文\n' > "$D/.claude/rules/a.md"
expect_fail check_paths "$D"

it "@ の取り込みの行を含む規則は落ちる"
D="$(make_fixture import)"
printf -- '---\npaths:\n  - "src/**"\n---\n\n@../../docs/b.md\n' > "$D/.claude/rules/a.md"
expect_fail check_no_import "$D"

it "地図からリンクされていない規則は落ちる"
D="$(make_fixture unlinked)"
printf -- '---\npaths:\n  - "src/**"\n---\n\n本文\n' > "$D/.claude/rules/b.md"
expect_fail check_map_links "$D"

it "地図が上限を超えると落ちる"
D="$(make_fixture long)"
for ((i = 0; i <= MAP_MAX_LINES; i++)); do echo "行 $i"; done >> "$D/$MAP_REL"
expect_fail check_map_size "$D"

# make_generated_fixture <名前> — 正本と、そこから生成した規則（地図にリンクされない）を持つルートを作る。
make_generated_fixture() {
  local d
  d="$(make_fixture "$1")"
  mkdir -p "$d/.ai-playbook"
  printf '# t\n\n常時\n\n<!-- claude-rules: name=x paths=src/** -->\n## 条件付き\n\n本文\n' > "$d/$SOURCE_REL"
  bash "$REPO_ROOT/$BOOTSTRAP_REL" --render-claude-rules "$d/$SOURCE_REL" "$d/.claude/rules" >/dev/null
  printf '%s' "$d"
}

it "（健全性）正本から生成した規則は、paths: が無い常時の規則や地図からリンクされない規則も含めて全検査を通る"
run_check check_all "$(make_generated_fixture genok)"

it "生成物を手で直すと落ちる"
D="$(make_generated_fixture genedit)"
printf '手で足した行\n' >> "$D/.claude/rules/ai-playbook-x.md"
expect_fail check_generated_match "$D"

it "正本を直したのに生成物を置き直していないと落ちる"
D="$(make_generated_fixture genstale)"
printf '\n正本に足した行\n' >> "$D/$SOURCE_REL"
expect_fail check_generated_match "$D"

it "正本から題が消えたのに、生成物が残っていると落ちる"
D="$(make_generated_fixture genorphan)"
printf '# t\n\n常時\n' > "$D/$SOURCE_REL"
expect_fail check_generated_match "$D"

it "生成した規則が置かれていないと落ちる"
D="$(make_generated_fixture genmissing)"
rm -f "$D/.claude/rules/ai-playbook-x.md"
expect_fail check_generated_match "$D"

it "正本が無いのに生成物があると落ちる"
D="$(make_generated_fixture gennosrc)"
rm -f "$D/$SOURCE_REL"
expect_fail check_generated_match "$D"

it "生成物の @ の取り込みも落ちる（生成物にも @ なしの検査を掛ける）"
D="$(make_generated_fixture genimport)"
printf '@docs/x.md\n' >> "$D/.claude/rules/ai-playbook-x.md"
expect_fail check_no_import "$D"

it "断りの接頭辞が本文の途中にあるだけの規則は生成物と見なされず、paths: が無ければ落ちる"
D="$(make_generated_fixture genmid)"
printf -- '---\ndescription: x\n---\n\n手書きの本文\n%s 途中の行\n' "$GEN_NOTICE" > "$D/.claude/rules/ai-playbook-x.md"
expect_fail check_paths "$D"

it "断りの行を消した規則は生成物と見なされず、paths: が無ければ落ちる（名前では見分けない）"
D="$(make_generated_fixture gennotice)"
printf -- '---\ndescription: x\n---\n\n手書きの本文\n' > "$D/.claude/rules/ai-playbook-x.md"
expect_fail check_paths "$D"

exit_with_result
