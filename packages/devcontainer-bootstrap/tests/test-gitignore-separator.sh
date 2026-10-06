#!/usr/bin/env bash
# test-gitignore-separator.sh — .gitignore の管理区画の手前の空行が累積しないことを検証する（#460）。
#
# 区画の外にある区切りの空行は awk の除去対象にならないため、以前は
# --upgrade のたびに 1 行ずつ増えていた。区切りは常に 1 行であること、
# 累積済みのファイルも 1 回の実行で 1 行に戻ることを確かめる。

set -uo pipefail

if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-gitignore-separator-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-gitignore-separator"

IMG="mcr.microsoft.com/devcontainers/base:noble"
BEGIN_MARK="# >>> devcontainer-bootstrap managed section >>>"

# 管理区画には github/gitignore のテンプレートを curl で取得して入れる。取得の成否や
# 公開内容が実行ごとに変わると「同じ入力」にならないため、curl を固定の出力へ差し替える。
STUB_BIN="$(new_workdir)/bin"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\nprintf "%%s\\n" "stub-template-entry"\n' > "$STUB_BIN/curl"
chmod +x "$STUB_BIN/curl"
export PATH="$STUB_BIN:$PATH"

gen() { # out [args...]
  local out="$1"; shift
  bash "$BOOTSTRAP" --project-name sep --languages node --base-image "$IMG" --output-dir "$out" "$@" >/dev/null 2>&1
}
upgrade() { # out — 終了コードは UP_RC
  bash "$BOOTSTRAP" --upgrade --output-dir "$1" >/dev/null 2>&1
  UP_RC=$?
}
# 管理区画の開始行の直前に並ぶ空行の数
blank_lines_before_section() {
  awk -v start="$BEGIN_MARK" '
    $0 == start {print n; exit}
    /^[[:space:]]*$/ {n++; next}
    {n=0}
  ' "$1"
}

# ── --upgrade を繰り返しても変わらない ───────────────────────────────────────

out="$(new_workdir)/p"
mkdir -p "$out"
printf 'node_modules\nmy-local-file\n' > "$out/.gitignore"
gen "$out"

it "管理区画のテンプレートは差し替えた curl から入る（入力が固定されている）"
if grep -qx 'stub-template-entry' "$out/.gitignore"; then pass; else fail "差し替えが効いていない"; fi

it "生成直後、プロジェクトの記述と管理区画の間の空行は 1 行"
assert_eq "$(blank_lines_before_section "$out/.gitignore")" "1"

upgrade "$out"; rc1=$UP_RC
first="$(cksum < "$out/.gitignore")"
upgrade "$out"; rc2=$UP_RC
second="$(cksum < "$out/.gitignore")"

it "--upgrade は 2 回とも成功する"
assert_eq "$rc1,$rc2" "0,0"

it "--upgrade を 2 回続けても、2 回目で .gitignore が変わらない"
assert_eq "$second" "$first"

it "--upgrade を重ねても、区切りの空行は 1 行のまま"
assert_eq "$(blank_lines_before_section "$out/.gitignore")" "1"

it "プロジェクトの記述は残る"
if grep -qx 'my-local-file' "$out/.gitignore"; then pass; else fail "my-local-file が消えた"; fi

# ── 累積済みの空行は 1 回で 1 行に戻る ──────────────────────────────────────

tmp="$(new_workdir)/g"
{ printf 'my-local-file\n\n\n\n'; sed -n "/^${BEGIN_MARK}\$/,\$p" "$out/.gitignore"; } > "$tmp"
cp "$tmp" "$out/.gitignore"
upgrade "$out"
it "空行が累積した .gitignore への --upgrade も成功する"
assert_eq "$UP_RC" "0"
it "空行が累積した .gitignore も、1 回の実行で区切り 1 行に戻る"
assert_eq "$(blank_lines_before_section "$out/.gitignore")" "1"

# ── プロジェクトの記述が無ければ、先頭に空行を作らない ─────────────────────

it "既存の .gitignore が空行だけなら、区画の手前に空行を残さない"
out2="$(new_workdir)/q"
mkdir -p "$out2"
printf '\n\n' > "$out2/.gitignore"
gen "$out2"
assert_eq "$(head -n1 "$out2/.gitignore")" "$BEGIN_MARK"

exit_with_result
