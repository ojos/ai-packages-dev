#!/usr/bin/env bash
# test-jsonc.sh — devcontainer.json を JSONC（コメント付き）として読めることを検証する（#543）。
#
# --with-codex の devcontainer.json は、securityOpt の理由を説明するコメントを持つ。
# 厳密な JSON として読む箇所（doctor.sh、jq を直接掛ける試験）はコメントで落ちるため、
# コメントを除いてから jq へ渡す。確かめること:
#   - コメント付きの devcontainer.json を doctor.sh が valid と判定する
#   - 壊れた JSON は今までどおり invalid と判定する（コメントを許すことで何でも通さない）
#   - 文字列の中の // や /* を、コメントとして取り除かない（URL を壊さない）
#   - 生成物の再生成（--upgrade の dry-run）でコメントの有無が差分にならない
#
# bash 3.2 互換を維持する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-jsonc"

DOCTOR="$PKG_DIR/doctor.sh"

# doctor.sh の devcontainer.json の判定行（OK / FAIL）だけを返す。
doctor_json_line() {
  bash "$DOCTOR" --target-dir "$1" 2>&1 | grep 'devcontainer.json \(valid\|invalid\)' || true
}

OUT_CX="$(new_workdir)/p"
run_bootstrap "$OUT_CX" --with-codex >/dev/null 2>&1
DC_CX="$OUT_CX/.devcontainer/devcontainer.json"

it "前提: --with-codex の devcontainer.json はコメントを持つ（厳密な JSON としては読めない）"
if grep -qE '^  // ' "$DC_CX" 2>/dev/null && ! jq -e . "$DC_CX" >/dev/null 2>&1; then
  pass
else
  fail "コメントが無い、または厳密な JSON として読めてしまう"
fi

it "コメント付きの devcontainer.json を doctor.sh が valid と判定する"
line="$(doctor_json_line "$OUT_CX")"
if [[ "$line" == "[OK] devcontainer.json valid JSON"* ]]; then
  pass
else
  fail "valid と判定されない: [$line]"
fi

it "コメントの無い devcontainer.json も valid と判定する（対照）"
OUT_PL="$(new_workdir)/p"
run_bootstrap "$OUT_PL" >/dev/null 2>&1
line="$(doctor_json_line "$OUT_PL")"
if [[ "$line" == "[OK] devcontainer.json valid JSON"* ]]; then
  pass
else
  fail "valid と判定されない: [$line]"
fi

it "壊れた JSON は invalid と判定する（コメントがあっても）"
OUT_BAD="$(new_workdir)/p"
run_bootstrap "$OUT_BAD" --with-codex >/dev/null 2>&1
printf '%s\n' '{ // コメント' '  "name": "x",' '  "features": {' '}' > "$OUT_BAD/.devcontainer/devcontainer.json"
line="$(doctor_json_line "$OUT_BAD")"
if [[ "$line" == "[FAIL] devcontainer.json invalid JSON"* ]]; then
  pass
else
  fail "invalid と判定されない: [$line]"
fi

it "閉じていないブロックコメントは invalid と判定する"
printf '%s\n' '{ "name": "x" } /* 閉じていない' > "$OUT_BAD/.devcontainer/devcontainer.json"
line="$(doctor_json_line "$OUT_BAD")"
if [[ "$line" == "[FAIL] devcontainer.json invalid JSON"* ]]; then
  pass
else
  fail "invalid と判定されない: [$line]"
fi

it "文字列の中の // と /* を取り除かない（doctor.sh の読み方）"
# doctor.sh の関数を取り出して使う（単体で取得される前提で、doctor.sh 自身が持つ）。
fn_file="$(new_workdir)/fn.sh"
awk '/^jsonc_strip\(\) \{/ { p = 1 } p { print } p && /^\}/ { exit }' "$DOCTOR" > "$fn_file"
sample="$(new_workdir)/s.jsonc"
printf '%s\n' '{' \
  '  // 行コメント' \
  '  "url": "https://example.com/a//b", /* ブロック */' \
  '  "glob": "src/**/*.ts",' \
  '  "esc": "q\"//not-comment"' \
  '}' > "$sample"
got="$(bash -c '. "$1"; jsonc_strip "$2"' _ "$fn_file" "$sample" | jq -r '[.url, .glob, .esc] | join("|")' 2>&1)"
assert_eq "$got" 'https://example.com/a//b|src/**/*.ts|q"//not-comment' "URL・glob・エスケープを含む文字列"

it "試験用の jsonc_strip（lib.sh）も同じ結果になる"
got="$(jqc -r '[.url, .glob, .esc] | join("|")' "$sample" 2>&1)"
assert_eq "$got" 'https://example.com/a//b|src/**/*.ts|q"//not-comment' "URL・glob・エスケープを含む文字列"

it "--upgrade --dry-run で、手を入れていない codex 構成は差分なし（コメントを含めて同じ内容に再現できる）"
out="$(bash "$BOOTSTRAP" --upgrade --dry-run --output-dir "$OUT_CX" 2>&1)"
if [[ "$out" == *"plan: up-to-date "*"/.devcontainer/devcontainer.json"$'\n'* ]]; then
  pass
else
  fail "devcontainer.json が up-to-date と報告されない: $(printf '%s' "$out" | grep 'devcontainer\.json')"
fi

exit_with_result
