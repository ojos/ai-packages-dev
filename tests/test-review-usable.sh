#!/usr/bin/env bash
# review-gate.yml（確認側）が判定を委ねる scripts/review-usable.sh について、
# 判定そのものの正しさと、この開発リポジトリ自身が使う写しの追随を検査する。
#
# 判定の正しさ:
#   review-usable.sh は GitHub 上でしか実行できない .github/workflows/review-gate.yml
#   から呼ばれるため、受け入れ条件を実際に PR を立てる以外の方法で確かめる手段が要る。
#   .ai-playbook/templates/check-review-usable.sh がその表駆動の自己検査で、ここでは
#   それを実行して結果を拾う（判定の一覧そのものはあちらが持ち、ここでは複製しない）。
#
# 写しの追随:
#   このリポジトリ自身の .github/workflows/review-gate.yml は
#   `bash scripts/review-usable.sh` を呼ぶため、scripts/review-usable.sh が
#   .ai-playbook/templates/review-usable.sh の写しとして実在し、かつ一致している
#   必要がある（tests/test-workflow-mirror.sh が .yml 側の一致を担保するのと同じ
#   理由）。ずれると、このリポジトリ自身のリモート最終ゲートが雛形と違う判定を
#   することになる。
#
# check-review-usable.sh のような表駆動の自己検査を持たない他の *.sh 雛形
# （second-opinion-review.sh 等）と違い、review-usable.sh には導入先ごとの
# 記入欄・customization point が無い。逐語一致を要求してよい理由はそこにある。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-review-usable"

TPL="$REPO_ROOT/.ai-playbook/templates/review-usable.sh"
CHECK="$REPO_ROOT/.ai-playbook/templates/check-review-usable.sh"
COPY="$REPO_ROOT/scripts/review-usable.sh"

it "規範パッケージが review-usable.sh / check-review-usable.sh を持つ"
if [[ -f "$TPL" && -f "$CHECK" ]]; then
  pass
else
  fail "$TPL または $CHECK が見つからない"
fi

it "review-usable.sh の表駆動の自己検査（check-review-usable.sh）が緑"
# 出力は check-review-usable.sh 側で 1 行ずつ「ok/FAIL」相当を出すため、ここでは
# 終了コードだけを見る。個々のケースを複製すると、あちら側で足したケースがここへ
# 反映されないまま「検査している気になる」状態を作る。
if out="$(bash "$CHECK" 2>&1)"; then
  pass
else
  fail "check-review-usable.sh が失敗した: $(printf '%s' "$out" | tail -n 20 | tr '\n' '/')"
fi

it "このリポジトリ自身が使う scripts/review-usable.sh が実在する"
# .github/workflows/review-gate.yml（このリポジトリ自身の写し）が
# `bash scripts/review-usable.sh` を呼ぶため、実行時にこのパスが要る。
if [[ -f "$COPY" ]]; then
  pass
else
  fail "$COPY が見つからない"
fi

it "scripts/review-usable.sh は雛形と完全一致する（コピーであって再実装でない）"
if [[ ! -f "$COPY" ]]; then
  fail "前段の存在検査に失敗しているため照合できない"
elif cmp -s "$TPL" "$COPY"; then
  pass
else
  detail="$(diff "$TPL" "$COPY" | head -n 12 | tr '\n' '/')"
  fail "雛形と写しが食い違う（両方を同時に直す）: $detail"
fi

exit_with_result
