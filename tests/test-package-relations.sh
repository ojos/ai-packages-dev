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
# ルート / ai-playbook / DCB / devhost の 4 つの README。どれも必須で、目印が無ければ落ちる。
#
# devhost の README については、本文が参照する節「DCB と一緒に使うと揃うもの」も見る。
# その節の表は、DCB の生成物（bootstrap.sh）が持つものを書き写しているので、次を照合する
# （shared-ai-rules.md 12 章）。
#   - 表の行が 4 つ（tmux / compose の init: true / codex のサンドボックス / UID の合わせ込み）
#   - 共通の説明文が列挙する 4 項目と、表の行が同じ
#   - 4 項目が bootstrap.sh に実在する（tmux の feature、compose の init: true、
#     apparmor=unconfined と seccomp=unconfined、updateRemoteUserUID を false にしていないこと）
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
it "$HOST の関係の説明がルートの README と一致する"
assert_eq "$(extract_block "$REPO_ROOT/$HOST")" "$REF_BLOCK" "$HOST"

it "$HOST に節「$HOST_SECTION」がある"
if grep -E "^#+ ${HOST_SECTION}\$" "$REPO_ROOT/$HOST" >/dev/null; then
  pass
else
  fail "$HOST に見出し「$HOST_SECTION」が無い"
fi

# 節の表の行の、最初の列の先頭の語（tmux / compose / codex / UID）
HOST_ROWS="$(awk -v h="$HOST_SECTION" '
  /^#+ / { inside = ($0 ~ h) ; next }
  inside && /^\| / && !/^\|---/ && !/^\| DCB の生成物/ { sub(/^\| /, ""); split($0, a, /[（ ]/); print a[1] }
' "$REPO_ROOT/$HOST")"

it "節「$HOST_SECTION」の表が 4 行で、tmux / compose / codex / UID を持つ"
assert_eq "$(printf '%s\n' "$HOST_ROWS" | sort | tr '\n' ' ')" "UID codex compose tmux " "表の行"

it "共通の説明文が、表と同じ 4 項目を列挙する"
listed="tmux、compose の \`init: true\`、codex のサンドボックスの設定、UID の合わせ込み"
if printf '%s\n' "$REF_BLOCK" | grep -F "$listed" >/dev/null; then
  pass
else
  fail "共通の説明文に「$listed」が無い（表の 4 行と揃えること）"
fi

BOOT="$REPO_ROOT/packages/devcontainer-bootstrap/bootstrap.sh"
it "4 項目が DCB の bootstrap.sh に実在する"
missing=""
grep -F 'ghcr.io/devcontainers-extra/features/tmux-apt-get' "$BOOT" >/dev/null || missing="$missing tmux"
grep -E '^ +init: true$' "$BOOT" >/dev/null || missing="$missing init:true"
grep -F 'apparmor=unconfined' "$BOOT" >/dev/null || missing="$missing apparmor=unconfined"
grep -F 'seccomp=unconfined' "$BOOT" >/dev/null || missing="$missing seccomp=unconfined"
# UID の合わせ込みは「書かずに既定（有効）に任せる」ので、false にしていないことを見る
grep -E '"updateRemoteUserUID" *: *false' "$BOOT" >/dev/null && missing="$missing updateRemoteUserUID=false"
if [[ -z "$missing" ]]; then pass; else fail "bootstrap.sh と食い違う:$missing"; fi

exit_with_result
