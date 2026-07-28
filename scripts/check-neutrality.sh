#!/usr/bin/env bash
# check-neutrality.sh — packages/ と .ai-playbook/ への固有名詞混入を検査する
#
# 検査対象・除外条件の正本。CI（.github/workflows/ci.yml の neutrality ジョブ）、
# ローカルゲート（scripts/acceptance.sh）、.github/PROJECT_DEFINITION.md の
# クイック検証は、いずれも条件を書き写さず本スクリプトを呼ぶ。
# 3 箇所へ grep を複製すると、片方だけが古くなる形で必ずずれるため。
#
# tests/ を除外する理由: 配布されない層であり、かつ「生成物に固有名詞が残らない
# こと」を検証する都合上、検査対象語をリテラルで持つ必要があるため。ここで検査
# すると中立性の趣旨と自己矛盾する。
#
# *.yml / *.yaml を含む理由: 規範層が配布する workflow テンプレート
# （.ai-playbook/templates/*.yml）を検査対象に入れるため。
#
# 終了コード: 0 = 混入なし / 1 = 混入あり（該当行を出力する）
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if hits="$(grep -rniE 'bascule|ojos' packages/ .ai-playbook/ \
  --include='*.sh' --include='*.md' --include='*.json' \
  --include='*.yml' --include='*.yaml' --exclude-dir=tests \
  | grep -v 'ojos/devcontainer-bootstrap' \
  | grep -v 'ojos/ai-playbook')"; then
  echo "$hits"
  echo "error: project-specific names must not leak into packages/ or .ai-playbook/" >&2
  exit 1
fi
