#!/bin/bash

# .env ファイルが存在する場合に環境変数を読み込む
# このスクリプトにより、プロジェクト固有の環境変数で remoteEnv 設定を上書きできる
#
# 使い方:
#   bash scripts/load-env.sh          # サブプロセスとして実行
#   source scripts/load-env.sh        # 現在のシェルへ読み込み（環境変数反映に推奨）
#
# 動作:
#   - プロジェクトルートに .env がある場合、`set -a` で全変数を export して読み込む
#   - .env の変数は既存環境変数より優先される（プロジェクト優先）
#   - .env がない場合はエラーにせず継続する

load_env_vars() {
  if [ -f .env ]; then
    # set -a: 以降の変数代入を自動 export
    # set +a: 読み込み後に通常動作へ戻す
    set -a
    source .env
    set +a
  fi
}

# source 実行時は現在シェルで関数を実行
# サブプロセス実行時は子プロセス環境に対して反映
load_env_vars
