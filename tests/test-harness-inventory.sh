#!/usr/bin/env bash
# 自前の実装の一覧（.github/harness-inventory.json）と実物の機械照合（#710）。
#
# 一覧は「本体（Claude Code）の更新で要らなくなった自前の仕組み」を洗い出す入口
# （scripts/harness-audit.sh）の入力である。実物に増減があるのに一覧が追随しないと、
# 棚卸しの対象から静かに外れる。共通規範 12 章「一覧の複製は機械照合で担保する」に従い、
# 次を両方向で突き合わせる（欠けと、実在しない項目の余り）。
#
#   script  : scripts/*.sh のすべて
#   skill   : .claude/skills/*/（path は .claude/skills/<名前>/SKILL.md）
#   hook    : .claude/settings.json の hooks の各エントリ（id は <イベント>/<matcher か *>/<スクリプトの basename>）
#   ci-job  : .github/workflows/ci.yml の jobs の各キー（id は ci/<ジョブ名>）
#   rule    : .claude/rules/*.md のうち手で書いたもの（id は rule/<名前>）。正本から生成した
#             ai-playbook*.md（先頭に「> 生成物:」の断りの行がある）は、正本の側が持つので除く
#
# 各項目の id と path の対応も見る（実在する別のファイルを指す項目を、集合の一致と実在の確認だけでは落とせないため）。
#
# あわせて、id の重複が無いこと・必須キーがあること・キーワードが汎用語でないこと、
# ルーティンの依頼文（docs/routines/harness-audit.md）が突き合わせのスクリプトと
# 追跡 issue を指していることを見る。
#
# 検査は「ルートを受け取る関数」にしてあり、末尾で壊したフィクスチャ（欠け 1 件・余り 1 件）へも
# 同じ関数を当てる。検査が実際に落ちることを確かめないと、常に緑の検査が緑のまま残る。
#
# jq を要する（scripts/acceptance.sh と同じ前提）。bash 3.2 互換を維持する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-harness-inventory"

INV_REL=".github/harness-inventory.json"
ROUTINE_REL="docs/routines/harness-audit.md"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/test-harness-inventory.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq が見つかりません" >&2
  exit 1
fi

# 一覧から、kind の id を 1 行 1 件で出す。
inventory_ids() {
  jq -r --arg k "$2" '.items[] | select(.kind == $k) | .id' "$1/$INV_REL" | sort -u
}

# 実物の script の id（scripts/*.sh）。
actual_scripts() {
  local f
  for f in "$1"/scripts/*.sh; do
    [[ -f "$f" ]] && printf 'scripts/%s\n' "$(basename "$f")"
  done | sort -u
}

# 実物の skill の id（skill/<名前>）。
actual_skills() {
  local d
  for d in "$1"/.claude/skills/*/; do
    [[ -d "$d" ]] && printf 'skill/%s\n' "$(basename "$d")"
  done | sort -u
}

