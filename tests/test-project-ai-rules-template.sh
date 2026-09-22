#!/usr/bin/env bash
# 2 層目の雛形（.ai-playbook/templates/project-ai-rules.md）が、
#
#   1. 残した空欄すべてで「既定はありません」と宣言していること
#   2. 既定値として挙げたパスが実在すること
#   3. 「書かれていない項目の意味」を冒頭で宣言していること
#
# を検査する。
#
# ## なぜこの 3 つか
#
# 雛形は穴埋め式で、**埋め忘れと意図的な未記入を読む側が区別できなかった**。
# 実測では、雛形を 1 文字も変えずに使うプロジェクトと、すべての欄を埋めて 485 行まで
# 育てるプロジェクトの両方があり、**どちらも成立している。**
#
# そこで「埋まっているか」ではなく、**「埋まっていない理由が書いてあるか」**を見る。
#
#   - 既定があるなら、欄ではなく既定値を書く（未記入のままでも文章が完結する）
#   - 既定が無いなら、欄のまま残し、**「既定はありません」と明示する**
#
# **「空欄が 1 つも無いこと」は検査しない。** 既定が原理的に決まらない項目
# （PAT の発行手順、コミットしない生成物など）は欄のまま残すのが正しい。全廃すると、
# 書かないと危ない項目が地の文へ埋もれる。
#
# ## 何を保証しないか
#
# **書かれた内容の妥当性は見ない。** 見るのは空欄の形と、パスの実在だけである。
# 「埋めた風」の記述は通る。
#
# 依存はコアユーティリティのみ。bash 3.2 互換を維持する。
set -uo pipefail
export LC_ALL=C.UTF-8
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-project-ai-rules-template"

TEMPLATE="$REPO_ROOT/.ai-playbook/templates/project-ai-rules.md"
BOOTSTRAP="$REPO_ROOT/packages/devcontainer-bootstrap/bootstrap.sh"
ENTRY="$REPO_ROOT/CLAUDE.md"

# 空欄形式の行。行頭が `-` か `1.` で、`: （…）` で終わるもの。
#
# **`（記載）` や `（例:` で数えない。** その形は `（コマンドを記載）` /
# `（記録先を記載）` / `（種別・対象・有効期限を記載）` を取りこぼす（実測で踏んだ。
# 23 箇所のうち 8 箇所しか数えられていなかった）。
blank_fields() {
  grep -nE '^[-*]|^[0-9]+\.' "$TEMPLATE" | grep -E ': （.*）$'
}

it "雛形から空欄形式の行を抽出できる"
# 0 件のまま緑になると、以降の検査は対象ゼロで無条件に通る（偽の緑）。
BLANKS="$(blank_fields)"
BLANK_COUNT="$(printf '%s\n' "$BLANKS" | grep -c . || true)"
if [[ "$BLANK_COUNT" -gt 0 ]]; then
  pass
else
  fail "空欄形式を 1 件も抽出できなかった（抽出が壊れているか、全廃された）"
fi

it "残した空欄がすべて「既定はありません」と宣言している"
# **これがこの検査の本体である。** 埋め忘れと意図的な未記入を、読む側が区別できる
# ようにする唯一の印。
undeclared="$(printf '%s\n' "$BLANKS" | grep -v '既定はありません' || true)"
if [[ -z "$undeclared" ]]; then
  pass
else
  fail "既定の有無を宣言していない空欄:
$undeclared"
fi

# ── 既定値として挙げたパスの実在 ─────────────────────────────────────────────
#
# 雛形が既定値を書くと、**実装の既定を書き写したことになる。** 書き写した一覧は
# 機械照合しないと、生成物の既定が変わった日に雛形だけが古いことを言い続ける。
#
# **見るのはパスの実在だけで、内容の妥当性は見ない。**

# 雛形が挙げるパス風のトークン。
template_paths() {
  grep -oE '`[A-Za-z0-9_./-]+\.(sh|md|yml|yaml|json|example)`|`\.env`' "$TEMPLATE" \
    | tr -d '`' | sort -u
}

