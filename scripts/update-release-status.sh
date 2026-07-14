#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  bash scripts/update-release-status.sh [--owner <github-owner>] [--readme <path>]

options:
  --owner <owner>   GitHub owner (default: ojos)
  --readme <path>   README path to update (default: README.md)
  -h, --help        Show help

notes:
  - README 内の RELEASE_STATUS 管理ブロックを更新する。
  - 実行には gh 認証と対象リポジトリアクセス権が必要。
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: command not found: $1" >&2
    exit 1
  }
}

OWNER="ojos"
README_PATH="README.md"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)
      OWNER="$2"
      shift 2
      ;;
    --readme)
      README_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd gh
require_cmd awk

[[ -f "$README_PATH" ]] || {
  echo "error: README not found: $README_PATH" >&2
  exit 1
}

get_latest_tag() {
  local repo="$1"
  gh api "repos/$OWNER/$repo/releases/latest" --jq '.tag_name' 2>/dev/null || echo "<none>"
}

DCB_TAG="$(get_latest_tag devcontainer-bootstrap)"
DOTFILES_TAG="$(get_latest_tag ai-dotfiles)"

BLOCK_FILE="$(mktemp)"
cat >"$BLOCK_FILE" <<EOF
| パッケージ | 配布状態 |
|---|---|
| devcontainer-bootstrap | $OWNER/devcontainer-bootstrap で $DCB_TAG まで公開済み |
| dotfiles | $OWNER/ai-dotfiles で $DOTFILES_TAG まで公開済み |

リリース実行手順は各パッケージの \`docs/\` または \`.github/workflows/\` を参照する。

### リリース状況

- \`devcontainer-bootstrap\`: published up to \`$DCB_TAG\` at \`$OWNER/devcontainer-bootstrap\`
- \`dotfiles\`: published up to \`$DOTFILES_TAG\` at \`$OWNER/ai-dotfiles\`
EOF

OUT_FILE="$(mktemp)"
awk -v block_file="$BLOCK_FILE" '
BEGIN {
  while ((getline line < block_file) > 0) {
    block = block line "\n"
  }
}
/<!-- RELEASE_STATUS:START -->/ {
  print
  printf "%s", block
  in_block = 1
  next
}
/<!-- RELEASE_STATUS:END -->/ {
  in_block = 0
  print
  next
}
!in_block { print }
' "$README_PATH" >"$OUT_FILE"

mv "$OUT_FILE" "$README_PATH"
rm -f "$BLOCK_FILE"

echo "[ok] updated release status block in $README_PATH"
echo "[info] devcontainer-bootstrap=$DCB_TAG"
echo "[info] ai-dotfiles=$DOTFILES_TAG"
