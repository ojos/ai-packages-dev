#!/usr/bin/env bash
# check-neutrality.sh — packages/ と .ai-playbook/ への固有名詞混入を検査する
#
# 検査対象・除外条件の正本。CI（.github/workflows/ci.yml の neutrality ジョブ）、
# ローカルゲート（scripts/acceptance.sh）、.github/PROJECT_DEFINITION.md の
# クイック検証は、いずれも条件を書き写さず本スクリプトを呼ぶ。
# 3 箇所へ grep を複製すると、片方だけが古くなる形で必ずずれるため。
#
# dev01 を見る理由（#375）: packages/devcontainer-host/ の取り込み元が使っていた機械名。
# 取り込み元が持っていた同種の検査（check-devhost.sh）をここへ寄せ、2 本目の
# 中立性検査を増やさない。取り込み元のリポジトリ名は禁止語にしない。取り込みの
# 経緯は取り込み元の票番号で参照する（例: 「game-forge #873」）と決めているため。
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

FORBIDDEN='bascule|ojos|dev01'

raw="$(grep -rniE "$FORBIDDEN" packages/ .ai-playbook/ \
  --include='*.sh' --include='*.md' --include='*.json' \
  --include='*.yml' --include='*.yaml' --include='*.example' --include='*.service' \
  --exclude-dir=tests || true)"

# 除外は「行ごと捨てる」のではなく「許可された配布先だけを番兵へ置き換えてから
# 再判定する」。行単位の grep -v だと、同一行に禁止語と許可 URL が共存したとき
# （例: `# bascule 用の ojos/devcontainer-bootstrap 設定`）に禁止語ごと検査を逃れる。
#
# 置き換えは部分一致なので、許可名を接頭辞に持つ別リポジトリ名
# （例: ojos/ai-playbook-test）も一致してしまう。番兵の直後に名前文字が残る場合は
# 別名であり許可対象ではないため、違反として扱う。`.git` や `/archive/...` のように
# 名前文字以外が続く形は正規の URL なので通す。
#
# 報告は元の行で行い、加工後の行は判定にのみ使う。
SENTINEL='@@ALLOWED_DISTRIBUTION_TARGET@@'
hits=""
while IFS= read -r line; do
  [ -n "$line" ] || continue

  probe="${line//ojos\/devcontainer-bootstrap/$SENTINEL}"
  probe="${probe//ojos\/ai-playbook/$SENTINEL}"
  probe="${probe//ojos\/devcontainer-host/$SENTINEL}"

  if printf '%s' "$probe" | grep -E "${SENTINEL}[A-Za-z0-9_-]" >/dev/null; then
    hits="${hits}${line}"$'\n'
    continue
  fi

  if printf '%s' "${probe//$SENTINEL/}" | grep -iE "$FORBIDDEN" >/dev/null; then
    hits="${hits}${line}"$'\n'
  fi
done <<< "$raw"

if [ -n "$hits" ]; then
  printf '%s' "$hits"
  echo "error: project-specific names must not leak into packages/ or .ai-playbook/" >&2
  exit 1
fi
