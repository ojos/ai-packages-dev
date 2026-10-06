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
if [[ $code -eq 0 ]] && printf '%s' "$output" | grep 'origin record missing' >/dev/null \
   && printf '%s' "$output" | grep 'WARN=[1-9]' >/dev/null; then
  pass
else
  fail "記録欠落が報告されない、または WARN が 0 件:
$output"
fi

it "記録が無いことは「変化なし」と誤認されない（unchanged と言わない）"
if printf '%s' "$output" | grep 'unchanged since generation' >/dev/null; then
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
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep 'origin record malformed' >/dev/null; then
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
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep 'origin record malformed' >/dev/null; then
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
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep 'changed since generation.*scripts/on-attach\.sh' >/dev/null; then
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
if [[ $code -eq 0 ]] && ! printf '%s' "$output" | grep '\[FAIL\] changed since generation' >/dev/null; then
  pass
else
  fail "変えていないのに変化したと報告した、または exit が非 0（exit=$code）:
$output"
fi

it "変化していない構成では unchanged と件数付きで報告する"
if printf '%s' "$output" | grep -E 'unchanged since generation \([0-9]+ file\(s\)\)' >/dev/null; then
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
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep 'recorded in origin but missing.*scripts/on-attach\.sh' >/dev/null; then
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
if printf '%s' "$output" | grep '\[WARN\] origin version is older than doctor.sh: recorded=v0.0.1' >/dev/null; then
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
if printf '%s' "$output" | grep '\[WARN\] origin version is older than doctor.sh: recorded=v0.9.1' >/dev/null; then
  pass
else
  fail "文字列比較で誤判定している可能性がある（doctor.sh 自身の版: $self_version）:
$output"
fi

it "version の値が vX.Y.Z 形式でなければ FAIL で報告する（壊れた記録を合格にしない）"
# 実測: "v0.11.0garbage" のように数字部分の前方一致だけで dcb_version_lt を
# 通すと、末尾のゴミを無視して「版が新しい/一致」側へ倒れ、壊れた記録を
# [OK] にしてしまっていた（PR #324 レビュー指摘）。
out="$(base_out)"
tmp_origin="$(mktemp "$TEST_TMP_ROOT/origin.XXXXXX")"
{
  echo "version=v0.11.0garbage"
  grep -v '^version=' "$out$ORIGIN_REL"
} > "$tmp_origin"
mv "$tmp_origin" "$out$ORIGIN_REL"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep '\[FAIL\] origin record malformed.*v0\.11\.0garbage' >/dev/null; then
  pass
else
  fail "壊れた版文字列を合格にしてしまった（exit=$code）:
$output"
fi

it "版が一致すれば「上流が更新されている」と報告しない（対照群）"
out="$(base_out)"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
if printf '%s' "$output" | grep 'origin version is older than doctor.sh' >/dev/null; then
  fail "版が一致するのに古いと報告した:
$output"
else
  pass
fi

it "版が一致すれば OK で明示的に報告する（黙って何も言わない、ではない）"
if printf '%s' "$output" | grep '\[OK\] origin version matches or is newer than doctor.sh' >/dev/null; then
  pass
else
  fail "版一致の OK 報告が無い:
$output"
fi

# ── 入力の記録（input: 行）と .ai-playbook/** のハッシュ（#396 の 1/3） ──────

it "入力の行がある新しい書式の記録を、そのまま合格として読める"
out="$(base_out)"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -eq 0 ]] && grep -q '^inputs-format=1' "$out$ORIGIN_REL" && ! printf '%s' "$output" | grep 'origin record malformed' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

# 入力の行を 1 行書き換える補助。$1=生成先 $2=置換対象の行頭 $3=新しい行（空なら削除）
mutate_origin() {
  local tmp="$1$ORIGIN_REL.mut"
  awk -v k="$2" -v n="$3" 'index($0, k) == 1 { if (n != "") print n; next } { print }' "$1$ORIGIN_REL" > "$tmp"
  mv "$tmp" "$1$ORIGIN_REL"
}

