#!/usr/bin/env bash
# test-doctor-claude-version.sh — doctor.sh の claude の版の検査を検証する。
#
# blockWritesOutsideWorkingDirectories は下限より古い claude では黙って無視される。
# 偽の claude を PATH の先頭に置いて、古い→WARN／新しい→PASS／無い→検査しない／
# 読めない→WARN を確かめる。ネットワークには出ない。bash 3.2 互換。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-doctor-claude-version"

DOCTOR="$PKG_DIR/doctor.sh"
BASE="$(new_workdir)/base"
run_bootstrap "$BASE" >/dev/null 2>&1

# 偽の claude を置いた bin ディレクトリを作る。$1=--version の出力（空なら失敗する claude）
fake_bin() {
  local d
  d="$(new_workdir)/bin"
  mkdir -p "$d"
  if [[ -n "$1" ]]; then
    printf '#!/usr/bin/env bash\necho "%s"\n' "$1" >"$d/claude"
  else
    printf '#!/usr/bin/env bash\nexit 1\n' >"$d/claude"
  fi
  chmod +x "$d/claude"
  printf '%s' "$d"
}

# 実在の claude を見えなくするため、PATH は偽 bin + 最小限のシステム領域だけにする。
run_doctor() { # PATH 先頭へ足すディレクトリ（空可）
  DOC_OUT="$(PATH="${1:+$1:}/usr/bin:/bin" bash "$DOCTOR" --target-dir "$BASE" 2>&1)"
}

it "claude が古い（2.1.296）と WARN で、効かないことを知らせる"
run_doctor "$(fake_bin '2.1.296 (Claude Code)')"
assert_contains "$DOC_OUT" "[WARN] claude 2.1.296 is older than 2.1.314" "古い版の WARN"

it "claude が下限ちょうど（2.1.314）なら OK"
run_doctor "$(fake_bin '2.1.314 (Claude Code)')"
assert_contains "$DOC_OUT" "[OK] claude 2.1.314 supports" "下限ちょうど"

it "claude が新しい（2.10.0）と OK（文字列比較ではなく数値比較）"
run_doctor "$(fake_bin '2.10.0 (Claude Code)')"
assert_contains "$DOC_OUT" "[OK] claude 2.10.0 supports" "桁の多い版"

it "claude が無ければ検査しない（行を出さない）"
run_doctor ""
if PATH="/usr/bin:/bin" command -v claude >/dev/null 2>&1; then
  pass # 標準の場所に実在する claude があり、無い状態を作れない
elif printf '%s' "$DOC_OUT" | command grep 'claude [0-9]\|claude version' >/dev/null; then
  fail "claude が無いのに検査の行が出た"
else
  pass
fi

it "版を読めないとき（出力が版でない）は WARN"
run_doctor "$(fake_bin 'unknown')"
assert_contains "$DOC_OUT" "claude version could not be determined" "読めない版"

it "claude --version が失敗するときは WARN"
run_doctor "$(fake_bin '')"
assert_contains "$DOC_OUT" "claude version could not be determined" "失敗する claude"

exit_with_result
