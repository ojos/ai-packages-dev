#!/usr/bin/env bash
# test-hygiene-wiring.sh — 配布した衛生検査 4 本の配線（#540）を検証する。
#
# 確かめること:
#   - 4 本の一覧が、bootstrap.sh（hygiene_check_rel_paths）・doctor.sh（HYGIENE_CHECKS）・
#     README・生成した acceptance.sh の雛形の間で一致する（片方だけ変えると落ちる）
#   - 新規生成した出力先で、acceptance.sh が 4 本を呼び、verify.sh が通る
#   - マニフェストの無い構成では、4 本が通っても acceptance.sh は「未定義」で失敗する
#   - 4 本を呼ばない acceptance.sh では doctor.sh が WARN を出し、--strict で非 0
#   - 呼んでいる／ファイル名をコメントで書いている出力先では WARN が出ない
#   - acceptance.sh が無いときは判定しない
#   - --upgrade の出力に、未配線のときだけ配線の案内が出る（終了コードは変えない）
#   - 手を入れていない旧い版の acceptance.sh は、--upgrade で 4 本を呼ぶ版になる

set -uo pipefail

if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-hygiene-wiring-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "${TEST_TMP_ROOT:?}"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-hygiene-wiring"

IMG="mcr.microsoft.com/devcontainers/base:noble"
DOCTOR="$PKG_DIR/doctor.sh"
README="$PKG_DIR/README.md"
ORIGIN_REL=".devcontainer/ORIGIN"
ACC="scripts/acceptance.sh"
NAMES="check-control-chars.sh check-table-breaks.sh check-doc-links.sh check-shell-portability.sh"

# 偽の go（引数を問わず成功する）。PATH の先頭に置く。
STUB="$(new_workdir)/stub"
mkdir -p "$STUB"
printf '#!/bin/sh\nexit 0\n' > "$STUB/go"
chmod +x "$STUB/go"

gen() { # out [args...]
  local out="$1"; shift
  bash "$BOOTSTRAP" --project-name hyg --languages go --base-image "$IMG" --output-dir "$out" --playbook-from "$PLAYBOOK_SRC" "$@" >/dev/null 2>&1
}
upgrade() { # out — 出力は UP_OUT、終了コードは UP_RC
  UP_OUT="$(bash "$BOOTSTRAP" --upgrade --output-dir "$1" --playbook-from "$PLAYBOOK_SRC" 2>&1)"
  UP_RC=$?
}
doctor_run() { # out [args...] — 出力は DOC_OUT、終了コードは DOC_RC
  local out="$1"; shift
  # go は偽のものを見せる（実行環境に無くても、ランタイム不在の WARN で --strict の判定が濁らないように）
  DOC_OUT="$(PATH="$STUB:$PATH" bash "$DOCTOR" --target-dir "$out" "$@" 2>&1)"
  DOC_RC=$?
}
# 4 本を呼ばない acceptance.sh に差し替える（ファイル名を一切含めない）
write_unwired() { # out
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho unrelated\n' > "$1/$ACC"
  chmod +x "$1/$ACC"
}
sorted_names() { tr ' ' '\n' | sed '/^$/d' | sort; }
# 衛生検査の節（コメントから最後の呼び出しまで）を取り除き、旧い版の acceptance.sh を作る
strip_hygiene() { # file
  python3 -I - "$1" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s = re.sub(r'# 衛生検査.*?bash scripts/check-shell-portability\.sh\n\n', '', s, flags=re.S)
open(p, "w", encoding="utf-8").write(s)
PY
}

# ── 一覧の機械照合 ────────────────────────────────────────────────────────────

BOOT_LIST="$(awk '/^hygiene_check_rel_paths\(\) \{/ { f = 1; next } f && /^\}/ { exit } f { print }' "$BOOTSTRAP" \
  | command grep -o 'scripts/check-[a-z-]*\.sh' | sed 's|^scripts/||' | sorted_names)"
EXPECTED="$(printf '%s' "$NAMES" | sorted_names)"

it "bootstrap.sh の hygiene_check_rel_paths が 4 本を持つ"
if [[ "$BOOT_LIST" == "$EXPECTED" ]]; then pass; else fail "$BOOT_LIST"; fi

it "doctor.sh の HYGIENE_CHECKS が bootstrap.sh の一覧と一致する"
DOC_LIST="$(sed -n 's/^HYGIENE_CHECKS="\(.*\)"$/\1/p' "$DOCTOR" | sorted_names)"
if [[ "$DOC_LIST" == "$BOOT_LIST" ]]; then pass; else fail "doctor: $DOC_LIST"; fi

it "README の Doctor 節の「衛生検査の配線」の行が、4 本すべてを載せている"
ROW="$(command grep '^| 衛生検査の配線 |' "$README" || true)"
missing=""
for n in $BOOT_LIST; do
  case "$ROW" in *"\`$n\`"*) ;; *) missing="$missing $n" ;; esac
