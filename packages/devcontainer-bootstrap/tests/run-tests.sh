#!/usr/bin/env bash
# run-tests.sh — DCB のテストランナー
#
# 使い方:
#   bash tests/run-tests.sh            # 全テスト
#   bash tests/run-tests.sh permissions # 名前に permissions を含むテストのみ
#
# 依存: bash, python3（URL 経路の検証にローカル HTTP サーバを使う）, tar, curl
# ネットワークには出ない。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"

for cmd in python3 tar curl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "error: required command not found: $cmd" >&2
    exit 1
  }
done

TEST_TMP_ROOT="$(mktemp -d)"
export TEST_TMP_ROOT
cleanup() {
  # 取り残した HTTP サーバがあれば止める
  pkill -P $$ -f 'http.server' 2>/dev/null || true
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
