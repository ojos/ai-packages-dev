#!/usr/bin/env bash
# tests/test-dcb-version-anchors.sh — DCB のバージョン正本の「箇所数」が
# RUNBOOK と release-packages.sh の実装で揃っていること、および
# validate_dcb_docs が実際に bootstrap.sh / doctor.sh の DCB_VERSION まで
# 照合していることを検査する。
#
# 背景（#321 の波及）: bootstrap.sh / doctor.sh へ生成物の由来診断のための
# DCB_VERSION を埋め込んだ結果、リリース時に版を揃える箇所が README の 3 箇所から
# 5 箇所へ増えた。docs/release/RELEASE_EXECUTION_RUNBOOK.md「バージョンの正本」節に
# 「揃えること」と書き足すだけでは呼びかけに留まり、validate_dcb_docs が実際に
# 照合していなければリリース時に静かにずれる。
#
# 「N 箇所」という件数は RUNBOOK 中に 3 通りの表現で現れる（表の 1 行 / 節見出し文 /
# 実行手順の箇条書き）。テスト側へ期待件数を書き写すと、実装とテストの両方が
# RUNBOOK から独立して古くなるため、突き合わせの相手は常に実装
# （validate_dcb_docs 本体の grep 行数）にする。tests/test-runbook-preflight.sh と
# 同じ考え方（#161 の教訓）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-dcb-version-anchors"

RUNBOOK="$REPO_ROOT/docs/release/RELEASE_EXECUTION_RUNBOOK.md"
RELEASE="$REPO_ROOT/scripts/release-packages.sh"

# ── RUNBOOK 側: 「バージョンの正本」節の DCB 番号付き一覧 ────────────────────

# "- DCB: ..." から "- ai-playbook:" までに含まれる、番号付き一覧（"  1. " 形式）の項目数。
dcb_anchor_list_count() {
  awk '
    /^## バージョンの正本/ { inside = 1; next }
    inside && /^- ai-playbook:/ { exit }
    inside && /^  [0-9]+\. / { n++ }
    END { print n + 0 }
  ' "$RUNBOOK"
}

# 「N 箇所」という件数の表明を、3 つの独立した文言からそれぞれ抜き出す。
# 表現が違う（README サブセットへの言及「3 箇所」と混同しない）ため、
# 周辺の固定文言ごと照合する。
count_in_preflight_table() {
  grep -oE 'DCB のバージョン正本照合（[0-9]+ 箇所' "$RUNBOOK" | grep -oE '[0-9]+'
}
count_in_anchor_section() {
  grep -oE '次の \*\*[0-9]+ 箇所\*\*を照合' "$RUNBOOK" | grep -oE '[0-9]+'
}
count_in_procedure_bullet() {
  grep -oE 'バージョンの正本 [0-9]+ 箇所（' "$RUNBOOK" | grep -oE '[0-9]+'
}

LIST_COUNT="$(dcb_anchor_list_count)"
TABLE_COUNT="$(count_in_preflight_table)"
SECTION_COUNT="$(count_in_anchor_section)"
PROCEDURE_COUNT="$(count_in_procedure_bullet)"

it "「バージョンの正本」節の DCB 番号付き一覧を抽出できる"
if [[ "$LIST_COUNT" -gt 0 ]]; then pass; else fail "一覧を抽出できなかった（0 件）"; fi

it "preflight 表の「N 箇所」を抽出できる"
if [[ -n "$TABLE_COUNT" ]]; then pass; else fail "抽出できなかった"; fi

it "「バージョンの正本」節見出し文の「N 箇所」を抽出できる"
if [[ -n "$SECTION_COUNT" ]]; then pass; else fail "抽出できなかった"; fi

it "実行手順の箇条書きの「N 箇所」を抽出できる"
if [[ -n "$PROCEDURE_COUNT" ]]; then pass; else fail "抽出できなかった"; fi

it "RUNBOOK 内の 3 つの「N 箇所」表明が番号付き一覧の項目数と一致する"
if [[ "$TABLE_COUNT" == "$LIST_COUNT" && "$SECTION_COUNT" == "$LIST_COUNT" && "$PROCEDURE_COUNT" == "$LIST_COUNT" ]]; then
  pass
else
  fail "件数が食い違う（一覧=$LIST_COUNT 表=$TABLE_COUNT 節見出し文=$SECTION_COUNT 実行手順=$PROCEDURE_COUNT）"
fi

# ── 実装側: validate_dcb_docs 本体の照合件数 ──────────────────────────────────

# 関数本体を「validate_dcb_docs() {」から、関数自身の閉じ括弧（行頭の "}"）まで
# 抽出する。内側の `|| { ... }` はインデントされるため行頭には現れず、
# 誤って途中で抽出を止めない。
validate_dcb_docs_body() {
  awk '
    /^validate_dcb_docs\(\) \{/ { f = 1 }
    f { print }
    f && /^}$/ { exit }
  ' "$RELEASE"
}

BODY="$(validate_dcb_docs_body)"

it "validate_dcb_docs の本体を抽出できる"
if [[ -n "$BODY" ]]; then pass; else fail "抽出できなかった"; fi

# コメント行を除いた grep 呼び出しの本数 = 照合している「箇所」の数。
IMPL_COUNT="$(printf '%s\n' "$BODY" | grep -v '^[[:space:]]*#' | grep -cE '^[[:space:]]*grep ')"

it "validate_dcb_docs から照合行を抽出できる"
if [[ "$IMPL_COUNT" -gt 0 ]]; then pass; else fail "grep による照合行を抽出できなかった（0 件）"; fi

