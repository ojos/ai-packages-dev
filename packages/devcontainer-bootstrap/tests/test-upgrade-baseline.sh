#!/usr/bin/env bash
# test-upgrade-baseline.sh — bootstrap.sh --upgrade --baseline-from <dir>（#536）と、
# ORIGIN が無い出力先の移行（#535 から統合）を検証する。
#
# 確かめること:
#   - ORIGIN が無く、現物 = baseline の同じ相対パスのファイルは、新しい版へ更新され .dcb-new が出ない
#   - baseline と違う（手を入れた）・baseline に無い・baseline 側がリンクのファイルは keep (no record) と .dcb-new
#   - 更新したあと doctor.sh が unchanged と報告する。手を入れたものを取り込んで --accept すると accepted と報告する
#   - --dry-run は plan: update (baseline match) を出し、何も書かない
#   - --upgrade なしの --baseline-from、存在しない <dir> は 0 以外で止まり何も書かない
#   - hash: の記録があるファイルは、baseline と一致しても記録に従う
#   - --baseline-from を渡さないと、記録の無い現物は keep (no record)
#   - README に移行の手順がある

set -uo pipefail

if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-baseline-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-upgrade-baseline"

IMG="mcr.microsoft.com/devcontainers/base:noble"
DOCTOR="$PKG_DIR/doctor.sh"
ORIGIN_REL=".devcontainer/ORIGIN"
A="scripts/verify.sh"                 # baseline と一致（DCB のテンプレート）
P=".ai-playbook/review-workflow.md"   # baseline と一致（規範ファイル）
B="scripts/on-attach.sh"              # baseline と違う（手を入れた）
C="scripts/load-project-env.sh"       # baseline に無い
D="scripts/loop-gate.sh"              # baseline 側がリンク

gen() { # out [args...]
  local out="$1"; shift
  bash "$BOOTSTRAP" --project-name bl --languages node --base-image "$IMG" --output-dir "$out" --playbook-from "$PLAYBOOK_SRC" "$@" >/dev/null 2>&1
}
upgrade() { # out [args...] — 出力は UP_OUT、終了コードは UP_RC。ORIGIN が無いので入力を明示する
  local out="$1"; shift
  UP_OUT="$(bash "$BOOTSTRAP" --upgrade --project-name bl --languages node --base-image "$IMG" --output-dir "$out" --playbook-from "$PLAYBOOK_SRC" "$@" 2>&1)"
  UP_RC=$?
}
# 現物を「旧い版を模した内容」（末尾に 1 行足したもの）へ書き換える（モードを保つため cat で流し込む）。
age() { # file
  { cat "$1"; printf '# old version\n'; } > "$1.tmp"
  cat "$1.tmp" > "$1"
  rm -f "$1.tmp"
}
# 出力先 out を作り、現物を旧い版の模造にし、baseline ディレクトリを組み、ORIGIN を消す。
setup() { # out base
  local out="$1" base="$2" f
  gen "$out"
  for f in "$A" "$P" "$B" "$C" "$D"; do age "$out/$f"; done
  mkdir -p "$base/scripts" "$base/.ai-playbook"
  cat "$out/$A" > "$base/$A"
  cat "$out/$P" > "$base/$P"
  # B は手を入れる前の内容を baseline に置く（現物と違う）
  cat "$out/$B" > "$base/$B"
  printf '# hand edit\n' >> "$out/$B"
  # D は baseline 側がリンク（中身は現物と同じ）
  cat "$out/$D" > "$base/scripts/loop-gate.real"
  ln -s loop-gate.real "$base/$D"
  rm -f "$out/$ORIGIN_REL"
}
sums() { # dir — ファイルとリンクの一覧と内容の checksum
  ( cd "$1" && find . \( -type f -o -type l \) | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f" 2>/dev/null)"; done )
}

out="$(new_workdir)/p"; base="$(new_workdir)/base"
setup "$out" "$base"
base_sum_before="$(sums "$base")"

