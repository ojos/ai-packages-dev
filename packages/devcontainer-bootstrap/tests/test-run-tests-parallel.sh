#!/usr/bin/env bash
# test-run-tests-parallel.sh — run-tests.sh の並列実行（#458）の振る舞いを検証する。
#
# ランナーを一時ディレクトリへ複製し、複製先にはこのテスト専用のダミーだけを置く。
# 本物のテスト一式を入れ子で再帰的に起動しないため。依存コマンドの事前検査は
# 複製したランナーでも走るが、親のランナーが同じ検査を通っているので問題にならない。

set -uo pipefail

if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-run-tests-parallel.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-run-tests-parallel"

W="$(new_workdir)"
mkdir -p "$W/tests"
cp "$TESTS_DIR/run-tests.sh" "$TESTS_DIR/lib.sh" "$W/tests/"

# ダミー: 成功 2 つ、失敗 1 つ。専用の TEST_TMP_ROOT が渡ることも検査する。
for n in ok-a ok-b; do
  cat >"$W/tests/test-dummy-$n.sh" <<'DUMMY'
#!/usr/bin/env bash
echo "dummy-output $(basename "$0")"
[[ -d "$TEST_TMP_ROOT" ]] || exit 1
exit 0
DUMMY
done
cat >"$W/tests/test-dummy-ng.sh" <<'DUMMY'
#!/usr/bin/env bash
echo "dummy-output $(basename "$0")"
echo "dummy-fail-detail" >&2
exit 1
DUMMY

# 複製したランナーを走らせる。出力は R_OUT、終了コードは R_RC。
# 親のランナーが渡した TEST_TMP_ROOT は、複製先が自分で作るものと混ざらないよう外す。
run() { # [env...] [フィルタ]
  R_OUT="$(env -u TEST_TMP_ROOT "$@" 2>&1)"
  R_RC=$?
}
RUNNER="$W/tests/run-tests.sh"

it "失敗が混じると exit 1 になり、失敗したファイル名が出る"
run DCB_TEST_JOBS=4 bash "$RUNNER"
if [[ "$R_RC" == "1" ]] && printf '%s' "$R_OUT" | grep '失敗: test-dummy-ng' >/dev/null \
   && ! printf '%s' "$R_OUT" | grep '失敗: test-dummy-ok' >/dev/null; then pass; else fail "rc=$R_RC"; fi

it "各ファイルの出力が、ファイル名順にまとめて表示される"
order="$(printf '%s' "$R_OUT" | grep -o 'dummy-output test-dummy-[a-z-]*' | tr '\n' ' ')"
assert_eq "dummy-output test-dummy-ng dummy-output test-dummy-ok-a dummy-output test-dummy-ok-b " "$order"

it "失敗の詳細（テストの stderr）は、ランナーの stdout を捨てても stderr に出る"
err="$(env -u TEST_TMP_ROOT DCB_TEST_JOBS=4 bash "$RUNNER" 2>&1 >/dev/null)"
assert_contains "$err" "dummy-fail-detail"

it "すべて成功なら exit 0 になる"
run DCB_TEST_JOBS=4 bash "$RUNNER" ok
if [[ "$R_RC" == "0" ]] && printf '%s' "$R_OUT" | grep '全 2 ファイル 成功' >/dev/null; then pass; else fail "rc=$R_RC"; fi

it "DCB_TEST_JOBS=1（直列）でも同じ結果になる"
run DCB_TEST_JOBS=1 bash "$RUNNER"
if [[ "$R_RC" == "1" ]] && printf '%s' "$R_OUT" | grep '3 ファイル中 1 ファイルで失敗' >/dev/null \
   && printf '%s' "$R_OUT" | grep '失敗: test-dummy-ng' >/dev/null; then pass; else fail "rc=$R_RC"; fi

for bad in abc 0 -1 1.5; do
  it "DCB_TEST_JOBS=$bad は実行前にエラーで止まる"
  run DCB_TEST_JOBS="$bad" bash "$RUNNER"
  if [[ "$R_RC" == "1" ]] && printf '%s' "$R_OUT" | grep 'DCB_TEST_JOBS' >/dev/null \
     && ! printf '%s' "$R_OUT" | grep 'dummy-output' >/dev/null; then pass; else fail "rc=$R_RC"; fi
done

it "桁あふれするほど大きい DCB_TEST_JOBS でも止まらずに完走する"
run DCB_TEST_JOBS=99999999999999999999 timeout 60 bash "$RUNNER" ok
if [[ "$R_RC" == "0" ]] && printf '%s' "$R_OUT" | grep '全 2 ファイル 成功' >/dev/null; then pass; else fail "rc=$R_RC"; fi

it "ランナーは実行権限を持つ（git のモードが 100755）"
mode="$(git -C "$TESTS_DIR" ls-files -s run-tests.sh 2>/dev/null | cut -d' ' -f1)"
if [[ -z "$mode" || "$mode" == "100755" ]]; then pass; else fail "mode=$mode"; fi

it "フィルタに一致するテストが無ければ exit 1 になる"
run DCB_TEST_JOBS=2 bash "$RUNNER" nomatch
if [[ "$R_RC" == "1" ]] && printf '%s' "$R_OUT" | grep 'no tests matched' >/dev/null; then pass; else fail "rc=$R_RC"; fi

exit_with_result