it "RUNBOOK の箇所数と validate_dcb_docs の照合件数が一致する"
assert_eq "$IMPL_COUNT" "$LIST_COUNT" "照合件数"

it "validate_dcb_docs が bootstrap.sh を照合対象に持つ（README だけでなくスクリプトも見る）"
case "$BODY" in
  *'"$bootstrap"'*) pass ;;
  *) fail "bootstrap.sh への参照が本体に無い" ;;
esac

it "validate_dcb_docs が doctor.sh を照合対象に持つ"
case "$BODY" in
  *'"$doctor"'*) pass ;;
  *) fail "doctor.sh への参照が本体に無い" ;;
esac

# ── 実際に呼び出して確かめる: タグとずれていれば落ちる ────────────────────────
#
# 関数定義だけを取り込む（実行部の手前まで）。
# packages/devcontainer-bootstrap/tests/test-release-contract.sh と同じ手法。

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-dcb-version-anchors.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

END_LINE="$(grep -n '^EXECUTE="false"' "$RELEASE" | head -1 | cut -d: -f1)"
FNS="$TMP_ROOT/fns.sh"
head -n $((END_LINE - 1)) "$RELEASE" > "$FNS"

# 実物の 3 ファイルを、相対パスを保ったまま作業コピーへ複製する。
# validate_dcb_docs は "packages/devcontainer-bootstrap/..." を CWD 相対で開くため。
fixture_dir() {
  local dir="$1"
  mkdir -p "$dir/packages/devcontainer-bootstrap"
  cp "$REPO_ROOT/packages/devcontainer-bootstrap/README.md" "$dir/packages/devcontainer-bootstrap/README.md"
  cp "$REPO_ROOT/packages/devcontainer-bootstrap/bootstrap.sh" "$dir/packages/devcontainer-bootstrap/bootstrap.sh"
  cp "$REPO_ROOT/packages/devcontainer-bootstrap/doctor.sh" "$dir/packages/devcontainer-bootstrap/doctor.sh"
}

# 現行の README が固定しているタグ（"- `vX.Y.Z`" 行）を実値から読む。決め打ちすると
# リリースのたびにこのテストだけ古くなる。
current_tag="$(grep -oE '^- `v[0-9]+\.[0-9]+\.[0-9]+`$' "$REPO_ROOT/packages/devcontainer-bootstrap/README.md" \
  | head -1 | sed -e 's/^- `//' -e 's/`$//')"

it "README から現行タグを読み取れる（フィクスチャの前提）"
if [[ -n "$current_tag" ]]; then pass; else fail "現行タグを抽出できなかった"; fi

run_validate() {
  local dir="$1" tag="$2"
  ( set -euo pipefail; . "$FNS"; cd "$dir" && validate_dcb_docs "$tag" ) >/dev/null 2>&1
}

it "5 箇所すべてが揃っていれば通る（対照群）"
ok_dir="$TMP_ROOT/ok"
fixture_dir "$ok_dir"
if run_validate "$ok_dir" "$current_tag"; then pass; else fail "揃っているのに落ちた"; fi

it "bootstrap.sh の DCB_VERSION だけがずれていると落ちる"
bad_bootstrap_dir="$TMP_ROOT/bad-bootstrap"
fixture_dir "$bad_bootstrap_dir"
printf '%s\n' 'DCB_VERSION="v0.0.1-mutated"' > "$TMP_ROOT/repl.txt"
awk -v newline="$(cat "$TMP_ROOT/repl.txt")" '
  /^DCB_VERSION="/ { print newline; next } { print }
' "$bad_bootstrap_dir/packages/devcontainer-bootstrap/bootstrap.sh" > "$bad_bootstrap_dir/packages/devcontainer-bootstrap/bootstrap.sh.new"
mv "$bad_bootstrap_dir/packages/devcontainer-bootstrap/bootstrap.sh.new" "$bad_bootstrap_dir/packages/devcontainer-bootstrap/bootstrap.sh"
if run_validate "$bad_bootstrap_dir" "$current_tag"; then
  fail "bootstrap.sh の版がずれているのに通った"
else
  pass
fi

it "doctor.sh の DCB_VERSION だけがずれていると落ちる"
bad_doctor_dir="$TMP_ROOT/bad-doctor"
fixture_dir "$bad_doctor_dir"
awk -v newline="$(cat "$TMP_ROOT/repl.txt")" '
  /^DCB_VERSION="/ { print newline; next } { print }
' "$bad_doctor_dir/packages/devcontainer-bootstrap/doctor.sh" > "$bad_doctor_dir/packages/devcontainer-bootstrap/doctor.sh.new"
mv "$bad_doctor_dir/packages/devcontainer-bootstrap/doctor.sh.new" "$bad_doctor_dir/packages/devcontainer-bootstrap/doctor.sh"
if run_validate "$bad_doctor_dir" "$current_tag"; then
  fail "doctor.sh の版がずれているのに通った"
else
  pass
fi

it "README の TAG= 行だけがずれていても落ちる（対照群: 既存 3 箇所の照合が壊れていない）"
bad_readme_dir="$TMP_ROOT/bad-readme"
fixture_dir "$bad_readme_dir"
sed_out="$TMP_ROOT/readme.new"
awk '{ gsub(/TAG=v[0-9]+\.[0-9]+\.[0-9]+/, "TAG=v0.0.1-mutated"); print }' \
  "$bad_readme_dir/packages/devcontainer-bootstrap/README.md" > "$sed_out"
mv "$sed_out" "$bad_readme_dir/packages/devcontainer-bootstrap/README.md"
if run_validate "$bad_readme_dir" "$current_tag"; then
  fail "README の TAG= がずれているのに通った"
else
  pass
fi

exit_with_result
