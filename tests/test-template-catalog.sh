#!/usr/bin/env bash
# 規範パッケージの雛形一覧について、README の記述と templates/ の実体が食い違って
# いないことを検査する。
#
# .ai-playbook/README.md は雛形を 2 か所で書き写している。
#
#   1. 「管理対象」の表 —— 種類数（`導入用の雛形 N 種`）と、その内訳の一覧
#   2. 「導入手順」の cp 行 —— どこへ置くかの手順
#
# 雛形を 1 つ足したとき、実体は増えるが上の 2 か所は自動では追随しない。しかも
# 追随漏れは静かに起きる（README を読んだ人が「5 種しかない」と思うだけで、テストも
# CI も何も言わない）。規範「文書が実装の一覧を書き写している箇所は機械照合へ載せる」
# （.github/project-ai-rules.md「統合検証」）に対応する検査。
#
# 数と内訳の両方を見る。数だけを見ると、雛形の入れ替え（数が変わらない変更）を
# 素通りさせるため。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-template-catalog"

TEMPLATES_DIR="$REPO_ROOT/.ai-playbook/templates"
README="$REPO_ROOT/.ai-playbook/README.md"

# ── 抽出 ──────────────────────────────────────────────────────────────────────

# templates/ の実体。サブディレクトリは今のところ無いが、増えても直下のファイルだけを
# 一覧の対象とする（README が並べているのは配置単位のファイル）。
ACTUAL="$(find "$TEMPLATES_DIR" -maxdepth 1 -type f -exec basename {} \; | sort)"

# 「管理対象」の表の行。行頭が `| \`templates/\` |` の 1 行だけを取る。
CATALOG_ROW="$(grep -F '| `templates/` |' "$README" | head -n 1)"

# 表が書いている種類数。
CATALOG_COUNT="$(printf '%s\n' "$CATALOG_ROW" | sed -nE 's/.*導入用の雛形 ([0-9]+) 種.*/\1/p')"

# 表が並べているファイル名。バッククォートで囲まれたトークンのうち、
# ディレクトリ名そのもの（`templates/`）を除いたもの。
CATALOG_NAMES="$(printf '%s\n' "$CATALOG_ROW" \
  | grep -oE '`[^`]+`' \
  | tr -d '`' \
  | grep -v '/$' \
  | sort -u)"

# 導入手順が置き先を示しているファイル名（`.ai-playbook/templates/<name>` の形）。
STEP_NAMES="$(grep -oE 'templates/[A-Za-z0-9._-]+' "$README" \
  | sed 's|^templates/||' \
  | sort -u)"

ACTUAL_COUNT="$(printf '%s\n' "$ACTUAL" | grep -c .)"

# ── 照合 ──────────────────────────────────────────────────────────────────────

it "templates/ から雛形を抽出できる"
if [[ "$ACTUAL_COUNT" -gt 0 ]]; then
  pass
else
  fail "$TEMPLATES_DIR から雛形を抽出できなかった"
fi

it "README の管理対象表に templates/ の行がある"
if [[ -n "$CATALOG_ROW" ]]; then
  pass
else
  fail "README から '| \`templates/\` |' の行を抽出できなかった"
fi

it "README が記述する雛形の種類数が実体と一致する"
if [[ -z "$CATALOG_COUNT" ]]; then
  fail "README から「導入用の雛形 N 種」を抽出できなかった"
else
  assert_eq "$CATALOG_COUNT" "$ACTUAL_COUNT" "README が記述する雛形の種類数"
fi

it "README の管理対象表が並べる雛形が実体と一致する"
assert_same_set "$CATALOG_NAMES" "$ACTUAL" "README の表" "templates/"

it "README の導入手順がすべての雛形の置き先を示している"
# 置き先の書かれていない雛形は、配布されても誰も置かない。逆に、実体の無い雛形を
# 手順が指していると、その手順は必ず失敗する。両方向を見る。
assert_same_set "$STEP_NAMES" "$ACTUAL" "README の導入手順" "templates/"

exit_with_result