# 実物の hook の id（<イベント>/<matcher か *>/<スクリプトの basename>）。
# コマンドに .sh が無いフック（インラインのコマンドなど）は、コマンドの文字列そのものを id の末尾にする。
# 黙って落とすと、そのフックが照合から外れるため。
actual_hooks() {
  jq -r '.hooks // {} | to_entries[] | .key as $e | .value[] | (.matcher // "*") as $m
    | (.hooks // [])[] | (([.command // "" | capture("(?<s>[A-Za-z0-9_.-]+\\.sh)")? | .s] | first) // (.command // "")) as $s
    | "\($e)/\($m)/\($s)"' "$1/.claude/settings.json" | sort -u
}

# 実物の ci-job の id（ci/<ジョブ名>）。
actual_cijobs() {
  awk '
    /^jobs:/ { injobs = 1; next }
    injobs && /^[^ #]/ { injobs = 0 }
    injobs && /^  [A-Za-z0-9_-]+:/ { k = $1; sub(/:$/, "", k); print "ci/" k }
  ' "$1/.github/workflows/ci.yml" | sort -u
}

# 実物の rule の id（rule/<名前>）。手で書いた規則だけ（生成物は先頭の断りの行で見分ける。
# 判定は tests/test-claude-rules.sh の is_generated と同じ: frontmatter の直後の最初の空でない行が「> 生成物:」で始まる）。
actual_rules() {
  local f
  for f in "$1"/.claude/rules/*.md; do
    [[ -f "$f" ]] || continue
    if awk -v p='> 生成物:' 'BEGIN { r = 1 }
        NR == 1 && $0 == "---" { fm = 1; next }
        fm && $0 == "---" { fm = 0; next }
        fm || $0 ~ /^[ \t\r]*$/ { next }
        { if (index($0, p) == 1) r = 0; exit }
        END { exit r }' "$f"; then
      continue
    fi
    printf 'rule/%s\n' "$(basename "$f" .md)"
  done | sort -u
}

# 一覧と実物を kind ごとに両方向で突き合わせる。差分があれば内容を出して 1 を返す。
check_coverage() {
  local root="$1" rc=0 kind actual listed only_actual only_listed
  for kind in script skill hook ci-job rule; do
    case "$kind" in
      script) actual="$(actual_scripts "$root")" ;;
      skill) actual="$(actual_skills "$root")" ;;
      hook) actual="$(actual_hooks "$root")" ;;
      ci-job) actual="$(actual_cijobs "$root")" ;;
      rule) actual="$(actual_rules "$root")" ;;
    esac
    listed="$(inventory_ids "$root" "$kind")"
    only_actual="$(comm -23 <(printf '%s\n' "$actual") <(printf '%s\n' "$listed") | tr '\n' ' ')"
    only_listed="$(comm -13 <(printf '%s\n' "$actual") <(printf '%s\n' "$listed") | tr '\n' ' ')"
    if [[ -n "${only_actual// /}" ]]; then
      echo "[$kind] 一覧に欠けている: $only_actual"
      rc=1
    fi
    if [[ -n "${only_listed// /}" ]]; then
      echo "[$kind] 一覧にあるが実物に無い: $only_listed"
      rc=1
    fi
  done
  return "$rc"
}

# 一覧の各項目の path が実在する。
check_paths_exist() {
  local root="$1" rc=0 p
  while IFS= read -r p; do
    if [[ ! -e "$root/$p" ]]; then
      echo "path が実在しない: $p"
      rc=1
    fi
  done < <(jq -r '.items[].path' "$root/$INV_REL")
  return "$rc"
}

# 各項目の id と path が対応している（kind ごとの命名の規則どおり）。
check_id_path() {
  local bad
  bad="$(jq -r '.items[] | select(
      (.kind == "script" and .path != .id)
      or (.kind == "skill" and .path != (".claude/skills/" + (.id | ltrimstr("skill/")) + "/SKILL.md"))
      or (.kind == "hook" and (.path | split("/") | last) != (.id | split("/") | last))
      or (.kind == "ci-job" and .path != ".github/workflows/ci.yml")
      or (.kind == "rule" and .path != (".claude/rules/" + (.id | ltrimstr("rule/")) + ".md"))
    ) | "\(.id) -> \(.path)"' "$1/$INV_REL" | tr '\n' ' ')"
  if [[ -n "${bad// /}" ]]; then
    echo "id と path が対応していない: $bad"
    return 1
  fi
}

# id の重複が無い。
check_unique_ids() {
  local dup
  dup="$(jq -r '.items[].id' "$1/$INV_REL" | sort | uniq -d | tr '\n' ' ')"
  if [[ -n "${dup// /}" ]]; then
    echo "id が重複している: $dup"
    return 1
  fi
}

# 各項目の必須キーと型。キーワードを持つ項目は補っている不足（compensates）も持つ。
check_required_keys() {
  local bad
  bad="$(jq -r '.items[] | select(
      ((has("id") and has("kind") and has("path") and has("compensates") and has("keywords") and has("issue")) | not)
      or ((.id | type) != "string") or ((.path | type) != "string")
      or ((.keywords | type) != "array")
      or ((.kind | IN("script","hook","skill","ci-job","rule")) | not)
      or ((.compensates != null) and ((.compensates | type) != "string"))
      or ((.keywords | length) > 0 and .compensates == null)
      or (.issue != null and ((.issue | type) != "string" or (.issue | test("^#[0-9]+$") | not)))
    ) | .id // "(id なし)"' "$1/$INV_REL" | tr '\n' ' ')"
  if [[ -n "${bad// /}" ]]; then
    echo "必須キー・型・kind・issue の形が不正: $bad"
    return 1
  fi
  if [[ "$(jq -r '.version' "$1/$INV_REL")" != "1" ]]; then
    echo "version が 1 ではない"
    return 1
  fi
}

# キーワードは汎用語にしない（誤検出で候補が埋まり、読まれなくなる）。
check_keywords_specific() {
  local bad
  bad="$(jq -r '.items[] | .id as $i | .keywords[]
      | select((length < 6) or (ascii_downcase | IN("claude","claude code","hook","hooks","skill","skills","fix","fixed","session","sessions","permission","permissions","review","script")))
      | "\($i):\(.)"' "$1/$INV_REL" | tr '\n' ' ')"
  if [[ -n "${bad// /}" ]]; then
    echo "キーワードが短すぎる・汎用的すぎる: $bad"
    return 1
  fi
}

# 依頼文が突き合わせのスクリプトと追跡 issue を指している。
check_routine_doc() {
  local root="$1" f="$1/$ROUTINE_REL"
  if [[ ! -f "$f" ]]; then
    echo "依頼文が無い: $ROUTINE_REL"
    return 1
  fi
  grep -q 'scripts/harness-audit\.sh' "$f" || { echo "依頼文が scripts/harness-audit.sh を参照していない"; return 1; }
  [[ -f "$root/scripts/harness-audit.sh" ]] || { echo "scripts/harness-audit.sh が実在しない"; return 1; }
  grep -Eq '^追跡 issue: #[0-9]+' "$f" || { echo "依頼文に「追跡 issue: #N」の行が無い"; return 1; }
}

# 関数 $1 をルート $2 へ当て、落ちる（0 以外）ことを確かめる。
expect_fail() {
  if "$1" "$2" >/dev/null 2>&1; then
    fail "壊したフィクスチャで $1 が落ちなかった"
  else
    pass
  fi
}

# 関数 $1 をルート $2 へ当て、通る（0）ことを確かめる。
expect_ok() {
  local out
  if out="$("$1" "$2" 2>&1)"; then
    pass
  else
    fail "$out"
  fi
}

it "scripts・スキル・フック・CI のジョブ・手で書いた規則が一覧と両方向で一致する"
expect_ok check_coverage "$REPO_ROOT"

it "id の重複が無い"
expect_ok check_unique_ids "$REPO_ROOT"

it "各項目の必須キー・型・kind が正しい"
expect_ok check_required_keys "$REPO_ROOT"

it "一覧の path がすべて実在する"
expect_ok check_paths_exist "$REPO_ROOT"

it "一覧の id と path が対応している"
expect_ok check_id_path "$REPO_ROOT"

it "キーワードが汎用語になっていない"
expect_ok check_keywords_specific "$REPO_ROOT"

it "ルーティンの依頼文が突き合わせのスクリプトと追跡 issue を指している"
expect_ok check_routine_doc "$REPO_ROOT"

# --- 壊したフィクスチャ ---

# 小さな正しいルートを作って $1 に置く。
make_fixture() {
  local d="$FIX/$1"
  mkdir -p "$d/scripts" "$d/.claude/skills/s" "$d/.claude/rules" "$d/.github/workflows" "$d/docs/routines"
  printf -- '---\npaths:\n  - "x"\n---\n\n# 手で書いた規則\n' > "$d/.claude/rules/r.md"
  printf '> 生成物: 正本から生成したもの\n' > "$d/.claude/rules/ai-playbook.md"
  : > "$d/scripts/a.sh"
  : > "$d/scripts/b.sh"
  : > "$d/.claude/skills/s/SKILL.md"
  cat > "$d/.claude/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/scripts/a.sh\""}]}],
 "SessionEnd":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/scripts/b.sh\" --hook"}]}]}}
EOF
  printf 'name: ci\non:\n  push:\njobs:\n  lint:\n    runs-on: x\n' > "$d/.github/workflows/ci.yml"
  printf 'scripts/harness-audit.sh を回す。\n追跡 issue: #1\n' > "$d/$ROUTINE_REL"
  : > "$d/scripts/harness-audit.sh"
  cat > "$d/$INV_REL" <<'EOF'
{"version":1,"items":[
 {"id":"scripts/a.sh","kind":"script","path":"scripts/a.sh","compensates":null,"keywords":[],"issue":null},
 {"id":"scripts/b.sh","kind":"script","path":"scripts/b.sh","compensates":null,"keywords":[],"issue":null},
 {"id":"scripts/harness-audit.sh","kind":"script","path":"scripts/harness-audit.sh","compensates":null,"keywords":[],"issue":null},
 {"id":"skill/s","kind":"skill","path":".claude/skills/s/SKILL.md","compensates":"不足","keywords":["specific phrase"],"issue":"#2"},
 {"id":"PreToolUse/Bash/a.sh","kind":"hook","path":"scripts/a.sh","compensates":null,"keywords":[],"issue":null},
 {"id":"SessionEnd/*/b.sh","kind":"hook","path":"scripts/b.sh","compensates":null,"keywords":[],"issue":null},
 {"id":"ci/lint","kind":"ci-job","path":".github/workflows/ci.yml","compensates":null,"keywords":[],"issue":null},
 {"id":"rule/r","kind":"rule","path":".claude/rules/r.md","compensates":null,"keywords":[],"issue":null}
]}
EOF
  printf '%s' "$d"
}

