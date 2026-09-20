#!/usr/bin/env bash
# test-doctor-origin.sh — doctor.sh による生成物の由来（.devcontainer/ORIGIN）の
# 乖離診断を検証する（#321）。記録側の生成責務は test-origin-record.sh が担う。
#
# 検査が成立しないことを合格にしないことを重点的に確かめる:
#   - 記録が無い生成先は「診断できない」と報告し、黙って合格にしない
#   - 記録が壊れている生成先も同様
#   - 生成物が変化していれば該当ファイル名を添えて報告する
#   - 変化していない生成物は「変化した」と報告しない（対照群）
#   - 記録の版が doctor.sh 自身の版より古ければ「上流が更新されている」と報告する
#   - 版が一致すれば報告しない（対照群）

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-doctor-origin"

DOCTOR="$PKG_DIR/doctor.sh"
ORIGIN_REL="/.devcontainer/ORIGIN"

# 生成先を 1 つ用意して使い回す（各 it が個別に汚す）。
base_out() {
  local out
  out="$(new_workdir)/p"
  run_bootstrap "$out" >/dev/null 2>&1
  printf '%s' "$out"
}

# ── 記録が無い ────────────────────────────────────────────────────────────────

it "記録が無い生成先は WARN で「診断できない」と報告し、黙って合格にしない"
out="$(base_out)"
rm -f "$out$ORIGIN_REL"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
code=$?
if [[ $code -eq 0 ]] && printf '%s' "$output" | grep -q 'origin record missing' \
   && printf '%s' "$output" | grep -q 'WARN=[1-9]'; then
  pass
else
  fail "記録欠落が報告されない、または WARN が 0 件:
$output"
fi

it "記録が無いことは「変化なし」と誤認されない（unchanged と言わない）"
if printf '%s' "$output" | grep -q 'unchanged since generation'; then
  fail "記録が無いのに unchanged と報告した"
else
  pass
fi

# ── 記録が壊れている ──────────────────────────────────────────────────────────

it "version= 行が無い記録は FAIL で報告し、黙って合格にしない"
out="$(base_out)"
printf 'this is not a valid origin record\n' > "$out$ORIGIN_REL"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep -q 'origin record malformed'; then
  pass
else
  fail "壊れた記録が合格してしまった（exit=$code）:
$output"
fi

it "空の記録も同様に FAIL で報告する"
out="$(base_out)"
: > "$out$ORIGIN_REL"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep -q 'origin record malformed'; then
  pass
else
  fail "空の記録が合格してしまった（exit=$code）:
$output"
fi

# ── 生成物の変化 ──────────────────────────────────────────────────────────────

it "生成物を1文字変えると FAIL で該当ファイル名を報告する"
out="$(base_out)"
printf 'X' >> "$out/scripts/on-attach.sh"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep -q 'changed since generation.*scripts/on-attach\.sh'; then
  pass
else
  fail "1 文字の変化を検出できない:
$output"
fi

it "変化していない生成物は「変化した」と報告しない（対照群）"
out="$(base_out)"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
code=$?
# "unchanged since generation" が部分一致してしまわないよう [FAIL] の接頭辞まで含めて照合する。
if [[ $code -eq 0 ]] && ! printf '%s' "$output" | grep -q '\[FAIL\] changed since generation'; then
  pass
else
  fail "変えていないのに変化したと報告した、または exit が非 0（exit=$code）:
$output"
fi

it "変化していない構成では unchanged と件数付きで報告する"
if printf '%s' "$output" | grep -qE 'unchanged since generation \([0-9]+ file\(s\)\)'; then
  pass
else
  fail "unchanged の報告が無い:
$output"
fi

it "記録された生成物が消えていれば FAIL で報告する"
out="$(base_out)"
rm -f "$out/scripts/on-attach.sh"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep -q 'recorded in origin but missing.*scripts/on-attach\.sh'; then
  pass
else
  fail "記録された生成物の消失を検出できない:
$output"
fi

# ── 上流の版 ──────────────────────────────────────────────────────────────────

it "記録の版が doctor.sh 自身より古ければ WARN で「上流が更新されている」と報告する"
out="$(base_out)"
self_version="$(dcb_version_of "$DOCTOR")"
tmp_origin="$(mktemp "$TEST_TMP_ROOT/origin.XXXXXX")"
{
  echo "version=v0.0.1"
  grep -v '^version=' "$out$ORIGIN_REL"
} > "$tmp_origin"
mv "$tmp_origin" "$out$ORIGIN_REL"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
if printf '%s' "$output" | grep -q '\[WARN\] origin version is older than doctor.sh: recorded=v0.0.1'; then
  pass
else
  fail "版の古さを検出できない（doctor.sh 自身の版: $self_version):
$output"
fi

it "バージョン比較は数値比較である（v0.9.1 は v0.11.0 より古いと判定する）"
out="$(base_out)"
tmp_origin="$(mktemp "$TEST_TMP_ROOT/origin.XXXXXX")"
{
  echo "version=v0.9.1"
  grep -v '^version=' "$out$ORIGIN_REL"
} > "$tmp_origin"
mv "$tmp_origin" "$out$ORIGIN_REL"
# doctor.sh 自身の版が v0.9.1 以下だとこの検査は成立しない（現状 v0.11.0 を想定）。
self_version="$(dcb_version_of "$DOCTOR")"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
if printf '%s' "$output" | grep -q '\[WARN\] origin version is older than doctor.sh: recorded=v0.9.1'; then
  pass
else
  fail "文字列比較で誤判定している可能性がある（doctor.sh 自身の版: $self_version）:
$output"
fi

it "版が一致すれば「上流が更新されている」と報告しない（対照群）"
out="$(base_out)"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
if printf '%s' "$output" | grep -q 'origin version is older than doctor.sh'; then
  fail "版が一致するのに古いと報告した:
$output"
else
  pass
fi

it "版が一致すれば OK で明示的に報告する（黙って何も言わない、ではない）"
if printf '%s' "$output" | grep -q '\[OK\] origin version matches or is newer than doctor.sh'; then
  pass
else
  fail "版一致の OK 報告が無い:
$output"
fi

# ── strict モードとの関係 ─────────────────────────────────────────────────────

it "記録欠落（WARN）は --strict で非 0 終了になる"
out="$(base_out)"
rm -f "$out$ORIGIN_REL"
bash "$DOCTOR" --target-dir "$out" --strict >/dev/null 2>&1
code=$?
assert_eq "$code" "2" "strict 終了コード"

exit_with_result
