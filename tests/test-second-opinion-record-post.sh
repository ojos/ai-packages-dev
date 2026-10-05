#!/usr/bin/env bash
# scripts/second-opinion-record.sh post を、gh を差し替えて回す（#440）。
#
# 確認側（second-opinion-gate.yml）は、書き手が PR の作者と一致するコメントしか
# 記録として数えない（#370 / #436）。post がこれと食い違うと、次の 2 つが起きる。
#
#   - 作者以外が post すると、成功と表示されるが確認側には使えない記録になる
#   - 作者以外が先に同じ印を書いていると、作者の post が「投稿済み」で終わり、
#     確認側は赤のままになる
#
# ここでは、post が「確認側が数える記録を作れたときだけ成功する」ことを確かめる。
#
#   gh … 環境変数 GH_ME（認証しているアカウント）・GH_AUTHOR（PR の作者）と、
#        FIXTURES の comments.json に --jq の式を本物の jq で当てて返す。
#        **スクリプトに書いた jq の式もそのまま確かめる。** pr comment は投稿した
#        ことを posted に記録するだけ

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-second-opinion-record-post"

command -v jq >/dev/null 2>&1 || { echo "error: jq がありません" >&2; exit 1; }

# スクリプトは自分の置き場所のリポジトリで動く（冒頭で親ディレクトリへ cd する）ので、
# 記録を持つ一時リポジトリへ写して回す。SCRIPT_SRC は修正前の版で回して、
# 試験が落ちることを確かめるときに使う。
SCRIPT_SRC="${SCRIPT_SRC:-$REPO_ROOT/scripts/second-opinion-record.sh}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/so-record-post.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
# 偽の gh。
set -euo pipefail
case "$1 ${2-}" in
  "pr view")
    case "$*" in
      *"--json number"*) echo 1 ;;
      *"--json author"*) [ -n "${GH_AUTHOR-}" ] || exit 1; echo "$GH_AUTHOR" ;;
      *) echo "gh stub: 知らない pr view: $*" >&2; exit 1 ;;
    esac
    ;;
  "api user") [ -n "${GH_ME-}" ] || exit 1; echo "$GH_ME" ;;
  "api --paginate")
    expr=""
    while [ $# -gt 0 ]; do
      case "$1" in --jq) expr="$2"; shift ;; esac
      shift
    done
    jq -r "$expr" "$FIXTURES/comments.json"
    ;;
  "pr comment") echo posted >> "$FIXTURES/posted" ;;
  *) echo "gh stub: 知らない呼び出し: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/gh"

# 記録を持つ git リポジトリを 1 つ作る（post の前段の verify を通すため）。
REPO="$WORK/repo"
git init -q "$REPO"
mkdir -p "$REPO/scripts"
cp "$SCRIPT_SRC" "$REPO/scripts/second-opinion-record.sh"
git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
SCRIPT="$REPO/scripts/second-opinion-record.sh"
SHA="$(git -C "$REPO" rev-parse HEAD)"
( cd "$REPO" && printf 'LGTM\n' | bash "$SCRIPT" save --engine fake --verdict pass --scope "range:$SHA..$SHA" --runs 1 ) >/dev/null \
  || { echo "error: 記録を作れません" >&2; exit 1; }

comment() { printf '{"id":%s,"user":{"login":"%s"},"body":"<!-- second-opinion sha=%s -->\\nLGTM"}' "$1" "$2" "$SHA"; }

# case_ <名前> <期待する終了（0 / 1）> <投稿されるか（yes / no）> <GH_ME> <GH_AUTHOR> <comments の JSON>
case_() {
  local name="$1" want_rc="$2" want_posted="$3" me="$4" author="$5" comments="$6"
  local fx="$WORK/fx" rc posted
  rm -rf "$fx"; mkdir -p "$fx"
  printf '%s' "$comments" > "$fx/comments.json"
  ( cd "$REPO" && PATH="$WORK/bin:$PATH" FIXTURES="$fx" GH_ME="$me" GH_AUTHOR="$author" \
      bash "$SCRIPT" post ) >"$fx/out" 2>&1
  rc=$?
  posted=no; [ -f "$fx/posted" ] && posted=yes
  it "$name"
  if [[ "$rc" == "$want_rc" && "$posted" == "$want_posted" ]]; then
    pass
  else
    fail "want rc=$want_rc posted=$want_posted / got rc=$rc posted=$posted: $(tr '\n' ' ' < "$fx/out")"
  fi
}

case_ "作者が post し、記録が無ければ投稿する" 0 yes alice alice '[]'
case_ "作者の記録が既に在れば、二重に投稿せず成功する" 0 no alice alice "[$(comment 1 alice)]"
case_ "作者以外（協力者）が書いた同じ印しか無ければ、作者の post は投稿する" 0 yes alice alice "[$(comment 1 helper)]"
case_ "作者以外のアカウントで post すると、投稿せず失敗する" 1 no helper alice '[]'
case_ "認証しているアカウントを読めなければ、投稿せず失敗する" 1 no "" alice '[]'
case_ "PR の作者を読めなければ、投稿せず失敗する" 1 no alice "" '[]'

exit_with_result
