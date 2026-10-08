#!/usr/bin/env bash
# 3 パッケージ（ai-playbook / DCB / devhost）の関係の説明が、各 README で同じ文面かを
# 機械照合する（#494）。
#
# ## なぜ要るか
#
# 関係の説明は複数の README に同じ文面で書き写している。一覧の複製は必ず古くなり、
# 片方だけ直すと入口によって説明が食い違う（shared-ai-rules.md 12 章「一覧の複製は
# 機械照合で担保する」）。目印の間の本文が全 README で一致することを検査する。
#
# ## 対象
#
# 必須: ルート / ai-playbook / DCB の README。
# 任意: devhost の README。目印を持つときだけ照合に加わる（devhost の README への
# 追記は別の変更で入るため）。目印を持つ場合は、本文が参照する節
# 「DCB と一緒に使うと揃うもの」が実在することも確かめる。
#
# 依存はコアユーティリティ（awk / grep）のみ。bash 3.2 互換を維持する。

set -uo pipefail
export LC_ALL=C
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-package-relations"

BEGIN_MARK='<!-- package-relations:begin -->'
END_MARK='<!-- package-relations:end -->'
HOST_SECTION='DCB と一緒に使うと揃うもの'

# 目印の間（目印を含む）を出力する
extract_block() {
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { on = 1 }
    on { print }
    $0 == e { on = 0 }
  ' "$1"
}

REF_FILE="README.md"
REF_BLOCK="$(extract_block "$REPO_ROOT/$REF_FILE")"

it "ルートの README に関係の説明の目印がある"
if [[ -n "$REF_BLOCK" ]] && [[ "$(printf '%s\n' "$REF_BLOCK" | grep -c -F "$END_MARK")" -eq 1 ]]; then
  pass
else
  fail "$REF_FILE に $BEGIN_MARK ... $END_MARK が見つからない"
fi

for f in .ai-playbook/README.md packages/devcontainer-bootstrap/README.md; do
  it "$f の関係の説明がルートの README と一致する"
  assert_eq "$(extract_block "$REPO_ROOT/$f")" "$REF_BLOCK" "$f"
done

HOST="packages/devcontainer-host/README.md"
if [[ -f "$REPO_ROOT/$HOST" ]] && grep -q -F "$BEGIN_MARK" "$REPO_ROOT/$HOST"; then
  it "$HOST の関係の説明がルートの README と一致する"
  assert_eq "$(extract_block "$REPO_ROOT/$HOST")" "$REF_BLOCK" "$HOST"

  it "$HOST に節「$HOST_SECTION」がある"
  if grep -q -E "^#+ ${HOST_SECTION}\$" "$REPO_ROOT/$HOST"; then
    pass
  else
    fail "$HOST に見出し「$HOST_SECTION」が無い"
  fi
fi

exit_with_result