it "--dry-run は plan: update (baseline match) を出し、何も書かない"
before="$(sums "$out")"
upgrade "$out" --baseline-from "$base" --dry-run
after="$(sums "$out")"
if [[ "$UP_OUT" == *"plan: update (baseline match) $out/$A"* && "$UP_OUT" == *"plan: update (baseline match) $out/$P"* && "$before" == "$after" ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "--baseline-from を渡さないと、手を入れていなくても keep (no record) と .dcb-new が出る（旧い版の模造）"
out0="$(new_workdir)/p"; base0="$(new_workdir)/base"
setup "$out0" "$base0"
upgrade "$out0"
if [[ "$UP_OUT" == *"keep (no record): $out0/$A"* && -e "$out0/$A.dcb-new" ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "--baseline-from で、現物 = baseline のファイルが新しい版へ更新され、.dcb-new が出ない"
upgrade "$out" --baseline-from "$base"
if [[ "$UP_OUT" == *"write: $out/$A (upgraded, baseline match)"* && "$UP_OUT" == *"write: $out/$P (upgraded, baseline match)"* \
  && ! -e "$out/$A.dcb-new" && ! -e "$out/$P.dcb-new" && -z "$(command grep 'old version' "$out/$A" || true)" ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "baseline と違う・baseline に無い・baseline 側がリンクのファイルは keep (no record) と .dcb-new"
ok=1
for f in "$B" "$C" "$D"; do
  [[ "$UP_OUT" == *"keep (no record): $out/$f"* && -e "$out/$f.dcb-new" ]] || ok=0
done
if [[ "$ok" == "1" && "$UP_RC" == "2" ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "<dir> の中身を書き換えない"
if [[ "$base_sum_before" == "$(sums "$base")" ]]; then pass; else fail "baseline が変わった"; fi

it "更新したファイルを doctor.sh が unchanged と報告し、更新したパスを変化として挙げない"
bash "$DOCTOR" --target-dir "$out" >"$TEST_TMP_ROOT/doctor.out" 2>&1
changed_line="$(command grep '^\[FAIL\] changed since generation' "$TEST_TMP_ROOT/doctor.out" || true)"
if [[ -n "$changed_line" && "$changed_line" != *"$A"* && "$changed_line" != *"$P"* ]]; then pass; else fail "$changed_line"; fi

it "baseline で更新しただけの出力先は、doctor.sh --strict が unchanged と報告して 0 で終わる"
out4="$(new_workdir)/p"; base4="$(new_workdir)/base"
gen "$out4"
age "$out4/$A"
mkdir -p "$base4/scripts"; cat "$out4/$A" > "$base4/$A"
rm -f "$out4/$ORIGIN_REL"
upgrade "$out4" --baseline-from "$base4"
bash "$DOCTOR" --strict --target-dir "$out4" >"$TEST_TMP_ROOT/doctor.out" 2>&1; rc=$?
if [[ "$rc" == "0" ]] && command grep 'unchanged since generation' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc $(command grep -E 'FAIL|WARN' "$TEST_TMP_ROOT/doctor.out")"; fi

it "手を入れたファイルを取り込んで .dcb-new を消し --accept すると、doctor.sh が accepted と報告する"
cat "$out/$B.dcb-new" > "$out/$B"
printf '# hand edit\n' >> "$out/$B"
rm -f "$out/$B.dcb-new"
acc_out="$(bash "$BOOTSTRAP" --accept "$B" --output-dir "$out" 2>&1)"; acc_rc=$?
bash "$DOCTOR" --target-dir "$out" >"$TEST_TMP_ROOT/doctor.out" 2>&1
if [[ "$acc_rc" == "0" ]] && command grep 'accepted as merged' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$acc_rc $acc_out $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

it "hash: の記録があるファイルは、baseline と一致しても記録に従って振り分ける"
out2="$(new_workdir)/p"; base2="$(new_workdir)/base"
gen "$out2"
printf '# edited\n' >> "$out2/$A"
mkdir -p "$base2/scripts"; cat "$out2/$A" > "$base2/$A"
upgrade "$out2" --baseline-from "$base2"
if [[ "$UP_OUT" == *"modified (template unchanged): $out2/$A"* && "$UP_OUT" != *"baseline match"* && ! -e "$out2/$A.dcb-new" ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "--upgrade なしの --baseline-from は 0 以外で止まり、何も書かない"
out3="$(new_workdir)/p"
bash "$BOOTSTRAP" --project-name bl --languages node --base-image "$IMG" --output-dir "$out3" --playbook-from "$PLAYBOOK_SRC" --baseline-from "$base" >"$TEST_TMP_ROOT/o.txt" 2>&1; rc=$?
if [[ "$rc" != "0" && ! -e "$out3" ]]; then pass; else fail "rc=$rc"; fi

it "存在しない <dir> は 0 以外で止まり、何も書かない"
before="$(sums "$out2")"
upgrade "$out2" --baseline-from "$TEST_TMP_ROOT/no-such-dir"
if [[ "$UP_RC" != "0" && "$before" == "$(sums "$out2")" ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "--accept や --force と一緒の --baseline-from は 0 以外で止まる"
bash "$BOOTSTRAP" --accept "$A" --baseline-from "$base" --output-dir "$out2" >/dev/null 2>&1; rc1=$?
bash "$BOOTSTRAP" --upgrade --force --baseline-from "$base" --output-dir "$out2" >/dev/null 2>&1; rc2=$?
if [[ "$rc1" != "0" && "$rc2" != "0" ]]; then pass; else fail "rc1=$rc1 rc2=$rc2"; fi

it "出力先そのもの・空の文字列・<dir> 自体がリンクの --baseline-from は、終了コード 1 で止まり何も書かない"
out5="$(new_workdir)/p"
gen "$out5"
age "$out5/$A"
rm -f "$out5/$ORIGIN_REL"
ln -s "$base" "$TEST_TMP_ROOT/base-link"
before="$(sums "$out5")"
upgrade "$out5" --baseline-from "$out5"; rc1=$UP_RC
upgrade "$out5" --baseline-from ""; rc2=$UP_RC
upgrade "$out5" --baseline-from "$TEST_TMP_ROOT/base-link"; rc3=$UP_RC
if [[ "$rc1" == "1" && "$rc2" == "1" && "$rc3" == "1" && "$before" == "$(sums "$out5")" ]]; then pass; else fail "rc=$rc1,$rc2,$rc3"; fi

it "--baseline-from は ORIGIN に記録しない"
if ! command grep -F -- 'baseline' "$out/$ORIGIN_REL" >/dev/null; then pass; else fail "ORIGIN に baseline がある"; fi

README="$PKG_DIR/README.md"
it "README の ORIGIN が無い出力先の項目に、keep (no record)・--baseline-from・手作業の手順がある"
sec="$(awk '/^- \*\*記録に入力が無い古い ORIGIN/ { f = 1 } /^- 追従先は/ { f = 0 } f { print }' "$README")"
if [[ "$sec" == *"keep (no record)"* && "$sec" == *"--baseline-from"* && "$sec" == *"手作業"* ]]; then pass; else fail "README の項目が足りない"; fi

exit_with_result
