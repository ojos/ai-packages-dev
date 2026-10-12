#!/usr/bin/env bash
# 配るワークフロー 5 本の実行先（runs-on）が、リポジトリ変数で切り替えられる形であることを検証する。
#
# 背景:
#   runs-on: ubuntu-latest の固定では、private リポジトリで GitHub のランナーを使うたびに
#   Actions の課金枠を消費する。利用側で手で書き換えると DCB の記録（ORIGIN）とずれる。
#   変数 ACTIONS_RUNS_ON があればそのラベル、無ければ ubuntu-latest で動く形にそろえる。
#
# ここで固定するのは 3 点:
#   1. 生成した 5 本すべての runs-on が、変数と既定値の形であること。
#   2. （1 に含まれる）ubuntu-latest で固定の runs-on が 1 つも残っていないこと。
#   3. 5 本が YAML として妥当であること（actionlint → PyYAML → 構造検査の段構え）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-runs-on-variable"

EXPECTED="runs-on: \${{ vars.ACTIONS_RUNS_ON || 'ubuntu-latest' }}"
WORKFLOWS="identity-guard.yml verify.yml second-opinion-gate.yml copilot-review.yml review-gate.yml"

out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot-review --playbook-from "$PLAYBOOK_SRC" >/dev/null 2>&1

for name in $WORKFLOWS; do
  WF="$out/.github/workflows/$name"

  it "$name が生成される"
  assert_file_exists "$WF"

  it "$name の runs-on がすべて変数と既定値の形である（ubuntu-latest 固定が残っていない）"
  # コメント行は除いて、実際の runs-on の行だけを数える。
  lines="$(grep -E '^[[:space:]]*runs-on:' "$WF" || true)"
  count="$(printf '%s\n' "$lines" | grep -c . || true)"
  bad="$(printf '%s\n' "$lines" | grep -vF "$EXPECTED" | grep -c . || true)"
  if [[ "$count" -ge 1 && "$bad" -eq 0 ]]; then
    pass
  else
    fail "runs-on が期待の形ではない（${count} 行 / 不一致 ${bad} 行）: ${lines}"
  fi

  it "$name が YAML/Actions として妥当である"
  assert_workflow_valid "$WF"
done

exit_with_result
