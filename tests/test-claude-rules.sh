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
# 検査は「ルートを受け取る関数」にしてあり、末尾で壊したフィクスチャへも同じ関数を
# 当てる。検査が実際に落ちることを確かめないと、常に緑の検査が緑のまま残る。
#
# bash 3.2 互換を維持する（連想配列・mapfile を使わない）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-claude-rules"

MAP_REL=".github/project-ai-rules.md"
MAP_MAX_LINES=150

# list_rules <root> — 規則ファイル（root からの相対パス）を 1 行ずつ出す。
list_rules() {
  local root="$1" f
  for f in "$root"/.claude/rules/*.md; do
    [[ -f "$f" ]] && printf '%s\n' "${f#"$root"/}"
  done
}

# frontmatter <file> — 先頭の --- から次の --- までを出す。先頭行が --- でなければ何も出さない。
frontmatter() {
  awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit } { print }' "$1"
}

# body <file> — frontmatter を除いた本文を出す。
body() {
  awk 'NR == 1 && $0 == "---" { fm = 1; next } fm && $0 == "---" { fm = 0; next } !fm { print }' "$1"
}

# check_rules_exist <root> — 規則が 1 つ以上ある。
check_rules_exist() {
  [[ -n "$(list_rules "$1")" ]] || { printf '.claude/rules/ に規則がありません' ; return 1; }
}

# check_paths <root> — 各規則が frontmatter に paths: と 1 つ以上の glob を持つ。
check_paths() {
  local root="$1" f fm bad=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    fm="$(frontmatter "$root/$f")"
    if ! grep '^paths:[[:space:]]*$' <<<"$fm" >/dev/null \
       || ! grep -E '^[[:space:]]+-[[:space:]]+[^[:space:]]' <<<"$fm" >/dev/null; then
      bad="$bad $f"
    fi
  done < <(list_rules "$root")
  [[ -z "$bad" ]] || { printf 'paths: を持たない規則:%s' "$bad"; return 1; }
}

# check_no_import <root> — 本文に @ の取り込みの行（行頭の @ に続くパス）が無い。
check_no_import() {
  local root="$1" f bad=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if grep -E '^[[:space:]]*@[A-Za-z0-9_./~-]+' <<<"$(body "$root/$f")" >/dev/null; then
      bad="$bad $f"
    fi
  done < <(list_rules "$root")
  [[ -z "$bad" ]] || { printf '@ の取り込みを含む規則:%s' "$bad"; return 1; }
}

# check_map_links <root> — 地図が各規則ファイルへリンクしている。
check_map_links() {
  local root="$1" f bad=""
  [[ -f "$root/$MAP_REL" ]] || { printf '地図がありません: %s' "$MAP_REL"; return 1; }
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    grep -F "$f" "$root/$MAP_REL" >/dev/null || bad="$bad $f"
  done < <(list_rules "$root")
  [[ -z "$bad" ]] || { printf '地図からリンクされていない規則:%s' "$bad"; return 1; }
}

# check_map_size <root> — 地図が上限行数以下。
check_map_size() {
  local root="$1" n
  [[ -f "$root/$MAP_REL" ]] || { printf '地図がありません: %s' "$MAP_REL"; return 1; }
  n="$(wc -l < "$root/$MAP_REL" | tr -d ' ')"
  [[ "$n" -le "$MAP_MAX_LINES" ]] || { printf '地図が %s 行（上限 %s 行）' "$n" "$MAP_MAX_LINES"; return 1; }
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

it ".claude/rules/ に規則が追跡されている（未追跡でも除外されていなければ可）"
TRACKED="$(cd "$REPO_ROOT" && git ls-files --cached --others --exclude-standard -- .claude/rules/ | grep -c '\.md$')"
if [[ "$TRACKED" -ge 1 ]]; then pass; else fail "追跡対象の規則が 0 件（.gitignore の !.claude/rules/ を確認）"; fi

it "規則が 1 つ以上ある"
run_check check_rules_exist "$REPO_ROOT"

it "各規則が frontmatter に paths: を持つ"
run_check check_paths "$REPO_ROOT"

it "規則の本文に @ の取り込みの行が無い"
run_check check_no_import "$REPO_ROOT"

it "地図が各規則ファイルへリンクしている"
run_check check_map_links "$REPO_ROOT"

it "地図が ${MAP_MAX_LINES} 行以下"
run_check check_map_size "$REPO_ROOT"

# ── 意図的に壊したフィクスチャ ───────────────────────────────────────────────

FIX="$(mktemp -d "${TMPDIR:-/tmp}/test-claude-rules.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

# make_fixture <名前> — 正常な最小構成を作って、そのルートを出力する。
make_fixture() {
  local d="$FIX/$1"
  mkdir -p "$d/.claude/rules" "$d/.github"
  printf -- '---\npaths:\n  - "src/**"\n---\n\n# 規則\n\n本文です。\n' > "$d/.claude/rules/a.md"
  printf '# 地図\n\n- `.claude/rules/a.md`\n' > "$d/$MAP_REL"
  printf '%s' "$d"
}

it "（健全性）正常なフィクスチャは全検査を通る"
GOOD="$(make_fixture good)"
if check_rules_exist "$GOOD" >/dev/null && check_paths "$GOOD" >/dev/null \
   && check_no_import "$GOOD" >/dev/null && check_map_links "$GOOD" >/dev/null \
   && check_map_size "$GOOD" >/dev/null; then pass; else fail "正常なフィクスチャが落ちた（フィクスチャか検査が壊れている）"; fi

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
i=0; while [[ "$i" -le "$MAP_MAX_LINES" ]]; do echo "行 $i"; i=$((i + 1)); done >> "$D/$MAP_REL"
expect_fail check_map_size "$D"

exit_with_result
