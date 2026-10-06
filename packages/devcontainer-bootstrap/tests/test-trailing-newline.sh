#!/usr/bin/env bash
# test-trailing-newline.sh — 生成物が末尾を改行で終えることを検証する（#462）。
#
# 雛形の中身は $(...) を通る過程で末尾の改行が剥がれるため、以前は .env.example や
# scripts/*.sh など write_file を通る生成物の末尾に改行が無く、利用者が手で整えた版や
# .dcb-new との diff に「\ No newline at end of file」が出ていた。

set -uo pipefail

if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-trailing-newline-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-trailing-newline"

IMG="mcr.microsoft.com/devcontainers/base:noble"

# 中身があり、末尾が改行でないファイルを列挙する
files_without_trailing_newline() {
  (cd "$1" && find . -type f | sort | while IFS= read -r f; do
    [[ -s "$f" ]] || continue
    [[ "$(tail -c1 "$f" | od -An -tx1 | tr -d ' ')" == "0a" ]] || printf '%s\n' "$f"
  done)
}

out="$(new_workdir)/p"
bash "$BOOTSTRAP" --project-name nl --languages node --base-image "$IMG" --output-dir "$out" \
  --with-claude --playbook-from "$PLAYBOOK_SRC" >/dev/null 2>&1

it "生成物はすべて末尾を改行で終える"
missing="$(files_without_trailing_newline "$out")"
if [[ -z "$missing" ]]; then pass; else fail "末尾に改行が無い: $(printf '%s' "$missing" | tr '\n' ' ')"; fi

it ".env.example は末尾の改行を 1 つだけ持つ（空行を足さない）"
assert_eq "$(tail -c2 "$out/.env.example" | od -An -tx1 | tr -d ' ')" "$(printf '=\n' | od -An -tx1 | tr -d ' ')"

it "手を入れていない生成物へ --upgrade しても、.dcb-new を置かない"
bash "$BOOTSTRAP" --upgrade --output-dir "$out" --playbook-from "$PLAYBOOK_SRC" >/dev/null 2>&1
leftovers="$(cd "$out" && find . -name '*.dcb-new' | sort)"
if [[ -z "$leftovers" ]]; then pass; else fail ".dcb-new が置かれた: $(printf '%s' "$leftovers" | tr '\n' ' ')"; fi

exit_with_result
