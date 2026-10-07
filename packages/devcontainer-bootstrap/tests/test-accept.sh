#!/usr/bin/env bash
# test-accept.sh — 取り込み済みの記録（bootstrap.sh --accept）と、それに関わる
# --upgrade の振り分け・doctor.sh の診断を検証する（#461）。
#
# 確かめること:
#   - 手を入れて --accept したあと、doctor.sh --strict が 0 で終わる
#   - accept したあとでさらに手を入れると FAIL に戻る
#   - 雛形が変わっていない版への --upgrade では、取り込み済みにしたファイルに .dcb-new を置かない
#     （accept していないファイル・取り込む前に失った .dcb-new には、従来どおり置く）
#   - 雛形が変わった版への --upgrade では .dcb-new を置き、accepted を外す（doctor は FAIL）
#   - 受け付けない入力は 0 以外で止まり、ORIGIN を変えない
#   - --accept --dry-run は ORIGIN を変えない

set -uo pipefail

if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-accept-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-accept"

IMG="mcr.microsoft.com/devcontainers/base:noble"
DOCTOR="$PKG_DIR/doctor.sh"
ORIGIN_REL=".devcontainer/ORIGIN"
TARGET="scripts/verify.sh"
OTHER="scripts/on-attach.sh"

gen() { # out [args...]
  local out="$1"; shift
  bash "$BOOTSTRAP" --project-name acc --languages node --base-image "$IMG" --output-dir "$out" --playbook-from "$PLAYBOOK_SRC" "$@" >/dev/null 2>&1
}
upgrade() { # out [args...] — 出力は UP_OUT、終了コードは UP_RC
  local out="$1"; shift
  UP_OUT="$(bash "$BOOTSTRAP" --upgrade --output-dir "$out" --playbook-from "$PLAYBOOK_SRC" "$@" 2>&1)"
  UP_RC=$?
}
accept() { # out [args...] — 出力は AC_OUT、終了コードは AC_RC
  local out="$1"; shift
  AC_OUT="$(bash "$BOOTSTRAP" --accept "$@" --output-dir "$out" 2>&1)"
  AC_RC=$?
}
doctor_strict() { # out — 終了コードを返す
  bash "$DOCTOR" --strict --target-dir "$1" >"$TEST_TMP_ROOT/doctor.out" 2>&1
}
edit() { # out rel — 現物へ 1 行足す
  printf '\n# edited by the project\n' >> "$1/$2"
}
# ORIGIN の hash: 行を別の値へ書き換える（雛形が変わった版を作る）。
change_template_hash() { # out rel
  local f="$1/$ORIGIN_REL"
  sed "s|^hash:$2=.*|hash:$2=$(printf '%064d' 0)|" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
accepted_of() { grep "^accepted:$2=" "$1/$ORIGIN_REL" || true; }

# ── 手を入れて --accept → doctor が通る ───────────────────────────────────────

out="$(new_workdir)/p"
gen "$out"

it "対照群: 生成直後は doctor.sh --strict が 0 で終わる"
doctor_strict "$out"; rc=$?
if [[ "$rc" == "0" ]]; then pass; else fail "rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

edit "$out" "$TARGET"

it "手を入れると doctor.sh --strict は FAIL で、--accept の案内を添える"
doctor_strict "$out"; rc=$?
if [[ "$rc" != "0" ]] && grep -- '--accept' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc"; fi

it "--accept --dry-run は ORIGIN を変えず、予定だけを出す"
before="$(cksum < "$out/$ORIGIN_REL")"
accept "$out" "$TARGET" --dry-run
after="$(cksum < "$out/$ORIGIN_REL")"
if [[ "$AC_RC" == "0" && "$before" == "$after" && "$AC_OUT" == *"plan: accept: $TARGET"* ]]; then pass; else fail "rc=$AC_RC $AC_OUT"; fi

it "--accept で ORIGIN へ accepted: を書き、version= と hash: は変えない"
hashes_before="$(grep -v '^accepted:' "$out/$ORIGIN_REL")"
accept "$out" "$TARGET"
hashes_after="$(grep -v '^accepted:' "$out/$ORIGIN_REL")"
want="accepted:$TARGET=$(dcb_file_sha256_for_test "$out/$TARGET")"
if [[ "$AC_RC" == "0" && "$hashes_before" == "$hashes_after" && "$(accepted_of "$out" "$TARGET")" == "$want" ]]; then pass; else fail "rc=$AC_RC $AC_OUT"; fi

it "accept したあとは doctor.sh --strict が 0 で終わる"
doctor_strict "$out"; rc=$?
if [[ "$rc" == "0" ]]; then pass; else fail "rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

it "同じパスを再度 --accept しても accepted: は 1 行のまま（冪等）"
accept "$out" "$TARGET"
n="$(grep -c "^accepted:$TARGET=" "$out/$ORIGIN_REL")"
if [[ "$AC_RC" == "0" && "$n" == "1" ]]; then pass; else fail "rc=$AC_RC 行数=$n"; fi

it "accept したあとでさらに手を入れると doctor.sh --strict が FAIL に戻る"
edit "$out" "$TARGET"
doctor_strict "$out"; rc=$?
if [[ "$rc" != "0" ]]; then pass; else fail "rc=0 のまま"; fi

# ── 雛形が変わっていない版への --upgrade ─────────────────────────────────────

out="$(new_workdir)/p"
gen "$out"
edit "$out" "$TARGET"
accept "$out" "$TARGET"

it "雛形が変わっていない版への --upgrade では、取り込み済みにしたファイルに .dcb-new を置かない"
upgrade "$out"
if [[ "$UP_RC" == "0" && ! -e "$out/$TARGET.dcb-new" && "$UP_OUT" == *"keep (modified, template unchanged): $out/$TARGET"* ]]; then pass; else fail "rc=$UP_RC $UP_OUT"; fi

it "その --upgrade は現物（手を入れた内容）を保ち、accepted: を引き継ぐ"
want="accepted:$TARGET=$(dcb_file_sha256_for_test "$out/$TARGET")"
if grep 'edited by the project' "$out/$TARGET" >/dev/null && [[ "$(accepted_of "$out" "$TARGET")" == "$want" ]]; then pass; else fail "accepted=$(accepted_of "$out" "$TARGET")"; fi

it "その --upgrade のあとも doctor.sh --strict が 0 で終わる"
doctor_strict "$out"; rc=$?
if [[ "$rc" == "0" ]]; then pass; else fail "rc=$rc: $(cat "$TEST_TMP_ROOT/doctor.out")"; fi

it "--upgrade --dry-run も、雛形が変わっていなければ plan: keep だけで .dcb-new を置かない"
upgrade "$out" --dry-run
if [[ "$UP_RC" == "0" && "$UP_OUT" == *"plan: keep (modified, template unchanged) $out/$TARGET"* && ! -e "$out/$TARGET.dcb-new" ]]; then pass; else fail "rc=$UP_RC"; fi

it "残っている古い .dcb-new は、取り込み済みのファイルでも消さない（終了コード 2 で報告）"
printf 'stale\n' > "$out/$TARGET.dcb-new"
upgrade "$out"
if [[ "$UP_RC" == "2" && "$(cat "$out/$TARGET.dcb-new")" == "stale" ]]; then pass; else fail "rc=$UP_RC"; fi
rm -f "$out/$TARGET.dcb-new"

it "accept せず手を入れただけのファイルには、雛形が変わっていなくても .dcb-new を置く"
edit "$out" "$OTHER"
upgrade "$out"
if [[ "$UP_RC" == "2" && -f "$out/$OTHER.dcb-new" ]]; then pass; else fail "rc=$UP_RC"; fi

it "取り込む前に失った .dcb-new は、同じ版の --upgrade をやり直すと作り直される"
rm -f "$out/$OTHER.dcb-new"
upgrade "$out"
if [[ "$UP_RC" == "2" && -f "$out/$OTHER.dcb-new" ]]; then pass; else fail "rc=$UP_RC 出力: $UP_OUT"; fi
rm -f "$out/$OTHER.dcb-new"

# ── 雛形が変わった版への --upgrade ───────────────────────────────────────────

out="$(new_workdir)/p"
gen "$out"
edit "$out" "$TARGET"
edit "$out" "$OTHER"
accept "$out" "$TARGET" "$OTHER"
change_template_hash "$out" "$TARGET"

it "雛形が変わった版への --upgrade では .dcb-new を置き、そのファイルの accepted: を外す"
upgrade "$out"
if [[ "$UP_RC" == "2" && -f "$out/$TARGET.dcb-new" && -z "$(accepted_of "$out" "$TARGET")" ]]; then pass; else fail "rc=$UP_RC accepted=$(accepted_of "$out" "$TARGET")"; fi

it "雛形が変わっていない別のファイルの accepted: は引き継ぐ"
if [[ -n "$(accepted_of "$out" "$OTHER")" && ! -e "$out/$OTHER.dcb-new" ]]; then pass; else fail "accepted=$(accepted_of "$out" "$OTHER")"; fi

it "雛形が変わった版への --upgrade のあと、doctor.sh --strict は FAIL"
doctor_strict "$out"; rc=$?
if [[ "$rc" != "0" ]]; then pass; else fail "rc=0"; fi

# ── 受け付けない入力は、止まって ORIGIN を変えない ────────────────────────────

out="$(new_workdir)/p"
gen "$out"
edit "$out" "$TARGET"
before="$(cksum < "$out/$ORIGIN_REL")"

it "記録の無いパスは 0 以外で止まり、ORIGIN を変えない"
printf 'x\n' > "$out/not-generated.txt"
accept "$out" not-generated.txt
if [[ "$AC_RC" != "0" && "$before" == "$(cksum < "$out/$ORIGIN_REL")" ]]; then pass; else fail "rc=$AC_RC"; fi

it "現物の無いパスは 0 以外で止まり、ORIGIN を変えない"
rm -f "$out/$OTHER"
accept "$out" "$OTHER"
if [[ "$AC_RC" != "0" && "$before" == "$(cksum < "$out/$ORIGIN_REL")" ]]; then pass; else fail "rc=$AC_RC"; fi

it ".dcb-new が残るパスは 0 以外で止まり、ORIGIN を変えない"
printf 'new\n' > "$out/$TARGET.dcb-new"
accept "$out" "$TARGET"
if [[ "$AC_RC" != "0" && "$before" == "$(cksum < "$out/$ORIGIN_REL")" ]]; then pass; else fail "rc=$AC_RC"; fi
rm -f "$out/$TARGET.dcb-new"

it "有効なパスと無効なパスを混ぜると、有効なパスも書かずに止まる"
accept "$out" "$TARGET" not-generated.txt
if [[ "$AC_RC" != "0" && "$before" == "$(cksum < "$out/$ORIGIN_REL")" ]]; then pass; else fail "rc=$AC_RC"; fi

it "ORIGIN の無い出力先は 0 以外で止まる"
empty="$(new_workdir)/empty"; mkdir -p "$empty"
accept "$empty" "$TARGET"
if [[ "$AC_RC" != "0" ]]; then pass; else fail "rc=0"; fi

it "パスを 1 つも渡さないと 0 以外で止まる"
accept "$out"
if [[ "$AC_RC" != "0" && "$before" == "$(cksum < "$out/$ORIGIN_REL")" ]]; then pass; else fail "rc=$AC_RC"; fi

for combo in "--project-name x" "--languages node" "--with-claude" "--without-claude" "--base-image $IMG" "--force" "--upgrade" "--no-gitignore" "--gitignore-targets Foo" "--with-playbook" "--playbook-from $PLAYBOOK_SRC"; do
  it "生成の引数との併用（$combo）は 0 以外で止まり、ORIGIN を変えない"
  # shellcheck disable=SC2086
  AC_OUT="$(bash "$BOOTSTRAP" --accept "$TARGET" --output-dir "$out" $combo 2>&1)"; AC_RC=$?
  if [[ "$AC_RC" != "0" && "$before" == "$(cksum < "$out/$ORIGIN_REL")" ]]; then pass; else fail "rc=$AC_RC"; fi
done

# ── 現物が hash: と一致するなら accepted を外す ──────────────────────────────

out="$(new_workdir)/p"
gen "$out"
cp "$out/$TARGET" "$TEST_TMP_ROOT/target.orig"
edit "$out" "$TARGET"
accept "$out" "$TARGET"
cp "$TEST_TMP_ROOT/target.orig" "$out/$TARGET"

it "現物が hash: と一致するパスの --accept は、accepted: を外して変更なしと報告する"
accept "$out" "$TARGET"
if [[ "$AC_RC" == "0" && -z "$(accepted_of "$out" "$TARGET")" && "$AC_OUT" == *"unchanged: $TARGET"* ]]; then pass; else fail "rc=$AC_RC $AC_OUT"; fi

# ── 後方互換: accepted: 行が無い既存の ORIGIN ────────────────────────────────

out="$(new_workdir)/p"
gen "$out"

it "accepted: 行の無い ORIGIN で doctor.sh が従来どおり通る（後方互換）"
if [[ -z "$(grep '^accepted:' "$out/$ORIGIN_REL" || true)" ]]; then
  doctor_strict "$out"; rc=$?
  if [[ "$rc" == "0" ]]; then pass; else fail "rc=$rc"; fi
else
  fail "生成直後に accepted: がある"
fi

it "doctor.sh は不正な accepted: 行（ハッシュが 64 桁でない）を malformed にする"
printf 'accepted:%s=abc\n' "$TARGET" >> "$out/$ORIGIN_REL"
doctor_strict "$out"; rc=$?
if [[ "$rc" != "0" ]] && grep 'malformed' "$TEST_TMP_ROOT/doctor.out" >/dev/null; then pass; else fail "rc=$rc"; fi

exit_with_result
