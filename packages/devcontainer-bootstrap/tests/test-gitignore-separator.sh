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

gen() { # out [args...]
  local out="$1"; shift
  bash "$BOOTSTRAP" --project-name sep --languages node --base-image "$IMG" --output-dir "$out" "$@" >/dev/null 2>&1
}
upgrade() { # out
  bash "$BOOTSTRAP" --upgrade --output-dir "$1" >/dev/null 2>&1
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

it "生成直後、プロジェクトの記述と管理区画の間の空行は 1 行"
assert_eq "$(blank_lines_before_section "$out/.gitignore")" "1"

upgrade "$out"
first="$(cksum < "$out/.gitignore")"
upgrade "$out"
second="$(cksum < "$out/.gitignore")"

it "--upgrade を 2 回続けても、2 回目で .gitignore が変わらない"
assert_eq "$second" "$first"

it "--upgrade を重ねても、区切りの空行は 1 行のまま"
assert_eq "$(blank_lines_before_section "$out/.gitignore")" "1"

it "プロジェクトの記述は残る"
if grep -qx 'my-local-file' "$out/.gitignore"; then pass; else fail "my-local-file が消えた"; fi

# ── 累積済みの空行は 1 回で 1 行に戻る ──────────────────────────────────────

it "空行が累積した .gitignore も、1 回の実行で区切り 1 行に戻る"
tmp="$(new_workdir)/g"
{ printf 'my-local-file\n\n\n\n'; sed -n "/^${BEGIN_MARK}\$/,\$p" "$out/.gitignore"; } > "$tmp"
cp "$tmp" "$out/.gitignore"
upgrade "$out"
assert_eq "$(blank_lines_before_section "$out/.gitignore")" "1"

# ── プロジェクトの記述が無ければ、先頭に空行を作らない ─────────────────────

it "既存の .gitignore が空行だけなら、区画の手前に空行を残さない"
out2="$(new_workdir)/q"
mkdir -p "$out2"
printf '\n\n' > "$out2/.gitignore"
gen "$out2"
assert_eq "$(head -n1 "$out2/.gitignore")" "$BEGIN_MARK"

exit_with_result