done
if [[ -n "$ROW" && -z "$missing" ]]; then pass; else fail "row=${ROW:+有} 欠落:$missing"; fi

it "4 本がすべて無条件のテンプレート（template_rel_paths）に含まれる"
TPL_BLOCK="$(awk '/^template_rel_paths\(\) \{/ { f = 1; next } f && /^\}/ { exit } f { print }' "$BOOTSTRAP")"
missing=""
for n in $BOOT_LIST; do
  case "$TPL_BLOCK" in *"'scripts/$n'"*) ;; *) missing="$missing $n" ;; esac
done
if [[ -z "$missing" ]]; then pass; else fail "template_rel_paths に無い:$missing"; fi

out="$(new_workdir)/p"
gen "$out"

it "生成した acceptance.sh の雛形が、4 本をそれぞれ呼ぶ（呼び出しの一覧が bootstrap.sh と一致する）"
CALLED="$(sed -n 's|^bash scripts/\(check-[a-z-]*\.sh\)$|\1|p' "$out/$ACC" | sorted_names)"
if [[ "$CALLED" == "$BOOT_LIST" ]]; then pass; else fail "呼び出し: $CALLED"; fi

it "4 本の呼び出しは、検証を 1 つでも実行したか（ran_any=1）に数えない"
# 衛生検査の節（コメントから ran_any の判定の手前まで）に ran_any=1 が無いこと
head_part="$(awk '/^# 衛生検査/ { f = 1 } f && /^if \[\[ "\$ran_any" -eq 0/ { exit } f { print }' "$out/$ACC")"
if [[ "$head_part" == *"bash scripts/check-doc-links.sh"* && "$head_part" != *"ran_any=1"* ]]; then pass; else fail "$head_part"; fi

# ── 新規生成した出力先での実行 ────────────────────────────────────────────────

(cd "$out" && git init -q && git add -A) >/dev/null 2>&1

it "マニフェストの無い構成では、4 本が通っても acceptance.sh は「未定義」で失敗する"
acc_out="$(cd "$out" && PATH="$STUB:$PATH" bash "$ACC" 2>&1)"; rc=$?
if [[ "$rc" != "0" && "$acc_out" == *"受け入れ条件が未定義"* && "$acc_out" == *"(hygiene) check-shell-portability"* ]]; then pass; else fail "rc=$rc $acc_out"; fi

it "新規生成した直後の出力先（マニフェストあり）で、acceptance.sh が 4 本を呼び、verify.sh が通る"
printf 'module example.test/hyg\n\ngo 1.22\n' > "$out/go.mod"
(cd "$out" && git add -A) >/dev/null 2>&1
ver_out="$(cd "$out" && PATH="$STUB:$PATH" bash scripts/verify.sh 2>&1)"; rc=$?
all_ran=1
for n in $BOOT_LIST; do
  case "$ver_out" in *"(hygiene) ${n%.sh}"*) ;; *) all_ran=0 ;; esac
done
if [[ "$rc" == "0" && "$ver_out" == *"VERIFY_PASS"* && "$all_ran" == "1" ]]; then pass; else fail "rc=$rc all_ran=$all_ran $ver_out"; fi

# ── doctor.sh の判定 ─────────────────────────────────────────────────────────

it "呼んでいる出力先では、配線の WARN が出ず、--strict が 0 で終わる"
doctor_run "$out" --strict
if [[ "$DOC_RC" == "0" && "$DOC_OUT" != *"not wired"* && "$DOC_OUT" == *"hygiene checks are referenced"* ]]; then pass; else fail "rc=$DOC_RC $DOC_OUT"; fi

out2="$(new_workdir)/p"
gen "$out2"
write_unwired "$out2"

it "4 本を呼ばない acceptance.sh の出力先で、doctor.sh が WARN を出し、--strict で非 0 になる"
doctor_run "$out2" --strict
if [[ "$DOC_RC" == "2" && "$DOC_OUT" == *"[WARN] hygiene checks not wired into scripts/acceptance.sh (4 of 4)"* && "$DOC_OUT" == *"bash scripts/check-doc-links.sh"* ]]; then pass; else fail "rc=$DOC_RC $DOC_OUT"; fi

it "WARN だけの場合、--strict でなければ終了コードは 0（FAIL にしない）"
doctor_run "$out2"
if [[ "$DOC_RC" == "0" && "$DOC_OUT" == *"not wired"* ]]; then pass; else fail "rc=$DOC_RC"; fi

it "ファイル名をコメントで書いているだけ（呼ばない）の acceptance.sh では、WARN が出ない"
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  for n in $BOOT_LIST; do printf '# %s: 理由があって呼ばない\n' "$n"; done
  printf 'echo unrelated\n'
} > "$out2/$ACC"
doctor_run "$out2" --strict
if [[ "$DOC_RC" == "0" && "$DOC_OUT" != *"not wired"* ]]; then pass; else fail "rc=$DOC_RC $DOC_OUT"; fi

