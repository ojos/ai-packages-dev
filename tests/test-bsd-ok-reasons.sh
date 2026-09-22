#!/usr/bin/env bash
# 移植性の逃げ道の印（`# bsd-ok: 理由`）に、根拠が書かれていることを検査する。
#
# scripts/check-shell-portability.sh は「理由が空でないこと」しか見ない。それは
# 検査の責務としては正しい——印の妥当性はレビューの責務であり、機械が中身の正しさを
# 判定できるとは限らないためである。
#
# **ただし 1 つだけ、機械で見られることがある。理由が「どの種類か」である。**
#
# 当初は「実行環境に言及していること」を求めたが、**同じファイルの中に別の種類の
# 印が同居する**ため成立しなかった（検査名に綴りが入るだけの行、分岐の枝が窓の外に
# ある行）。自由文を 1 つの語で縛ると、正しい印まで落ちる。
#
# そこで**語彙を決める**。印の理由は、下の既知の種類のいずれかに当てはまらなければ
# ならない。新しい種類を使いたければ、この一覧へ足す差分が要る——**その差分が
# レビューに出ることが、この検査の目的である。** 自由文のままだと「とりあえず」で
# 増えていき、あとから種類ごとに見直すことができない。
#
# 対象は、この一連で印を足した層に限る。検査自身とそのテストは印の密度が桁違いで
# （綴りをリテラルで持つのが仕事なので当然である）、同じ語彙を課す意味が無い。
set -uo pipefail
export LC_ALL=C.UTF-8
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-bsd-ok-reasons"

# 実行環境を根拠にする層。ここへ付いた印は、実行環境に言及していなければならない。
SCOPED='scripts/release-packages.sh
packages/devcontainer-bootstrap/tests/test-readme-install.sh
packages/devcontainer-bootstrap/tests/test-release-audit.sh
packages/devcontainer-bootstrap/tests/test-release-contract.sh'

# 既知の種類。理由にこのいずれかが現れなければならない。
#
#   Actions / CI … その層を Linux でしか実行しない
#   検査名       … 検査の名前や報告文に綴りが入るだけで、呼び出しではない
#   分岐の中     … 可搬性のための分岐の内側だが、BSD 側の枝が前後 1 行の外にある
KNOWN='Actions
CI
検査名
分岐の中'

reason_is_known() {
  local reason="$1" kind
  while IFS= read -r kind; do
    [ -n "$kind" ] || continue
    case "$reason" in *"$kind"*) return 0 ;; esac
  done <<KINDS
$KNOWN
KINDS
  return 1
}

# 印の付いた行を "パス:行番号:理由" で列挙する。
marks_in() {
  local f="$1"
  grep -nE '#[[:space:]]*bsd-ok:' "$REPO_ROOT/$f" 2>/dev/null \
    | sed -e "s|^|$f:|" -e 's|#[[:space:]]*bsd-ok:[[:space:]]*|\t|'
}

TOTAL=0
BAD=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    TOTAL=$((TOTAL + 1))
    reason="${hit#*$'\t'}"
    reason_is_known "$reason" || BAD="${BAD}${hit}"$'\n'
  done <<MARKS
$(marks_in "$f")
MARKS
done <<FILES
$SCOPED
FILES

it "対象の層から、印を 1 件以上抽出できる"
# 0 件のまま緑になると、以降の検査は対象ゼロで無条件に通る（偽の緑）。
if [[ "$TOTAL" -gt 0 ]]; then
  pass
else
  fail "印を 1 件も抽出できなかった（抽出が壊れているか、印が消えた）"
fi

it "その層の印がすべて既知の種類のいずれかである"
if [[ -z "$BAD" ]]; then
  pass
else
  fail "既知の種類に当てはまらない理由を持つ印（種類を足すなら KNOWN へ追加する）:
$BAD"
fi

# ── 検査ロジック自身の検証 ────────────────────────────────────────────────────
#
# 現行ツリーが緑なのは「理由が書かれている」からであって「検査が動いている」証明では
# ない。言及の無い理由を作って、実際に拾えることを示す。

it "既知の種類に当てはまらない理由を検出する（意図的な負例）"
probe_bad=""
for reason in 'とりあえず' 'あとで直す' '不要'; do
  reason_is_known "$reason" && probe_bad="${probe_bad} $reason"
done
if [[ -z "$probe_bad" ]]; then pass; else fail "未知の理由を通してしまう:$probe_bad"; fi

it "既知の種類の理由は検出しない（対照群）"
probe_ok=""
for reason in \
  'リリース実行は Actions（Linux）でしか行わない' \
  'CI（Linux）でしか実行しないテスト' \
  '検査名に綴りが入るだけ' \
  '分岐の中（else 側に shasum の枝がある）'; do
  reason_is_known "$reason" || probe_ok="${probe_ok} $reason"
done
if [[ -z "$probe_ok" ]]; then pass; else fail "既知の理由を誤検出する:$probe_ok"; fi

exit_with_result