it "フィクスチャ（正しい形）は通る（壊す前の基準）"
D="$(make_fixture base)"
if check_coverage "$D" >/dev/null && check_unique_ids "$D" >/dev/null && check_required_keys "$D" >/dev/null \
  && check_paths_exist "$D" >/dev/null && check_id_path "$D" >/dev/null && check_keywords_specific "$D" >/dev/null \
  && check_routine_doc "$D" >/dev/null; then
  pass
else
  fail "正しいフィクスチャが落ちた"
fi

it "手で書いた規則が一覧から欠けると落ちる（生成物の規則は求めない）"
D="$(make_fixture miss-rule)"
jq '.items |= map(select(.id != "rule/r"))' "$D/$INV_REL" > "$D/x.json" && cat "$D/x.json" > "$D/$INV_REL"
expect_fail check_coverage "$D"

it "id と別の実在するファイルを path が指すと落ちる"
D="$(make_fixture id-path)"
jq '.items |= map(if .id == "scripts/a.sh" then .path = "scripts/b.sh" else . end)' "$D/$INV_REL" > "$D/x.json" && cat "$D/x.json" > "$D/$INV_REL"
expect_fail check_id_path "$D"

it "script が一覧から欠けると落ちる"
D="$(make_fixture miss-script)"
jq '.items |= map(select(.id != "scripts/b.sh"))' "$D/$INV_REL" > "$D/x.json" && cat "$D/x.json" > "$D/$INV_REL"
expect_fail check_coverage "$D"

