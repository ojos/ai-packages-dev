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
  - Release / タグを読めなかったとき（認証・権限・通信の失敗、リポジトリが無い）は、
    README を書き換えずに非 0 で終わる。Release が無い（404）だけを「未公開」として扱う。
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
require_cmd jq

[[ -f "$README_PATH" ]] || {
  echo "error: README not found: $README_PATH" >&2
  exit 1
}

# 読めなかったときは README を書き換えずに止まる（#500）。
#
# 「Release / タグが無い（未公開）」と「読めなかった（認証・権限・通信の失敗、リポジトリが無い）」を
# 区別する。以前はどちらも <none> に倒していたため、公開済みでも API が一時的に失敗すると、
# README に「未公開」と書き込んで正常終了していた。3 つとも読めてから README を書き換えるので、
# どれかで止まれば README は変わらない。
fail_read() {
  echo "error: $1 を読めませんでした（$2）。README は書き換えていません。" >&2
  exit 1
}

# gh api -i の 1 行目（HTTP/x.y NNN ...）から状態の番号を取る。エラー文の文面には頼らない。
http_status() {
  printf '%s\n' "$1" | sed -n '1s#^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*#\1#p'
}

# DCB と devcontainer-host は GitHub Release で配布するため、最新 Release のタグを正とする。
# 404 は「Release が無い」だけでなく「リポジトリが無い」でも返るので、404 のときは
# リポジトリ自体があるかを確かめ、無ければ止まる（リポジトリ名の誤りを「未公開」と書かない）。
get_latest_release() {
  local repo="$1" resp status tag
  # gh は 4xx / 5xx で非 0 終了するが、-i なら状態行と本文を標準出力へ出す。終了コードでは止めず、状態で判定する。
  resp="$(gh api -i "repos/$OWNER/$repo/releases/latest" 2>/dev/null)" || true
  status="$(http_status "$resp")"
  case "$status" in
    200)
      tag="$(printf '%s\n' "$resp" | awk 'b { print } /^\r?$/ { b = 1 }' | jq -r '.tag_name // empty' 2>/dev/null)" || tag=""
      [[ -n "$tag" ]] || fail_read "$OWNER/$repo の最新の Release" "タグ名が取れない"
      printf '%s' "$tag"
      ;;
    404)
      resp="$(gh api -i "repos/$OWNER/$repo" 2>/dev/null)" || true
      status="$(http_status "$resp")"
      [[ "$status" == "200" ]] || fail_read "$OWNER/$repo" "Release が 404 で、リポジトリも読めない（HTTP ${status:-応答なし}）"
      printf '<none>'
      ;;
    *)
      fail_read "$OWNER/$repo の最新の Release" "HTTP ${status:-応答なし}"
      ;;
  esac
}

# ai-playbook は Release を作らずタグのみで配布する。最新の semver タグを正とする。
# tags API はタグを semver 順に返さないため、vX.Y.Z を抽出して sort -V で最大を採る。
# タグの一覧そのものが読めなければ止まる。読めて semver のタグが 1 つも無いときだけ <none>。
get_latest_semver_tag() {
  local repo="$1" names out
  names="$(gh api --paginate "repos/$OWNER/$repo/tags" --jq '.[].name' 2>/dev/null)" \
    || fail_read "$OWNER/$repo のタグの一覧" "gh api が失敗した"
  out="$(printf '%s\n' "$names" | awk '/^v[0-9]+\.[0-9]+\.[0-9]+$/' | sort -V | tail -1)"
  [[ -n "$out" ]] && printf '%s' "$out" || printf '<none>'
}

DCB_TAG="$(get_latest_release devcontainer-bootstrap)"
HOST_TAG="$(get_latest_release devcontainer-host)"
PLAYBOOK_TAG="$(get_latest_semver_tag ai-playbook)"

# 未公開（Release が無い）のとき「<none> まで公開済み」と出すと、公開済みと読める。
# 未公開であることが分かる表示にする。
if [[ "$HOST_TAG" == "<none>" ]]; then
  HOST_TABLE="$OWNER/devcontainer-host は未公開（Release なし）"
  HOST_LIST="\`$OWNER/devcontainer-host\` は未公開（Release なし）"
else
  HOST_TABLE="$OWNER/devcontainer-host で $HOST_TAG まで公開済み"
  HOST_LIST="\`$OWNER/devcontainer-host\` で \`$HOST_TAG\` まで公開済み"
fi

BLOCK_FILE="$(mktemp "${TMPDIR:-/tmp}/release-status-block.XXXXXX")"
cat >"$BLOCK_FILE" <<EOF
| パッケージ | 配布状態 |
|---|---|
| devcontainer-bootstrap | $OWNER/devcontainer-bootstrap で $DCB_TAG まで公開済み |
| devcontainer-host | $HOST_TABLE |
| ai-playbook | $OWNER/ai-playbook で $PLAYBOOK_TAG まで公開済み |

リリース実行手順は [docs/release/RELEASE_EXECUTION_RUNBOOK.md](docs/release/RELEASE_EXECUTION_RUNBOOK.md) を参照する。

### リリース状況

- \`devcontainer-bootstrap\`: \`$OWNER/devcontainer-bootstrap\` で \`$DCB_TAG\` まで公開済み
- \`devcontainer-host\`: $HOST_LIST
- \`ai-playbook\`: \`$OWNER/ai-playbook\` で \`$PLAYBOOK_TAG\` まで公開済み
EOF

OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/release-status-out.XXXXXX")"
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
echo "[info] devcontainer-host=$HOST_TAG"
echo "[info] ai-playbook=$PLAYBOOK_TAG"
