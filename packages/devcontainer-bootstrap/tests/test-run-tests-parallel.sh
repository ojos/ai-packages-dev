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
if [[ "$R_RC" == "1" ]] && printf '%s' "$R_OUT" | grep -q '失敗: test-dummy-ng' \
   && ! printf '%s' "$R_OUT" | grep -q '失敗: test-dummy-ok'; then pass; else fail "rc=$R_RC"; fi

it "各ファイルの出力が、ファイル名順にまとめて表示される"
order="$(printf '%s' "$R_OUT" | grep -o 'dummy-output test-dummy-[a-z-]*' | tr '\n' ' ')"
assert_eq "dummy-output test-dummy-ng dummy-output test-dummy-ok-a dummy-output test-dummy-ok-b " "$order"

it "すべて成功なら exit 0 になる"
run DCB_TEST_JOBS=4 bash "$RUNNER" ok
if [[ "$R_RC" == "0" ]] && printf '%s' "$R_OUT" | grep -q '全 2 ファイル 成功'; then pass; else fail "rc=$R_RC"; fi

it "DCB_TEST_JOBS=1（直列）でも同じ結果になる"
run DCB_TEST_JOBS=1 bash "$RUNNER"
if [[ "$R_RC" == "1" ]] && printf '%s' "$R_OUT" | grep -q '3 ファイル中 1 ファイルで失敗' \
   && printf '%s' "$R_OUT" | grep -q '失敗: test-dummy-ng'; then pass; else fail "rc=$R_RC"; fi

for bad in abc 0 -1 1.5; do
  it "DCB_TEST_JOBS=$bad は実行前にエラーで止まる"
  run DCB_TEST_JOBS="$bad" bash "$RUNNER"
  if [[ "$R_RC" == "1" ]] && printf '%s' "$R_OUT" | grep -q 'DCB_TEST_JOBS' \
     && ! printf '%s' "$R_OUT" | grep -q 'dummy-output'; then pass; else fail "rc=$R_RC"; fi
done

it "フィルタに一致するテストが無ければ exit 1 になる"
run DCB_TEST_JOBS=2 bash "$RUNNER" nomatch
if [[ "$R_RC" == "1" ]] && printf '%s' "$R_OUT" | grep -q 'no tests matched'; then pass; else fail "rc=$R_RC"; fi

exit_with_result
