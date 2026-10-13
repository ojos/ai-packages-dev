#!/usr/bin/env bash
# test-owned-pending.sh — ORIGIN の owned: / pending: 行と、それに関わる --upgrade の振り分け・
# doctor.sh の診断を検証する（#534。表示の改名 #533 を含む）。
#
# 確かめること:
#   - owned: のファイルは、accept せずに編集しても doctor.sh --strict が 0 で終わる
#   - owned: でないファイルは、accept せずに編集すると FAIL のまま
#   - 雛形が変わっていない版への --upgrade では、編集したファイルに .dcb-new を置かない
#     （dry-run でも pending の無いファイルに keep で始まる行が出ない）
#   - 雛形が変わった版への --upgrade では .dcb-new と pending: を置き、owned: でも doctor は FAIL
#   - 取り込む前に .dcb-new を失っても、同じ版の --upgrade で作り直される
#   - --accept で pending: が外れ、doctor が通る
#   - owned: / pending: の無い既存の ORIGIN へ --upgrade すると owned: が書き足される
#   - 既に .dcb-new が残っているファイルには、--upgrade が pending: を書き足す
#   - 生成対象から外れたパスの owned: / pending: は残らない
#   - 旧い表示（keep で始まる template unchanged の行）が出ない

set -uo pipefail

if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-owned-pending-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-owned-pending"

IMG="mcr.microsoft.com/devcontainers/base:noble"
DOCTOR="$PKG_DIR/doctor.sh"
ORIGIN_REL=".devcontainer/ORIGIN"
OWNED="scripts/acceptance.sh"
REMOTE="scripts/acceptance-remote.sh"
OTHER="scripts/verify.sh"