it "input:project-name が欠けていれば malformed（FAIL）"
out="$(base_out)"
mutate_origin "$out" "input:project-name=" ""
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep '\[FAIL\] origin record malformed.*input:project-name' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it "input:base-image-mode が不正値なら malformed（FAIL）"
out="$(base_out)"
mutate_origin "$out" "input:base-image-mode=" "input:base-image-mode=maybe"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep '\[FAIL\] origin record malformed.*base-image-mode' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it "値の中の不正な % の並びは malformed（FAIL）"
out="$(base_out)"
mutate_origin "$out" "input:gitignore-targets=" "input:gitignore-targets=a%zz"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep '\[FAIL\] origin record malformed.*%' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it "認識できない行（読み飛ばさない）は malformed（FAIL）"
out="$(base_out)"
printf 'garbage line without key\n' >> "$out$ORIGIN_REL"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep '\[FAIL\] origin record malformed.*認識できない行' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it "hash: 行の値が sha256 でなければ malformed（FAIL）"
out="$(base_out)"
printf 'hash:scripts/zzz.sh=notahash\n' >> "$out$ORIGIN_REL"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep '\[FAIL\] origin record malformed.*hash' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it "inputs-format が 1 でなければ入力の検査を省いて WARN にする（未知の書式を FAIL にしない）"
out="$(base_out)"
mutate_origin "$out" "inputs-format=" "inputs-format=2"
mutate_origin "$out" "input:project-name=" ""
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -eq 0 ]] && printf '%s' "$output" | grep '\[WARN\] origin inputs-format is not 1' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it "未知の input: キーは malformed（FAIL）"
out="$(base_out)"
printf 'input:bogus=1\n' >> "$out$ORIGIN_REL"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep '\[FAIL\] origin record malformed.*input:bogus' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it "base-image-mode=auto でも input:base-image が欠けていれば malformed（FAIL）"
out="$(base_out)"
mutate_origin "$out" "input:base-image-mode=" "input:base-image-mode=auto"
mutate_origin "$out" "input:base-image=" ""
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep '\[FAIL\] origin record malformed.*input:base-image が無い' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

for bad_langs in 'node,' ',node' 'node,,go'; do
  it "input:languages に空要素（$bad_langs）があれば malformed（FAIL）"
  out="$(base_out)"
  mutate_origin "$out" "input:languages=" "input:languages=$bad_langs"
  output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
  if [[ $code -ne 0 ]] && printf '%s' "$output" | grep '\[FAIL\] origin record malformed.*input:languages' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi
done

it "パスに = を含む hash: 行も正しく読める（正常な記録は通り、改変は changed になる）"
out="$(base_out)"
mkdir -p "$out/dir=x"
printf 'hello\n' > "$out/dir=x/f.txt"
printf 'hash:dir=x/f.txt=%s\n' "$(dcb_file_sha256_for_test "$out/dir=x/f.txt")" >> "$out$ORIGIN_REL"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -eq 0 ]] && ! printf '%s' "$output" | grep 'malformed' >/dev/null; then pass; else fail "正常な記録が通らない: 終了コード=$code
$output"; fi
printf 'X' >> "$out/dir=x/f.txt"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep -F 'changed since generation:' >/dev/null && printf '%s' "$output" | grep -F 'dir=x/f.txt' >/dev/null; then pass; else fail "改変を changed と言わない: 終了コード=$code
$output"; fi

it "input: の行があるのに inputs-format の行が無ければ malformed（旧形式として検査を省かない）"
out="$(base_out)"
mutate_origin "$out" "inputs-format=" ""
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep '\[FAIL\] origin record malformed.*inputs-format' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it "改行で終わらない最終行も検査する（不正な input: 行が最終行でも malformed）"
out="$(base_out)"
printf 'input:bogus=1' >> "$out$ORIGIN_REL"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep '\[FAIL\] origin record malformed.*input:bogus' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it ".ai-playbook/** の規範ファイルを変えると changed と判定する"
out="$(new_workdir)/p"
run_bootstrap "$out" --playbook-from "$PLAYBOOK_SRC" >/dev/null 2>&1
pb_file="$(cd "$out" && find .ai-playbook -type f -name '*.md' | sort | sed -n 1p)"
printf '\nedited\n' >> "$out/$pb_file"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep -F "changed since generation: $pb_file" >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it ".ai-playbook/VERSION を消すと missing と判定する"
out="$(new_workdir)/p"
run_bootstrap "$out" --playbook-from "$PLAYBOOK_SRC" >/dev/null 2>&1
rm -f "$out/.ai-playbook/VERSION"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep 'recorded in origin but missing.*\.ai-playbook/VERSION' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

