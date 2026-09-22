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
#
# **ファイルを引数で受ける。** 本番の判定と負例のフィクスチャが**同じ関数を通る**
# ようにするため。フィクスチャ側で同じ処理を書き直すと、**本番の判定を無効化しても
# フィクスチャが緑のまま**になり、検査が壊れたことに誰も気づけない（この形を
# 実際に踏んだ。レビューの指摘）。
blank_fields() {
  grep -nE '^[-*]|^[0-9]+\.' "$1" | grep -E ': （.*）$'
}

# 空欄のうち、既定の不在を宣言していない行を返す。**判定の本体。**
undeclared_blanks() {
  blank_fields "$1" | grep -v '既定はありません' || true
}

it "雛形から空欄形式の行を抽出できる"
# 0 件のまま緑になると、以降の検査は対象ゼロで無条件に通る（偽の緑）。
BLANKS="$(blank_fields "$TEMPLATE")"
BLANK_COUNT="$(printf '%s\n' "$BLANKS" | grep -c . || true)"
if [[ "$BLANK_COUNT" -gt 0 ]]; then
  pass
else
  fail "空欄形式を 1 件も抽出できなかった（抽出が壊れているか、全廃された）"
fi

it "残した空欄がすべて「既定はありません」と宣言している"
# **これがこの検査の本体である。** 埋め忘れと意図的な未記入を、読む側が区別できる
# ようにする唯一の印。
undeclared="$(undeclared_blanks "$TEMPLATE")"
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

# 規範パッケージの雛形の**配置先**。`.ai-playbook/README.md` の cp 行から取る。
#
# **basename で照合しない。** ディレクトリ部分が見られず、
# `wrong-dir/second-opinion-review.sh` のような誤ったパスが通る（レビューの指摘。
# 実測で確認した）。cp 行は雛形と配置先の対応を正確に持っているので、そこから取る。
# 決め打ちにすると、規範側が置き先を変えたときに古い場所を見続けて緑のままになる
# （tests/test-workflow-mirror.sh と同じ理由）。
placed_paths() {
  grep -E '^cp \.ai-playbook/templates/' "$REPO_ROOT/.ai-playbook/README.md" \
    | awk '{ print $3 }' \
    | while IFS= read -r dest; do
        case "$dest" in
          */) printf '%s%s\n' "$dest" "$(basename "$(grep -E "^cp .*${dest}\$" "$REPO_ROOT/.ai-playbook/README.md" | awk '{ print $2 }' | sed -n 1p)")" ;;
          *)  printf '%s\n' "$dest" ;;
        esac
      done
}

# 一覧に無いパスを返す。**判定の本体。** 標準入力からパスを受ける。
unknown_paths() {
  local generated="$1" playbook="$2" placed="$3" path
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "
$EXCLUDED
" in *"
$path
"*) continue ;; esac
    printf '%s\n' "$generated" | grep -Fxq "$path" && continue
    printf '%s\n' "$playbook" | grep -Fxq "$path" && continue
    printf '%s\n' "$placed" | grep -Fxq "$path" && continue
    printf '%s\n' "$path"
  done
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
PLACED="$(placed_paths)"
missing="$(printf '%s\n' "$PATHS" | unknown_paths "$GENERATED" "$PLAYBOOK" "$PLACED")"
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
# **本番と同じ関数を通す。** ここで同じ処理を書き直すと、本番の判定を無効化しても
# この検査が緑のままになり、検査が壊れたことに誰も気づけない（実測で踏んだ）。
printf '%s\n' '- 何かの項目: （記載）' > "$FIXTURE_DIR/bad.md"
if [[ -n "$(undeclared_blanks "$FIXTURE_DIR/bad.md")" ]]; then
  pass
else
  fail "宣言の無い空欄を検出できない（判定の本体が壊れている）"
fi

it "「既定はありません」のある空欄は検出しない（対照群）"
printf '%s\n' '- 何かの項目: （記載。**既定はありません**）' > "$FIXTURE_DIR/ok.md"
if [[ -z "$(undeclared_blanks "$FIXTURE_DIR/ok.md")" ]]; then
  pass
else
  fail "宣言のある空欄を誤検出した"
fi

it "空欄でない行は拾わない（対照群）"
# 地の文の例示（`（例: \`src\` / \`docs\`）` のような形）を拾うと、正しい記述を
# 落とす方向の修正を招く。
printf '%s\n' 'トップレベル構造（例: `src` / `docs`）は推奨として扱います。' > "$FIXTURE_DIR/prose.md"
if [[ -z "$(blank_fields "$FIXTURE_DIR/prose.md")" ]]; then
  pass
else
  fail "地の文を空欄として拾った"
fi

it "実在しないパスを検出する（意図的な負例）"
# **本番と同じ関数へ流す。** 「実在しないこと」を別経路で確かめるだけでは、
# 判定ループが欠落パスを常に合格にするよう壊れていても緑のままになる。
fake="$(printf '%s\n' 'scripts/this-does-not-exist.sh' | unknown_paths "$GENERATED" "$PLAYBOOK" "$PLACED")"
if [[ "$fake" == "scripts/this-does-not-exist.sh" ]]; then
  pass
else
  fail "実在しないパスを検出できない（判定の本体が壊れている）: ${fake:-なし}"
fi

it "実在するパスは誤検出しない（対照群）"
known="$(printf '%s\n' 'scripts/verify.sh' | unknown_paths "$GENERATED" "$PLAYBOOK" "$PLACED")"
if [[ -z "$known" ]]; then
  pass
else
  fail "実在するパスを欠落として報告した: $known"
fi

it "ディレクトリ部分の違うパスを検出する（basename 照合では通ってしまう形）"
# `.ai-playbook/templates/second-opinion-review.sh` は実在するが、配置先は
# `scripts/second-opinion-review.sh` である。basename だけを見ると誤った
# ディレクトリのパスが通る（レビューの指摘。実測で確認した）。
wrong="$(printf '%s\n' 'wrong-dir/second-opinion-review.sh' | unknown_paths "$GENERATED" "$PLAYBOOK" "$PLACED")"
if [[ "$wrong" == "wrong-dir/second-opinion-review.sh" ]]; then
  pass
else
  fail "ディレクトリ部分の違うパスを見逃した: ${wrong:-なし}"
fi

it "雛形の配置先を README の cp 行から取れている（対照群）"
# 決め打ちにすると、規範側が置き先を変えたときに古い場所を見続けて緑のままになる。
placed_ok="$(printf '%s\n' 'scripts/second-opinion-review.sh' | unknown_paths "$GENERATED" "$PLAYBOOK" "$PLACED")"
if [[ -z "$placed_ok" ]]; then
  pass
else
  fail "README の cp 行から配置先を取れていない: $placed_ok"
fi

exit_with_result
