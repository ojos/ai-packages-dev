#!/usr/bin/env bash
set -euo pipefail
echo "[check] bootstrap checks"
# shellcheck は受け入れ検証（scripts/acceptance.sh）が要求する。無いとゲートが
# 通らないため、CLI 群と同じ位置で存在を確認する。手元での apt install に頼ると
# rebuild のたびに消えるので、devcontainer.json の feature で入れている。
for cmd in bash jq gh docker rg shellcheck; do
  command -v "$cmd" >/dev/null 2>&1 && echo "[check] $cmd OK" || echo "[check] $cmd missing"
done

# 認証状態を保持するディレクトリが named volume として実際にマウントされているかを見る。
# 定義したのにマウントされていない状態（compose の編集ミス、devcontainer.json が別
# サービスを指している等）は、CLI が入っていて動くぶん気づきにくく、rebuild のたびに
# 静かにログインが消える形で表面化する。
#
# /proc/mounts を引くのは、mountpoint コマンドが無いベースイメージがあるため。
# 判定できない環境（/proc/mounts を読めない等）は「不明」として素通りさせる。
check_mounted() {
  local dir="$1" vol="$2"
  if [[ ! -r /proc/mounts ]]; then
    echo "[check] $vol unknown (cannot read /proc/mounts)"
    return 0
  fi
  if awk -v d="$dir" '$2 == d { found = 1 } END { exit found ? 0 : 1 }' /proc/mounts; then
    echo "[check] $vol mounted at $dir"
  else
    echo "[check] WARN: $vol not mounted at $dir (認証状態は rebuild で失われます)" >&2
  fi
}
check_mounted "/home/vscode/.config/gh" "gh-storage"
check_mounted "/home/vscode/.claude" "claude-storage"
check_mounted "/home/vscode/.gemini" "gemini-storage"
command -v node >/dev/null 2>&1 && echo "[check] node OK" || echo "[check] node missing"
command -v claude >/dev/null 2>&1 && echo "[check] claude OK" || echo "[check] claude missing"
command -v gemini >/dev/null 2>&1 && echo "[check] gemini OK" || echo "[check] gemini missing"