# ── strict モードとの関係 ─────────────────────────────────────────────────────

it "記録欠落（WARN）は --strict で非 0 終了になる"
out="$(base_out)"
rm -f "$out$ORIGIN_REL"
bash "$DOCTOR" --target-dir "$out" --strict >/dev/null 2>&1
code=$?
assert_eq "$code" "2" "strict 終了コード"

# ── flags= の必須化・input: の重複・*.dcb-new の報告（#396 の 3/3） ───────────

it "新しい形式（inputs-format=1）で flags= の行が消えていれば malformed（FAIL）"
out="$(base_out)"
mutate_origin "$out" "flags=" ""
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep '\[FAIL\] origin record malformed.*flags=' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it "flags= が空の値でも、行があれば通る（対照群）"
out="$(base_out)"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if grep -q '^flags=$' "$out$ORIGIN_REL" && [[ $code -eq 0 ]] && ! printf '%s' "$output" | grep 'origin record malformed' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it "古い形式（inputs-format 無し）では flags= が無くても通る（後方互換）"
out="$(base_out)"
mutate_origin "$out" "flags=" ""
grep -v '^inputs-format=\|^input:' "$out$ORIGIN_REL" > "$out$ORIGIN_REL.tmp"; mv "$out$ORIGIN_REL.tmp" "$out$ORIGIN_REL"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -eq 0 ]] && ! printf '%s' "$output" | grep 'origin record malformed' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it "同じ input: のキーが重複していれば malformed（FAIL）"
out="$(base_out)"
printf 'input:project-name=other\n' >> "$out$ORIGIN_REL"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep '\[FAIL\] origin record malformed.*重複.*input:project-name' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it "残っている *.dcb-new を WARN で一覧し、取り込み方を出す"
out="$(base_out)"
echo new > "$out/scripts/verify.sh.dcb-new"
mkdir -p "$out/.git" "$out/node_modules/x"
echo ignored > "$out/.git/a.dcb-new"
echo ignored > "$out/node_modules/x/b.dcb-new"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
if [[ $code -eq 0 ]] && printf '%s' "$output" | grep '\[WARN\] .*\.dcb-new' >/dev/null \
  && printf '%s' "$output" | grep 'scripts/verify.sh.dcb-new' >/dev/null \
  && printf '%s' "$output" | grep '手で混ぜて' >/dev/null \
  && ! printf '%s' "$output" | grep 'a.dcb-new\|b.dcb-new' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi

it "*.dcb-new が無ければ WARN を出さない（対照群）"
out="$(base_out)"
output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"
if printf '%s' "$output" | grep 'dcb-new が残' >/dev/null; then fail "$output"; else pass; fi

it "*.dcb-new の WARN は --strict で非 0 終了になる"
out="$(base_out)"
echo new > "$out/scripts/verify.sh.dcb-new"
bash "$DOCTOR" --target-dir "$out" --strict >/dev/null 2>&1
assert_eq "$?" "2" "strict 終了コード"

it "読めないディレクトリがあっても、doctor は最後まで走り、探索の失敗を WARN で出す（OK と言わない）"
if [[ "$(id -u)" == "0" ]]; then
  echo "  skip (root では chmod が効かない)"
  pass
else
  out="$(base_out)"
  mkdir -p "$out/locked/inner"
  chmod 000 "$out/locked"
  output="$(bash "$DOCTOR" --target-dir "$out" 2>&1)"; code=$?
  chmod 755 "$out/locked"
  if [[ $code -eq 0 ]] && printf '%s' "$output" | grep '\[WARN\] \*\.dcb-new を一部探索できませんでした' >/dev/null \
    && printf '%s' "$output" | grep 'Summary:' >/dev/null \
    && ! printf '%s' "$output" | grep 'no \*\.dcb-new left behind' >/dev/null; then pass; else fail "終了コード=$code
$output"; fi
fi

exit_with_result
