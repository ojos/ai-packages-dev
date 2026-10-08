#!/usr/bin/env bash
# terraform-refuse-destroy.sh — 公開リポジトリを消す・作り直す plan を、apply の前に落とす（#487）
#
# .github/workflows/terraform.yml の plan / apply の両方が、plan の直後に呼ぶ。
#
# ## なぜ要るのか
#
# apply に使う PAT の Administration: write は、リポジトリの削除もできる権限である。
# 普段は infra/github/repositories.tf の prevent_destroy が、消す plan そのものを誤りにする
# ので、ここへは来ない。これは prevent_destroy が外されたとき（書き換えの誤り、または
# 意図して外した変更をレビューで見落としたとき）の 2 枚目である。
#
# ## 何を見るか
#
# plan の中で、型が github_repository の資源の変更に delete を含むものを探す。アドレスでは
# なく型で見るので、モジュールへ移すなどしてアドレスが変わっても取りこぼさない。
# terraform_data の作り直し（delete と create）は gh api を打ち直すだけなので対象にしない。
#
# 使い方:
#   bash scripts/terraform-refuse-destroy.sh <terraform のディレクトリ> <plan ファイル>
#
# 終了コード: 0 = 消す変更なし / 1 = 消す変更あり / 2 = 引数の誤り・plan を読めない
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "使い方: bash scripts/terraform-refuse-destroy.sh <terraform のディレクトリ> <plan ファイル>" >&2
  exit 2
fi
dir="$1"
plan="$2"

for cmd in terraform jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[refuse-destroy] $cmd が見つかりません" >&2; exit 2; }
done

# show -json は plan ファイルを読むだけで、provider の資格情報は要らない。
json="$(terraform -chdir="$dir" show -json "$plan")" || {
  echo "[refuse-destroy] plan を読めません: $dir/$plan" >&2
  exit 2
}

bad="$(printf '%s\n' "$json" | jq -r '
  .resource_changes[]?
  | select(.type == "github_repository")
  | select(.change.actions | index("delete"))
  | .address')" || {
  echo "[refuse-destroy] plan の JSON を解釈できません" >&2
  exit 2
}

if [[ -n "$bad" ]]; then
  echo "::error::公開リポジトリを消す・作り直す plan です。apply しません:"
  printf '%s\n' "$bad"
  exit 1
fi
echo "[refuse-destroy] 公開リポジトリを消す変更はありません"
