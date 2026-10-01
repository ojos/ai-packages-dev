#!/usr/bin/env bash
# review-usable.sh は、リモート最終ゲート（任意の層）の確認側が「要求・投稿された
# だけでなく実際に読めたか」を判定するために使う opt-in の雛形である。このリポジトリ
# 自身は撤退済みで写しを持たないため（ojos/ai-packages-dev#364）、ここで見るのは
# 雛形としての判定そのものの正しさだけである。
#
# 判定の正しさ:
#   review-usable.sh は GitHub 上でしか実行できない .github/workflows/review-gate.yml
#   （DCB の --with-copilot-review を選んだ利用側にのみ配置される）から呼ばれるため、
#   受け入れ条件を実際に PR を立てる以外の方法で確かめる手段が要る。
#   .ai-playbook/templates/check-review-usable.sh がその表駆動の自己検査で、ここでは
#   それを実行して結果を拾う（判定の一覧そのものはあちらが持ち、ここでは複製しない）。
#
# このリポジトリ自身の採用・写しの一致は見ない:
#   以前はこのリポジトリ自身も scripts/review-usable.sh を写しとして持ち、
#   .github/workflows/review-gate.yml から呼んでいたが、リモート最終ゲートを
#   任意の層へ改めたのに合わせて撤退した。採用側の写しの一致検査は
#   tests/test-workflow-mirror.sh / packages/devcontainer-bootstrap/tests/
#   test-review-gate.sh（DCB の生成物側）が別に持つ。
#
# check-review-usable.sh のような表駆動の自己検査を持たない他の *.sh 雛形
# （second-opinion-review.sh 等）と違い、review-usable.sh には導入先ごとの
# 記入欄・customization point が無い。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-review-usable"

TPL="$REPO_ROOT/.ai-playbook/templates/review-usable.sh"
CHECK="$REPO_ROOT/.ai-playbook/templates/check-review-usable.sh"

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

exit_with_result
