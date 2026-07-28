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

# DCB は GitHub Release で配布するため、最新 Release のタグを正とする。
get_latest_release() {
  local repo="$1" out
  # 404（Release 未作成）や権限エラー時、gh は本文を stdout に出しつつ非ゼロ終了する。
  # コマンド置換がその本文を拾わないよう、代入の失敗で明示的に空へ倒す。
  out="$(gh api "repos/$OWNER/$repo/releases/latest" --jq '.tag_name' 2>/dev/null)" || out=""
  [[ -n "$out" ]] && printf '%s' "$out" || printf '<none>'
}

# ai-playbook は Release を作らずタグのみで配布する。最新の semver タグを正とする。
# tags API はタグを semver 順に返さないため、vX.Y.Z を抽出して sort -V で最大を採る。
get_latest_semver_tag() {
  local repo="$1" out
  out="$(gh api --paginate "repos/$OWNER/$repo/tags" --jq '.[].name' 2>/dev/null \
        | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)" || out=""
  [[ -n "$out" ]] && printf '%s' "$out" || printf '<none>'
}

DCB_TAG="$(get_latest_release devcontainer-bootstrap)"
PLAYBOOK_TAG="$(get_latest_semver_tag ai-playbook)"

BLOCK_FILE="$(mktemp)"
cat >"$BLOCK_FILE" <<EOF
| パッケージ | 配布状態 |
|---|---|
| devcontainer-bootstrap | $OWNER/devcontainer-bootstrap で $DCB_TAG まで公開済み |
| ai-playbook | $OWNER/ai-playbook で $PLAYBOOK_TAG まで公開済み |

リリース実行手順は [docs/release/RELEASE_EXECUTION_RUNBOOK.md](docs/release/RELEASE_EXECUTION_RUNBOOK.md) を参照する。

### リリース状況

- \`devcontainer-bootstrap\`: \`$OWNER/devcontainer-bootstrap\` で \`$DCB_TAG\` まで公開済み
- \`ai-playbook\`: \`$OWNER/ai-playbook\` で \`$PLAYBOOK_TAG\` まで公開済み
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
echo "[info] ai-playbook=$PLAYBOOK_TAG"
