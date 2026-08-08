#!/usr/bin/env bash
# run-tests.sh — DCB のテストランナー
#
# 使い方:
#   bash tests/run-tests.sh            # 全テスト
#   bash tests/run-tests.sh permissions # 名前に permissions を含むテストのみ
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

TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-tests.XXXXXX")"
export TEST_TMP_ROOT

# テストが停止処理へ到達せず終わった場合（アサーション失敗による早期 return、
# 中断など）に備え、ランナー側でも配下のプロセスを確実に始末する。
# 供給元は python でも node でもあり得るため、特定のコマンド名では絞らない。
cleanup() {
  local kids
  kids="$(pgrep -P $$ 2>/dev/null || true)"
  if [[ -n "$kids" ]]; then
    # テストファイル（bash）は既に終了しているため、ここで残るのは
    # 孫として取り残されたサーバのみ。
    echo "$kids" | while read -r p; do kill "$p" 2>/dev/null || true; done
  fi
  # テストが起動した HTTP サーバのうち、親を失ったものを掃除する。
  # TEST_TMP_ROOT 配下を配信しているものだけを対象にし、無関係なプロセスは触らない。
  for p in $(pgrep -f "$TEST_TMP_ROOT" 2>/dev/null || true); do
    [[ "$p" == "$$" ]] && continue
    kill "$p" 2>/dev/null || true
  done
  rm -rf "$TEST_TMP_ROOT"
}
trap cleanup EXIT

echo "== devcontainer-bootstrap tests =="
echo

total=0
failed_files=0

for f in "$TESTS_DIR"/test-*.sh; do
  [[ -f "$f" ]] || continue
  name="$(basename "$f" .sh)"
  if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then
    continue
  fi
  total=$((total + 1))
  if bash "$f"; then
    :
  else
    failed_files=$((failed_files + 1))
  fi
done

if [[ "$total" -eq 0 ]]; then
  echo "error: no tests matched filter: $FILTER" >&2
  exit 1
fi

echo "=================================="
if [[ "$failed_files" -eq 0 ]]; then
  echo "全 $total ファイル 成功"
  exit 0
fi
echo "$total ファイル中 $failed_files ファイルで失敗" >&2
exit 1
