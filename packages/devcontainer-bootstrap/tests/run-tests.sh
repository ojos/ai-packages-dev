#!/usr/bin/env bash
# run-tests.sh — DCB のテストランナー
#
# 使い方:
#   bash tests/run-tests.sh            # 全テスト
#   bash tests/run-tests.sh permissions # 名前に permissions を含むテストのみ
#   DCB_TEST_JOBS=1 bash tests/run-tests.sh # 並列度を指定（1 なら直列）
#
# テストファイルは並列に実行する。並列度の既定は CPU 数（nproc、無ければ
# getconf _NPROCESSORS_ONLN、どちらも無ければ 1）。環境変数 DCB_TEST_JOBS で変える。
# 正の整数以外は、実行前にエラーで止める。
#
# 依存: bash, python3（URL 経路の検証にローカル HTTP サーバを使う）, tar, curl,
#       timeout（副作用の前で停止することを検証するテストが使う）,
#       静的解析器 shellcheck（生成物が素で解析を通ることを検証するテストが使う）
# ネットワークには出ない。
#
# この一覧は下の依存チェックと同じ内容を持つ。片方だけを更新しないこと。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"

# timeout は、副作用の前で停止することを検証するテスト（test-release-contract.sh /
# test-release-execution-guard.sh）が使う。無い環境では該当テストだけが
# "command not found" で落ち、原因が「依存の欠落」だと分からない形になるため、
# 他の依存と同じく入口で明示的に検査する。
#
# 静的解析器 shellcheck は、生成物が素の状態で解析を通ることを検証するテスト
# （test-generated-shellcheck.sh）が使う。同テストは不在をスキップ扱いにせず失敗
# させるが、そこで初めて分かるのでは原因が「依存の欠落」だと読み取りにくいため、
# timeout と同じくここで先に落とす。
for cmd in python3 tar curl timeout shellcheck; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "error: required command not found: $cmd" >&2
    exit 1
  }
done

# 並列度。不正な値は、走らせてから原因の分からない失敗になるより前に止める。
if [[ -n "${DCB_TEST_JOBS:-}" ]]; then
  JOBS="$DCB_TEST_JOBS"
  if ! [[ "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: DCB_TEST_JOBS must be a positive integer: $JOBS" >&2
    exit 1
  fi
else
  JOBS="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || JOBS=1
fi

TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-tests.XXXXXX")"
export TEST_TMP_ROOT

# 実行中のテスト（サブシェル）の PID。cleanup が中断時に止める。
RUNNING_PIDS=()

# テストが停止処理へ到達せず終わった場合（アサーション失敗による早期 return、
# 中断など）に備え、ランナー側でも配下のプロセスを確実に始末する。
# 供給元は python でも node でもあり得るため、特定のコマンド名では絞らない。
cleanup() {
  local kids rp rk
  # 中断されたとき、走っているテストを止める。テストは孫（HTTP サーバなど）を
  # 持つため、直下のサブシェルだけでなくその子も落とす。
  for rp in ${RUNNING_PIDS[@]+"${RUNNING_PIDS[@]}"}; do
    for rk in $(pgrep -P "$rp" 2>/dev/null || true); do
      kill "$rk" 2>/dev/null || true
    done
    kill "$rp" 2>/dev/null || true
  done
  kids="$(pgrep -P $$ 2>/dev/null || true)"
  if [[ -n "$kids" ]]; then
    # テストファイル（bash）は既に終了しているため、ここで残るのは
    # 孫として取り残されたサーバのみ。
    echo "$kids" | while read -r p; do kill "$p" 2>/dev/null || true; done
  fi
  # テストが起動した HTTP サーバのうち、親を失ったものを掃除する。
  # TEST_TMP_ROOT 配下を配信しているものだけを対象にし、無関係なプロセスは触らない。
  # 並列実行ではファイルごとのサブディレクトリ（TEST_TMP_ROOT の配下）を配信するため、
  # 同じ前方一致で当たる。
  for p in $(pgrep -f "$TEST_TMP_ROOT" 2>/dev/null || true); do
    [[ "$p" == "$$" ]] && continue
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$TEST_TMP_ROOT"
}
trap cleanup EXIT
# 中断（Ctrl-C / TERM）でも EXIT トラップへ確実に到達させる。
trap 'exit 130' INT TERM

echo "== devcontainer-bootstrap tests =="
echo

# 並列実行では出力が混ざるため、ファイルごとに専用の一時領域と出力ファイルを持たせ、
# 全部終わってからファイル名順にまとめて表示する。TEST_TMP_ROOT をファイルごとの
# サブディレクトリにするのは、テスト同士が同じ固定名の領域を奪い合わないため。
ROOT_BASE="$TEST_TMP_ROOT"
RESULTS_DIR="$ROOT_BASE/.results"
mkdir -p "$RESULTS_DIR"

names=()
for f in "$TESTS_DIR"/test-*.sh; do
  [[ -f "$f" ]] || continue
  name="$(basename "$f" .sh)"
  if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then
    continue
  fi
  names+=("$name")
done
total=${#names[@]}
failed_files=0

if [[ "$total" -eq 0 ]]; then
  echo "error: no tests matched filter: $FILTER" >&2
  exit 1
fi

# 終わったテストを 1 つ以上待って配列から外す。bash 3.2 には wait -n が無いため、
# kill -0 で生存を確かめて回る。最も古いテストだけを待つと、長いテスト（2 分超の
# ものがある）が終わるまで、先に空いた枠へ次のテストを入れられない。
reap_finished() {
  local p alive
  while :; do
    alive=()
    for p in "${RUNNING_PIDS[@]}"; do
      if kill -0 "$p" 2>/dev/null; then
        alive+=("$p")
      else
        wait "$p" 2>/dev/null || true
      fi
    done
    if [[ "${#alive[@]}" -lt "${#RUNNING_PIDS[@]}" ]]; then
      RUNNING_PIDS=(${alive[@]+"${alive[@]}"})
      return 0
    fi
    sleep 0.2
  done
}

for name in "${names[@]}"; do
  if [[ "${#RUNNING_PIDS[@]}" -ge "$JOBS" ]]; then
    reap_finished
  fi
  mkdir -p "$ROOT_BASE/$name"
  (
    TEST_TMP_ROOT="$ROOT_BASE/$name"
    export TEST_TMP_ROOT
    bash "$TESTS_DIR/$name.sh" >"$RESULTS_DIR/$name.out" 2>"$RESULTS_DIR/$name.err"
    echo $? >"$RESULTS_DIR/$name.rc"
  ) &
  RUNNING_PIDS+=("$!")
done
while [[ "${#RUNNING_PIDS[@]}" -gt 0 ]]; do
  reap_finished
done

# stdout と stderr は別々に戻す。失敗の詳細（lib.sh の fail）は stderr に出るため、
# 呼び出し側が stdout を捨てても（release-packages.sh の run_dcb_tests）見える。
failed_names=()
for name in "${names[@]}"; do
  cat "$RESULTS_DIR/$name.out"
  cat "$RESULTS_DIR/$name.err" >&2
  rc="$(cat "$RESULTS_DIR/$name.rc" 2>/dev/null || echo 1)"
  if [[ "$rc" != "0" ]]; then
    failed_files=$((failed_files + 1))
    failed_names+=("$name")
  fi
done

echo "=================================="
if [[ "$failed_files" -eq 0 ]]; then
  echo "全 $total ファイル 成功"
  exit 0
fi
echo "$total ファイル中 $failed_files ファイルで失敗" >&2
for name in "${failed_names[@]}"; do
  echo "  失敗: $name" >&2
done
exit 1