it "1 本だけ未配線のときは、その 1 本だけを件数つきで報告する"
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  for n in $BOOT_LIST; do [[ "$n" == "check-table-breaks.sh" ]] || printf 'bash scripts/%s\n' "$n"; done
} > "$out2/$ACC"
doctor_run "$out2" --strict
if [[ "$DOC_RC" == "2" && "$DOC_OUT" == *"(1 of 4): check-table-breaks.sh"* ]]; then pass; else fail "rc=$DOC_RC $DOC_OUT"; fi

it "検査のファイルが生成先に無ければ、その検査は数えない"
rm -f "${out2:?}/scripts/check-table-breaks.sh"
doctor_run "$out2" --strict
if [[ "$DOC_OUT" != *"not wired"* && "$DOC_OUT" == *"referenced from scripts/acceptance.sh (3 file(s))"* ]]; then pass; else fail "rc=$DOC_RC $DOC_OUT"; fi

it "acceptance.sh が無いときは判定しない（配線の OK も WARN も出さない）"
rm -f "${out2:?}/scripts/acceptance.sh"
doctor_run "$out2"
if [[ "$DOC_OUT" != *"not wired"* && "$DOC_OUT" != *"referenced from scripts/acceptance.sh"* ]]; then pass; else fail "$DOC_OUT"; fi

# ── --upgrade の案内 ─────────────────────────────────────────────────────────

out3="$(new_workdir)/p"
gen "$out3"
write_unwired "$out3"
upgrade "$out3"

it "未配線の出力先への --upgrade の出力に、配線の案内が出る（終了コードは変わらない）"
if [[ "$UP_RC" == "0" && "$UP_OUT" == *"呼ばれていません"* && "$UP_OUT" == *"bash scripts/check-control-chars.sh"* ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "呼んでいる出力先への --upgrade では、案内が出ない"
out4="$(new_workdir)/p"
gen "$out4"
upgrade "$out4"
if [[ "$UP_RC" == "0" && "$UP_OUT" != *"呼ばれていません"* ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "コメントでファイル名と理由を書いた出力先への --upgrade では、案内が出ない"
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  for n in $BOOT_LIST; do printf '# %s: 理由があって呼ばない\n' "$n"; done
} > "$out3/$ACC"
upgrade "$out3"
if [[ "$UP_RC" == "0" && "$UP_OUT" != *"呼ばれていません"* ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

# ── 旧い版の acceptance.sh ───────────────────────────────────────────────────

it "手を入れていない旧い版の acceptance.sh は、--upgrade で 4 本を呼ぶ版になる"
out5="$(new_workdir)/p"
gen "$out5"
# 衛生検査の節を取り除いた旧い版を作り、ORIGIN の記録をその版の hash に合わせる
# （＝旧い雛形のまま手を入れていないファイル）
strip_hygiene "$out5/$ACC"
old_hash="$(dcb_file_sha256_for_test "$out5/$ACC")"
sed "s|^hash:$ACC=.*|hash:$ACC=$old_hash|" "$out5/$ORIGIN_REL" > "$out5/$ORIGIN_REL.tmp" && mv "$out5/$ORIGIN_REL.tmp" "$out5/$ORIGIN_REL"
old_calls="$(command grep -c 'check-control-chars' "$out5/$ACC" || true)"
upgrade "$out5"
new_calls="$(command grep -c '^bash scripts/check-' "$out5/$ACC" || true)"
if [[ "$old_calls" == "0" && "$UP_RC" == "0" && "$new_calls" == "4" && ! -e "$out5/$ACC.dcb-new" ]]; then pass; else fail "old=$old_calls new=$new_calls rc=$UP_RC $UP_OUT"; fi

it "その --upgrade のあと、doctor.sh --strict が 0 で終わる"
doctor_run "$out5" --strict
if [[ "$DOC_RC" == "0" ]]; then pass; else fail "rc=$DOC_RC $DOC_OUT"; fi

it "手を入れた旧い版の acceptance.sh には .dcb-new が置かれ、doctor.sh は FAIL になる"
out6="$(new_workdir)/p"
gen "$out6"
strip_hygiene "$out6/$ACC"
printf '\n# edited by the project\n' >> "$out6/$ACC"
sed "s|^hash:$ACC=.*|hash:$ACC=$(printf '%064d' 0)|" "$out6/$ORIGIN_REL" > "$out6/$ORIGIN_REL.tmp" && mv "$out6/$ORIGIN_REL.tmp" "$out6/$ORIGIN_REL"
upgrade "$out6"
doctor_run "$out6" --strict
if [[ "$UP_RC" == "2" && -f "$out6/$ACC.dcb-new" && "$DOC_RC" == "1" ]]; then pass; else fail "up=$UP_RC doctor=$DOC_RC"; fi

exit_with_result
