#!/usr/bin/env bash
# check-repo-security.sh — 脆弱性の報告と通知に関わるリポジトリ設定が有効かを照合する（#394）
#
# ## なぜ要るのか
#
# SECURITY.md は「Security タブの Report a vulnerability から知らせてください」と案内する。
# **案内している窓口が手で切られたり、有効にし忘れたりしたまま、案内だけが残る**と、
# 善意の発見者は公開の issue に書くか、黙るかの二択に戻る。配布先の公開リポジトリでは
# この 3 つを Terraform（infra/github/security.tf。#487）で有効にするが、Private vulnerability
# reporting は provider が扱えず、作成時に gh api を打つだけなので、外で無効にされても
# plan に差分が出ない。このモノレポ自身は Terraform の対象外で、手で有効にする。どちらも
# 「有効であること」の照合はここで行う（.github/project-ai-rules.md「脆弱性の報告と通知」）。
#
# ## 何を見るか
#
# - Private vulnerability reporting（非公開の報告窓口）
# - Dependabot alerts（依存の脆弱性の通知）
# - Dependabot security updates（その修正 PR）
#
# **読めなかったことを「無効」とも「有効」とも読まない。** トークンの権限不足（403）や
# 到達できないことは、設定の乖離ではなく前提の不成立として、別の文面と終了コードで出す。
# 読めない状態を「無効」と報告すると、権限を足すべきところで設定を触りに行く誤りを招く。
#
# ## 前提
#
# - gh と jq が要る
# - Dependabot の 2 つの API は**リポジトリの管理者権限**を要する。fine-grained PAT なら
#   Administration（read）が要る。CI の GITHUB_TOKEN では読めないので、CI のゲートには
#   入れず、持ち主が手元で回す
#
# 使い方:
#   bash scripts/check-repo-security.sh [owner/repo]
#   （省略時は gh repo view が返すリポジトリ）
#
# 終了コード: 0 = 3 つとも有効 / 1 = 無効なものがある（乖離） / 2 = 読めないものがある（前提の不成立）
#   乖離と前提の不成立が両方あるときは 2 を返す（読めない項目は有効かどうか確かめられていない）
set -euo pipefail

say() { printf '[check-repo-security] %s\n' "$*"; }

for cmd in gh jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    say "前提の不成立: $cmd が見つかりません。"
    exit 2
  fi
done

repo="${1:-}"
if [[ -z "$repo" ]]; then
  repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null)" || repo=""
  if [[ -z "$repo" ]]; then
    say "前提の不成立: 照合するリポジトリを決められません（gh repo view が失敗しました）。owner/repo を引数で渡すこと。"
    exit 2
  fi
fi

# 状態コードと本文を両方取る。gh api は 2xx 以外で非 0 を返すが、-i の出力には状態行が
# 残るので、終了コードではなく状態行で読み分ける（vulnerability-alerts は無効を 404 で返す）。
# 結果は STATUS（数字。取れなければ空）と BODY（ヘッダの後の空行より後ろ全部）に入れる。
# 本文は最後の行だけを取らない。JSON が複数行で来ると、最後の行は `}` だけになる。
# gh は端末へ出すとき（GH_FORCE_TTY を含む）、JSON を整形して色付けの制御文字も混ぜるので、
# GH_FORCE_TTY を外し、NO_COLOR を立てて呼ぶ。
STATUS="" BODY=""
fetch() {
  local out
  out="$(env -u GH_FORCE_TTY NO_COLOR=1 gh api -i "$1" 2>/dev/null)" || true
  out="$(printf '%s\n' "$out" | tr -d '\r')"
  STATUS="$(printf '%s\n' "$out" | awk 'NR == 1 && $1 ~ /^HTTP\// { print $2 }')"
  BODY="$(printf '%s\n' "$out" | awk 'in_body { print; next } /^$/ { in_body = 1 }')"
}

drift=0
unknown=0

report_unreadable() {
  local label="$1"
  unknown=1
  case "$STATUS" in
    401 | 403)
      say "前提の不成立: ${label} を読めません（HTTP ${STATUS}）。リポジトリの管理者権限のトークンが要ります（fine-grained PAT なら Administration: read）。"
      ;;
    "")
      say "前提の不成立: ${label} を読めません（応答がありません）。gh の認証と到達性を確かめること。"
      ;;
    *)
      say "前提の不成立: ${label} を読めません（HTTP ${STATUS}）。"
      ;;
  esac
}

# 一覧の前に、リポジトリそのものに管理者として届くかを見る。届かない 404 を
# 「vulnerability-alerts が無効」の 404 と取り違えないため。
fetch "repos/${repo}"
if [[ "$STATUS" != "200" ]]; then
  report_unreadable "リポジトリ ${repo}"
  exit 2
fi
if [[ "$(jq -r '.permissions.admin // false' <<<"$BODY" 2>/dev/null)" != "true" ]]; then
  say "前提の不成立: ${repo} の管理者権限がありません。持ち主のトークンで回すこと。"
  exit 2
fi

# $1 = 表示名 / $2 = API のパス。{"enabled": true|false} を返す API を読む。
check_enabled_flag() {
  local label="$1" path="$2" enabled
  fetch "$path"
  if [[ "$STATUS" != "200" ]]; then
    report_unreadable "$label"
    return
  fi
  enabled="$(jq -r 'if type == "object" and (.enabled | type) == "boolean" then .enabled else "invalid" end' <<<"$BODY" 2>/dev/null)" || enabled="invalid"
  case "$enabled" in
    true) say "OK    ${label} は有効です" ;;
    false)
      say "FAIL  ${label} が無効です"
      drift=1
      ;;
    *)
      say "前提の不成立: ${label} の応答を読めません（enabled が真偽値ではありません）。"
      unknown=1
      ;;
  esac
}

check_enabled_flag "Private vulnerability reporting" "repos/${repo}/private-vulnerability-reporting"

# vulnerability-alerts は本文を持たず、有効なら 204、無効なら 404 を返す。
fetch "repos/${repo}/vulnerability-alerts"
case "$STATUS" in
  204) say "OK    Dependabot alerts は有効です" ;;
  404)
    say "FAIL  Dependabot alerts が無効です"
    drift=1
    ;;
  *) report_unreadable "Dependabot alerts" ;;
esac

check_enabled_flag "Dependabot security updates" "repos/${repo}/automated-security-fixes"

if [[ "$unknown" -ne 0 ]]; then
  say "読めない設定があります。有効かどうかを確かめられていません。"
  exit 2
fi
if [[ "$drift" -ne 0 ]]; then
  say "無効な設定があります。有効にする手順は .github/project-ai-rules.md「脆弱性の報告と通知」にあります。"
  exit 1
fi
say "${repo}: 3 つとも有効です"