# DCB が生成する相対パス（無条件・条件付きの両方）。
generated_paths() {
  awk '
    /^(conditional_)?template_rel_paths\(\) \{/ { inside = 1 }
    inside && /^\}/ { inside = 0 }
    inside { print }
  ' "$BOOTSTRAP" | grep -oE "'[^']+'" | tr -d "'" | sort -u
}

# 規範パッケージの実体（雛形が参照してよい相手）。
playbook_paths() {
  ( cd "$REPO_ROOT/.ai-playbook" && find . -type f -name '*.md' | sed 's|^\./|.ai-playbook/|' )
  printf '%s\n' 'CLAUDE.md'
}

# 照合から外すパスと、その理由。**外した事実を消さない。**
#
#   .env  利用者が自分で作るもので、生成物には含まれない。既定値としては書けるが
#         実在を照合する相手がいない。
EXCLUDED='.env'

it "雛形からパス風のトークンを抽出できる"
PATHS="$(template_paths)"
if [[ "$(printf '%s\n' "$PATHS" | grep -c .)" -gt 0 ]]; then
  pass
else
  fail "パスを 1 件も抽出できなかった"
fi

it "雛形が挙げるパスがすべて実在する（または理由つきで除外されている）"
GENERATED="$(generated_paths)"
PLAYBOOK="$(playbook_paths)"
missing=""
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  case "
$EXCLUDED
" in *"
$path
"*) continue ;; esac
  printf '%s\n' "$GENERATED" | grep -Fxq "$path" && continue
  printf '%s\n' "$PLAYBOOK" | grep -Fxq "$path" && continue
  [[ -f "$REPO_ROOT/.ai-playbook/templates/$(basename "$path")" ]] && continue
  missing="${missing}${path}"$'\n'
done <<PATHS_EOF
$PATHS
PATHS_EOF
if [[ -z "$missing" ]]; then
  pass
else
  fail "雛形が挙げるが実在しないパス（生成物にも規範パッケージにも無い）:
$missing"
fi

it "照合から外したパスが、外した理由とともに記録されている"
# 除外を黙って増やすと、「照合した」と「照合していない」が読み分けられなくなる。
if grep -q '^#   \.env  利用者が自分で作るもので' "${BASH_SOURCE[0]}"; then
  pass
else
  fail "除外したパスの理由がこのファイルのコメントに無い"
fi

# ── 冒頭の宣言 ───────────────────────────────────────────────────────────────

it "雛形の冒頭が「書かれていない項目の意味」を宣言している"
# これが無いと、空のまま使うことが正当だと読む側に伝わらない。
if grep -q '全体共通ルールの既定に従う' "$TEMPLATE"; then
  pass
else
  fail "「全体共通ルールの既定に従う」という宣言が雛形に無い"
fi

it "雛形が「保証しないこと」を明記している"
if grep -q 'この雛形が保証しないこと' "$TEMPLATE"; then
  pass
else
  fail "「この雛形が保証しないこと」の節が雛形に無い"
fi

it "3 層目の入口ファイルが 2 層目を「正本」と呼び続けている"
# この票で「正本」の語を変えない、という判断を固定する。空でも正本として成立する
# 理由を雛形へ書いたので、語を変える必要が無くなった。
if grep -q 'プロジェクト層ポリシーの正本は' "$ENTRY"; then
  pass
else
  fail "CLAUDE.md の「プロジェクト層ポリシーの正本は」の記述が失われている"
fi

# ── 検査ロジック自身の検証 ────────────────────────────────────────────────────
#
# 現行の雛形が緑なのは「正しく書かれている」からであって「検査が動いている」証明では
# ない。意図的に壊したフィクスチャで赤になることを別に示す。

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-project-ai-rules.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

it "「既定はありません」を消した空欄を検出する（意図的な負例）"
printf '%s\n' '- 何かの項目: （記載）' > "$FIXTURE_DIR/bad.md"
if printf '%s\n' "$(grep -nE '^[-*]|^[0-9]+\.' "$FIXTURE_DIR/bad.md" | grep -E ': （.*）$')" \
  | grep -v '既定はありません' | grep . >/dev/null; then
  pass
else
  fail "宣言の無い空欄を検出できない"
fi

it "「既定はありません」のある空欄は検出しない（対照群）"
printf '%s\n' '- 何かの項目: （記載。**既定はありません**）' > "$FIXTURE_DIR/ok.md"
if printf '%s\n' "$(grep -nE '^[-*]|^[0-9]+\.' "$FIXTURE_DIR/ok.md" | grep -E ': （.*）$')" \
  | grep -v '既定はありません' | grep . >/dev/null; then
  fail "宣言のある空欄を誤検出した"
else
  pass
fi

it "実在しないパスを検出する（意図的な負例）"
fake='scripts/this-does-not-exist.sh'
if printf '%s\n' "$GENERATED" | grep -Fxq "$fake"; then
  fail "フィクスチャのパスが実在してしまっている（前提が崩れた）"
elif printf '%s\n' "$PLAYBOOK" | grep -Fxq "$fake"; then
  fail "フィクスチャのパスが規範パッケージに実在してしまっている（前提が崩れた）"
elif [[ -f "$REPO_ROOT/.ai-playbook/templates/$(basename "$fake")" ]]; then
  fail "フィクスチャのパスが雛形として実在してしまっている（前提が崩れた）"
else
  pass
fi

it "実在するパスは誤検出しない（対照群）"
real='scripts/verify.sh'
if printf '%s\n' "$GENERATED" | grep -Fxq "$real"; then
  pass
else
  fail "実在するパスを抽出できていない（生成対象の抽出が壊れている）"
fi

exit_with_result
