#!/usr/bin/env bash
# test-owned-list.sh — bootstrap.sh のプロジェクト所有の一覧（project_owned_rel_paths）と、
# README が「プロジェクトが所有・編集」と書くファイルの一致を機械照合する（#534）。
#
# 文書が実装の一覧を書き写している箇所は、片方だけの変更で黙って食い違うため、
# 一致を検査する（.ai-playbook/shared-ai-rules.md 12 章「一覧の複製は機械照合で担保する」）。
# README 側は「| `パス` | ... プロジェクトが所有・編集 ...」の表の行から取り出す。

set -uo pipefail

if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-owned-list-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-owned-list"

README="$PKG_DIR/README.md"

# 実装側: 関数の本体だけを切り出して評価し、出力を得る。
impl_list() { # [file]
  local f="${1:-$BOOTSTRAP}"
  ( eval "$(sed -n '/^project_owned_rel_paths() {$/,/^}$/p' "$f")"; project_owned_rel_paths ) | sort -u
}
# 文書側: 「プロジェクトが所有・編集」を含む表の行の、先頭セルのバッククォートのパス。
doc_list() { # [file]
  local f="${1:-$README}"
  command grep 'プロジェクトが所有・編集' "$f" | sed -n 's/^| `\([^`]*\)` |.*/\1/p' | sort -u
}

it "実装の一覧が空でない"
if [[ -n "$(impl_list)" ]]; then pass; else fail "project_owned_rel_paths を読めない"; fi

it "README の一覧が空でない"
if [[ -n "$(doc_list)" ]]; then pass; else fail "README に該当行が無い"; fi

it "実装の一覧と README の記述が一致する"
if [[ "$(impl_list)" == "$(doc_list)" ]]; then pass; else fail "実装: $(impl_list | tr '\n' ' ') / README: $(doc_list | tr '\n' ' ')"; fi

it "README の記述から 1 行落とすと不一致を検出する（検査が空振りしていない）"
cp "$README" "$TEST_TMP_ROOT/readme.mut"
command grep -v '^| `scripts/acceptance-remote.sh` | \*\*外部層\*\*の受け入れ条件（プロジェクトが所有・編集）' "$README" > "$TEST_TMP_ROOT/readme.mut"
if [[ "$(impl_list)" != "$(doc_list "$TEST_TMP_ROOT/readme.mut")" ]]; then pass; else fail "落としたのに一致のまま"; fi

it "実装の一覧へ 1 件足すと不一致を検出する"
sed "s|    'scripts/acceptance-remote.sh'\$|    'scripts/acceptance-remote.sh' \\\\\n    'scripts/extra.sh'|" "$BOOTSTRAP" > "$TEST_TMP_ROOT/bootstrap.mut"
if [[ "$(impl_list "$TEST_TMP_ROOT/bootstrap.mut")" != "$(doc_list)" ]]; then pass; else fail "足したのに一致のまま"; fi

exit_with_result