it "hook が一覧から欠けると落ちる"
D="$(make_fixture miss-hook)"
jq '.items |= map(select(.id != "SessionEnd/*/b.sh"))' "$D/$INV_REL" > "$D/x.json" && cat "$D/x.json" > "$D/$INV_REL"
expect_fail check_coverage "$D"

it "ci-job が一覧から欠けると落ちる"
D="$(make_fixture miss-ci)"
jq '.items |= map(select(.id != "ci/lint"))' "$D/$INV_REL" > "$D/x.json" && cat "$D/x.json" > "$D/$INV_REL"
expect_fail check_coverage "$D"

it "skill が一覧から欠けると落ちる"
D="$(make_fixture miss-skill)"
jq '.items |= map(select(.id != "skill/s"))' "$D/$INV_REL" > "$D/x.json" && cat "$D/x.json" > "$D/$INV_REL"
expect_fail check_coverage "$D"

it "実在しない script が一覧にあると落ちる（余り）"
D="$(make_fixture extra-script)"
jq '.items += [{"id":"scripts/ghost.sh","kind":"script","path":"scripts/ghost.sh","compensates":null,"keywords":[],"issue":null}]' "$D/$INV_REL" > "$D/x.json" && cat "$D/x.json" > "$D/$INV_REL"
expect_fail check_coverage "$D"

it "実在しない path が一覧にあると落ちる"
D="$(make_fixture extra-path)"
jq '.items += [{"id":"rule/ghost","kind":"rule","path":".claude/rules/ghost.md","compensates":null,"keywords":[],"issue":null}]' "$D/$INV_REL" > "$D/x.json" && cat "$D/x.json" > "$D/$INV_REL"
expect_fail check_paths_exist "$D"

it "id が重複すると落ちる"
D="$(make_fixture dup-id)"
jq '.items += [.items[0]]' "$D/$INV_REL" > "$D/x.json" && cat "$D/x.json" > "$D/$INV_REL"
expect_fail check_unique_ids "$D"

it "必須キーが欠けると落ちる"
D="$(make_fixture nokey)"
jq '.items[0] |= del(.keywords)' "$D/$INV_REL" > "$D/x.json" && cat "$D/x.json" > "$D/$INV_REL"
expect_fail check_required_keys "$D"

it "キーワードがあるのに補っている不足が null だと落ちる"
D="$(make_fixture nocomp)"
jq '.items[0].keywords = ["specific phrase"]' "$D/$INV_REL" > "$D/x.json" && cat "$D/x.json" > "$D/$INV_REL"
expect_fail check_required_keys "$D"

it "汎用的なキーワードがあると落ちる"
D="$(make_fixture genericword)"
jq '.items[3].keywords = ["hook"]' "$D/$INV_REL" > "$D/x.json" && cat "$D/x.json" > "$D/$INV_REL"
expect_fail check_keywords_specific "$D"

it "依頼文に追跡 issue の行が無いと落ちる"
D="$(make_fixture noissue)"
printf 'scripts/harness-audit.sh を回す。\n' > "$D/$ROUTINE_REL"
expect_fail check_routine_doc "$D"

it "依頼文がスクリプトを参照していないと落ちる"
D="$(make_fixture noref)"
printf '追跡 issue: #1\n' > "$D/$ROUTINE_REL"
expect_fail check_routine_doc "$D"

exit_with_result