gen() { # out [args...]
  local out="$1"; shift
  bash "$BOOTSTRAP" --project-name own --languages node --base-image "$IMG" --output-dir "$out" --playbook-from "$PLAYBOOK_SRC" "$@" >/dev/null 2>&1
}
upgrade() { # out [args...] — 出力は UP_OUT、終了コードは UP_RC
  local out="$1"; shift
  UP_OUT="$(bash "$BOOTSTRAP" --upgrade --output-dir "$out" --playbook-from "$PLAYBOOK_SRC" "$@" 2>&1)"
  UP_RC=$?
}
accept() { # out [args...] — 終了コードは AC_RC
  local out="$1"; shift
  AC_OUT="$(bash "$BOOTSTRAP" --accept "$@" --output-dir "$out" 2>&1)"
  AC_RC=$?
}
doctor_strict() { # out — 終了コードを返す
  bash "$DOCTOR" --strict --target-dir "$1" >"$TEST_TMP_ROOT/doctor.out" 2>&1
}
edit() { # out rel
  printf '\n# edited by the project\n' >> "$1/$2"
}
change_template_hash() { # out rel
  local f="$1/$ORIGIN_REL"
  sed "s|^hash:$2=.*|hash:$2=$(printf '%064d' 0)|" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
has_line() { # out prefix-with-path（例: owned:scripts/x.sh=）
  grep -F -- "$2" "$1/$ORIGIN_REL" >/dev/null
}

# ── 生成時に owned: を記録する ────────────────────────────────────────────────

out="$(new_workdir)/p"
gen "$out"

it "生成時に、プロジェクト所有のファイルへ owned: を記録し、そうでないファイルには記録しない"
if has_line "$out" "owned:$OWNED=" && ! has_line "$out" "owned:$OTHER=" && ! has_line "$out" "owned:$REMOTE="; then pass; else fail "$(grep -E '^(owned|pending):' "$out/$ORIGIN_REL")"; fi

it "owned: のファイルを accept せずに編集しても doctor.sh --strict が 0 で終わる"
edit "$out" "$OWNED"
doctor_strict "$out"; rc=$?
if [[ "$rc" == "0" ]]; then pass; else fail "rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

it "owned: でないファイルを accept せずに編集すると doctor.sh は FAIL のまま"
edit "$out" "$OTHER"
doctor_strict "$out"; rc=$?
if [[ "$rc" != "0" ]] && grep "changed since generation: $OTHER" "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc"; fi

# ── 雛形が変わっていない版への --upgrade ─────────────────────────────────────

it "雛形が変わっていない版への --upgrade で、編集した owned: / それ以外のどちらにも .dcb-new を置かない"
upgrade "$out"
if [[ "$UP_RC" == "0" && ! -e "$out/$OWNED.dcb-new" && ! -e "$out/$OTHER.dcb-new" \
  && "$UP_OUT" == *"owned (template unchanged): $out/$OWNED"* \
  && "$UP_OUT" == *"modified (template unchanged): $out/$OTHER"* ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "その --upgrade は owned: を引き継ぎ、pending: を書かない"
if has_line "$out" "owned:$OWNED=" && ! grep '^pending:' "$out/$ORIGIN_REL" >/dev/null; then pass; else fail "$(grep -E '^(owned|pending):' "$out/$ORIGIN_REL")"; fi

it "--upgrade --dry-run は pending の無いファイルについて keep で始まる行を出さない"
upgrade "$out" --dry-run
if [[ "$UP_RC" == "0" ]] && ! printf '%s\n' "$UP_OUT" | grep -E '^(plan: )?keep' >/dev/null \
  && [[ "$UP_OUT" == *"plan: owned (template unchanged) $out/$OWNED"* ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "旧い表示（keep で始まる template unchanged の行）は出ない"
old_label="keep (modified, template"" unchanged)"
if [[ "$UP_OUT" != *"$old_label"* ]]; then pass; else fail "$UP_OUT"; fi

# ── 雛形が変わった版への --upgrade ───────────────────────────────────────────

out="$(new_workdir)/p"
gen "$out"
edit "$out" "$OWNED"
change_template_hash "$out" "$OWNED"
upgrade "$out"

it "雛形が変わった版への --upgrade で .dcb-new と pending: が置かれる（owned: は残る）"
if [[ "$UP_RC" == "2" && -f "$out/$OWNED.dcb-new" ]] && has_line "$out" "pending:$OWNED=" && has_line "$out" "owned:$OWNED="; then pass; else fail "rc=$UP_RC"; fi

it "pending: がある owned: のファイルは doctor.sh --strict が FAIL"
doctor_strict "$out"; rc=$?
if [[ "$rc" != "0" ]] && grep "changed since generation: $OWNED" "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

it ".dcb-new を取り込まずに消しても、同じ版の --upgrade で作り直される"
rm -f "$out/$OWNED.dcb-new"
upgrade "$out"
if [[ "$UP_RC" == "2" && -f "$out/$OWNED.dcb-new" ]] && has_line "$out" "pending:$OWNED="; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it ".dcb-new が残っているあいだは --accept が止まる（従来どおり）"
accept "$out" "$OWNED"
if [[ "$AC_RC" != "0" ]] && has_line "$out" "pending:$OWNED="; then pass; else fail "rc=$AC_RC"; fi

it ".dcb-new を片付けて --accept すると pending: が外れ、doctor.sh --strict が 0 で終わる"
rm -f "$out/$OWNED.dcb-new"
accept "$out" "$OWNED"
doctor_strict "$out"; rc=$?
if [[ "$AC_RC" == "0" ]] && ! has_line "$out" "pending:$OWNED=" && [[ "$rc" == "0" ]]; then pass; else fail "accept rc=$AC_RC doctor rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

it "さらに雛形が変わらない版へ --upgrade しても、.dcb-new を置かず pending: も付かない"
upgrade "$out"
if [[ "$UP_RC" == "0" && ! -e "$out/$OWNED.dcb-new" ]] && ! grep '^pending:' "$out/$ORIGIN_REL" >/dev/null; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

# ── pending: のファイルを現物 = 新しい版にすると pending: が外れる ──────────────

out="$(new_workdir)/p"
gen "$out"
ref="$(new_workdir)/ref"
gen "$ref"
edit "$out" "$OWNED"
change_template_hash "$out" "$OWNED"
upgrade "$out"
cp "$ref/$OWNED" "$out/$OWNED"
rm -f "$out/$OWNED.dcb-new"
upgrade "$out"

it "現物が新しい版と一致（up-to-date）になると pending: が外れる"
if [[ "$UP_RC" == "0" ]] && ! grep '^pending:' "$out/$ORIGIN_REL" >/dev/null; then pass; else fail "rc=$UP_RC"; fi

# ── 既存の ORIGIN（owned: / pending: が無い） ────────────────────────────────

out="$(new_workdir)/p"
gen "$out"
grep -v -E '^(owned|pending):' "$out/$ORIGIN_REL" > "$out/$ORIGIN_REL.tmp" && mv "$out/$ORIGIN_REL.tmp" "$out/$ORIGIN_REL"
edit "$out" "$OWNED"
printf 'left\n' > "$out/$OTHER.dcb-new"
edit "$out" "$OTHER"

it "owned: / pending: の無い既存の ORIGIN でも doctor.sh を読める（owned: が無ければ FAIL のまま）"
doctor_strict "$out"; rc=$?
if [[ "$rc" != "0" ]] && ! grep 'malformed' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc"; fi

upgrade "$out"

it "既存の ORIGIN への --upgrade で owned: が書き足される"
if has_line "$out" "owned:$OWNED="; then pass; else fail "$(grep -E '^(owned|pending):' "$out/$ORIGIN_REL")"; fi

it "既に .dcb-new が残っているファイルには、--upgrade が pending: を書き足す"
if has_line "$out" "pending:$OTHER=" && [[ "$UP_RC" == "2" ]]; then pass; else fail "rc=$UP_RC"; fi

# ── 生成対象から外れたパス ───────────────────────────────────────────────────

out="$(new_workdir)/p"
gen "$out" --with-aws
edit "$out" "$REMOTE"
change_template_hash "$out" "$REMOTE"
upgrade "$out" --with-aws

it "対照群: --with-aws のあいだは $REMOTE に owned: と pending: が付く"
if has_line "$out" "owned:$REMOTE=" && has_line "$out" "pending:$REMOTE="; then pass; else fail "$(grep -E '^(owned|pending):' "$out/$ORIGIN_REL")"; fi

upgrade "$out" --without-aws

it "--upgrade --without-aws で生成対象から外れたパスの owned: / pending: は残らない"
if ! grep -F -- "$REMOTE" "$out/$ORIGIN_REL" >/dev/null && has_line "$out" "owned:$OWNED="; then pass; else fail "$(grep -F -- "$REMOTE" "$out/$ORIGIN_REL")"; fi

# ── 現物が hash: と一致するのに pending: が残っている ─────────────────────────

out="$(new_workdir)/p"
gen "$out"
edit "$out" "$OWNED"
change_template_hash "$out" "$OWNED"
upgrade "$out"
cp "$out/$OWNED.dcb-new" "$out/$OWNED"
rm -f "$out/$OWNED.dcb-new"

it "現物 = 新しい版で pending: が残ると doctor.sh は WARN を出し、対象のパスと件数を示す"
bash "$DOCTOR" --target-dir "$out" >"$TEST_TMP_ROOT/doctor.out" 2>&1; rc=$?
if grep -F "[WARN]" "$TEST_TMP_ROOT/doctor.out" | grep -F "$OWNED" | grep -F "1 file(s)" >/dev/null; then pass; else fail "rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

it "その WARN は --strict なしでは 0、--strict では 0 以外"
bash "$DOCTOR" --target-dir "$out" >/dev/null 2>&1; rc1=$?
doctor_strict "$out"; rc2=$?
if [[ "$rc1" == "0" && "$rc2" != "0" ]]; then pass; else fail "rc1=$rc1 rc2=$rc2"; fi

it "--accept で pending: が外れ、WARN が消えて --strict が 0 で終わる"
accept "$out" "$OWNED"
doctor_strict "$out"; rc=$?
if [[ "$AC_RC" == "0" ]] && ! has_line "$out" "pending:$OWNED=" && [[ "$rc" == "0" ]] && ! grep -F "[WARN]" "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "accept rc=$AC_RC doctor rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

# ── doctor.sh の書式検査 ─────────────────────────────────────────────────────

out="$(new_workdir)/p"
gen "$out"

it "doctor.sh は owned: / pending: の行を認識できない行として扱わない"
printf 'pending:%s=1\n' "$OTHER" >> "$out/$ORIGIN_REL"
doctor_strict "$out"; rc=$?
if ! grep 'malformed' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

exit_with_result
