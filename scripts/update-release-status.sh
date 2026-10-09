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

# gh api -i の状態（HTTP の番号）を返す。エラー文の文面には頼らない。
# check-repo-security.sh の fetch と同じく、端末向けの整形・色付け（GH_FORCE_TTY）を外し、
# 改行の CR を除いてから 1 行目を読む。
http_status() {
  local out
  out="$(env -u GH_FORCE_TTY NO_COLOR=1 gh api -i "$1" 2>/dev/null)" || true
  printf '%s\n' "$out" | tr -d '\r' | awk 'NR == 1 && $1 ~ /^HTTP\// { print $2 }'
}

# DCB と devcontainer-host は GitHub Release で配布するため、最新 Release のタグを正とする。
# 404 は「Release が無い」だけでなく「リポジトリが無い」でも返るので、404 のときは
# リポジトリ自体があるかを確かめ、無ければ止まる（リポジトリ名の誤りを「未公開」と書かない）。
get_latest_release() {
  local repo="$1" status tag
  status="$(http_status "repos/$OWNER/$repo/releases/latest")"
  case "$status" in
    200)
      # タグ名は本文を切り出さず、--jq で別に取る（-i の出力の形に依存しない）
      tag="$(env -u GH_FORCE_TTY NO_COLOR=1 gh api "repos/$OWNER/$repo/releases/latest" --jq '.tag_name // empty' 2>/dev/null)" || tag=""
      [[ -n "$tag" ]] || fail_read "$OWNER/$repo の最新の Release" "タグ名が取れない"
      printf '%s' "$tag"
      ;;
    404)
      status="$(http_status "repos/$OWNER/$repo")"
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
  names="$(env -u GH_FORCE_TTY NO_COLOR=1 gh api --paginate "repos/$OWNER/$repo/tags" --jq '.[].name' 2>/dev/null)" \
    || fail_read "$OWNER/$repo のタグの一覧" "gh api が失敗した"
  out="$(printf '%s\n' "$names" | awk '/^v[0-9]+\.[0-9]+\.[0-9]+$/' | sort -V | tail -1)"
  [[ -n "$out" ]] && printf '%s' "$out" || printf '<none>'
}

DCB_TAG="$(get_latest_release devcontainer-bootstrap)"
HOST_TAG="$(get_latest_release devcontainer-host)"
PLAYBOOK_TAG="$(get_latest_semver_tag ai-playbook)"

# 未公開（Release / タグが無い）のとき「<none> まで公開済み」と出すと、公開済みと読める。
# 3 つとも、未公開であることが分かる表示にする。$1 はリポジトリ名、$2 は版、$3 は無いときの理由。
status_table() { if [[ "$2" == "<none>" ]]; then printf '%s は未公開（%s）' "$OWNER/$1" "$3"; else printf '%s で %s まで公開済み' "$OWNER/$1" "$2"; fi; }
# shellcheck disable=SC2016  # ` は Markdown のコードの記号として文字どおり出す
status_list()  { if [[ "$2" == "<none>" ]]; then printf '`%s` は未公開（%s）' "$OWNER/$1" "$3"; else printf '`%s` で `%s` まで公開済み' "$OWNER/$1" "$2"; fi; }

BLOCK_FILE="$(mktemp "${TMPDIR:-/tmp}/release-status-block.XXXXXX")"
cat >"$BLOCK_FILE" <<EOF
| パッケージ | 配布状態 |
|---|---|
| devcontainer-bootstrap | $(status_table devcontainer-bootstrap "$DCB_TAG" "Release なし") |
| devcontainer-host | $(status_table devcontainer-host "$HOST_TAG" "Release なし") |
| ai-playbook | $(status_table ai-playbook "$PLAYBOOK_TAG" "タグなし") |

リリース実行手順は [docs/release/RELEASE_EXECUTION_RUNBOOK.md](docs/release/RELEASE_EXECUTION_RUNBOOK.md) を参照する。

### リリース状況

- \`devcontainer-bootstrap\`: $(status_list devcontainer-bootstrap "$DCB_TAG" "Release なし")
- \`devcontainer-host\`: $(status_list devcontainer-host "$HOST_TAG" "Release なし")
- \`ai-playbook\`: $(status_list ai-playbook "$PLAYBOOK_TAG" "タグなし")
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
