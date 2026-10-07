#!/usr/bin/env bash
# このリポジトリ自身の .devcontainer/compose.yaml の app サービスに init: true があることを
# 機械照合する（#469）。
#
# ## なぜ要るか
#
# app の PID 1 は sleep infinity で、sleep は孤児になったプロセスを回収しない。init: true が
# 無いとゾンビが溜まり、数日でプロセス数の上限に達して docker exec もコンテナ内の AI の
# セッションも止まる（実測: pids.current 18034 / pids.max 18039 で停止）。DCB の生成物は
# packages/devcontainer-bootstrap/tests/test-compose-config.sh が確かめるが、このリポジトリの
# compose.yaml は生成物ではなく手で持っているため、別に照合する。
#
# 依存はコアユーティリティ（awk）のみ。bash 3.2 互換を維持する。

set -uo pipefail
export LC_ALL=C
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-compose-init"

COMPOSE="$REPO_ROOT/.devcontainer/compose.yaml"

# app サービスの直下（4 字下げ）に init: true があるか
has_app_init() {
  awk '/^  app:$/ { inapp = 1; next } /^  [^ ]/ || /^[^ ]/ { inapp = 0 } inapp && $0 == "    init: true" { found = 1 } END { exit !found }' "$1"
}

it ".devcontainer/compose.yaml の app サービスに init: true がある"
if has_app_init "$COMPOSE"; then pass; else fail "init: true が無い（$COMPOSE）"; fi

it "検出は app の外の init: true を拾わない（検査が死んでいない）"
neg="$(mktemp "${TMPDIR:-/tmp}/compose-init-neg.XXXXXX")"
printf 'services:\n  app:\n    image: x\n  other:\n    init: true\n' > "$neg"
if has_app_init "$neg"; then fail "app の外を拾った"; else pass; fi
rm -f "$neg"

exit_with_result
