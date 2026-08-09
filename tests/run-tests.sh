#!/usr/bin/env bash
# run-tests.sh — プロジェクト層のテストランナー
#
# 使い方:
#   bash tests/run-tests.sh              # 全テスト
#   bash tests/run-tests.sh runbook      # 名前に runbook を含むテストのみ
#
# ここで回すのは「この開発リポジトリ自身の規律」の検査で、配布パッケージの検査
# （packages/devcontainer-bootstrap/tests/run-tests.sh）とは層が違う。
#
# 依存はコアユーティリティ（awk / sed / grep / comm）だけに保つ。大半が文書と実装の
# テキスト照合で、パッケージ層のような外部依存（python3 / tar / curl / timeout）は
# 要らない。所要時間も秒単位に収める。scripts/acceptance.sh はこれを DCB テスト
# （約 4 分）より前に置き、安い検査から落ちるようにしている。
#
# 例外は test-agy-telemetry.sh で、こちらは scripts/install-ai-tools.sh を実行する
# ため jq を要する。持ち込んでいるのは検査対象スクリプト自身の依存で、テスト側が
# 増やした依存ではない（scripts/acceptance.sh も同じ理由で jq を前提にしている）。
# ネットワークへは出ない（導入処理は PATH 上の stub で skip させる）。

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"

echo "== project tests =="
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
