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
#        ことを posted に、`workflow run` の引数を dispatched に記録するだけ
#
# 投稿の直後に、確認側を既定ブランチで手動実行する（定期実行は持たない）ことも確かめる。
# 起こせなければ、手で起こすコマンドを示して非 0 で終わる。

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
  "repo view") [ "${GH_DEFAULT_BRANCH-main}" != "" ] || exit 1; echo "${GH_DEFAULT_BRANCH-main}" ;;
  "api repos/"*)
    # ワークフローの state（無効化の判定）。GH_WF_STATE が空なら読めない扱い
    case "$*" in *"actions/workflows"*)
      [ -n "${GH_WF_STATE-}" ] || exit 1
      echo "$GH_WF_STATE"; exit 0 ;;
    esac
    # 確認側のワークフローが既定ブランチに在るか（contents）。GH_NO_GATE で 404 を返す
    if [ -n "${GH_NO_GATE-}" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    echo second-opinion-gate.yml
    ;;
  "workflow run")
    [ -z "${GH_DISPATCH_FAIL-}" ] || exit 1
    echo "$*" >> "$FIXTURES/dispatched"
    ;;
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
  local want_dispatch="${7-}"   # 期待する workflow run の引数（空なら起こされないこと）
  local fx="$WORK/fx" rc posted dispatched
  rm -rf "$fx"; mkdir -p "$fx"
  printf '%s' "$comments" > "$fx/comments.json"
  ( cd "$REPO" && PATH="$WORK/bin:$PATH" FIXTURES="$fx" GH_ME="$me" GH_AUTHOR="$author" \
      GH_DISPATCH_FAIL="${GH_DISPATCH_FAIL-}" GH_DEFAULT_BRANCH="${GH_DEFAULT_BRANCH-main}" GH_NO_GATE="${GH_NO_GATE-}" GH_WF_STATE="${GH_WF_STATE-}" \
      bash "$SCRIPT" post ) >"$fx/out" 2>&1
  rc=$?
  posted=no; [ -f "$fx/posted" ] && posted=yes
  dispatched=""; [ -f "$fx/dispatched" ] && dispatched="$(tr -d '\n' < "$fx/dispatched")"
  it "$name"
  if [[ "$rc" == "$want_rc" && "$posted" == "$want_posted" && "$dispatched" == "$want_dispatch" ]]; then
    pass
  else
    fail "want rc=$want_rc posted=$want_posted dispatched='$want_dispatch' / got rc=$rc posted=$posted dispatched='$dispatched': $(tr '\n' ' ' < "$fx/out")"
  fi
}

RUN="workflow run second-opinion-gate.yml --ref main"
case_ "作者が post し、記録が無ければ投稿し、既定ブランチで確認側を手動実行する" 0 yes alice alice '[]' "$RUN"
case_ "作者の記録が既に在れば、二重に投稿せず、確認側の手動実行だけ起こして成功する" 0 no alice alice "[$(comment 1 alice)]" "$RUN"
case_ "作者以外（協力者）が書いた同じ印しか無ければ、作者の post は投稿する" 0 yes alice alice "[$(comment 1 helper)]" "$RUN"
case_ "作者以外のアカウントで post すると、投稿せず、手動実行も起こさず失敗する" 1 no helper alice '[]'
case_ "認証しているアカウントを読めなければ、投稿せず失敗する" 1 no "" alice '[]'
case_ "PR の作者を読めなければ、投稿せず失敗する" 1 no alice "" '[]'

# 既定ブランチは固定の名前ではなく、リポジトリから読んだ値を ref に渡す。
GH_DEFAULT_BRANCH=trunk case_ "既定ブランチが main でなければ、その名前を ref に渡す" 0 yes alice alice '[]' "workflow run second-opinion-gate.yml --ref trunk"

# 手動実行を起こせないときは、投稿は済んでいるが非 0 で終わり、手で起こすコマンドを示す。
GH_DISPATCH_FAIL=1 case_ "確認側を手動実行できなければ、非 0 で終わる" 1 yes alice alice '[]'
it "手動実行できなかったときの出力に、手で起こすコマンドが含まれる"
if grep -q 'gh workflow run second-opinion-gate.yml --ref main' "$WORK/fx/out"; then pass; else fail "手で起こすコマンドが出力に無い: $(tr '\n' ' ' < "$WORK/fx/out")"; fi
# ワークフローが無効なら、そうと分かる文言と enable の案内を出して非 0 で終わる。
GH_DISPATCH_FAIL=1 GH_WF_STATE=disabled_manually case_ "手動実行に失敗し state が disabled_manually なら、非 0 で終わる" 1 yes alice alice '[]'
it "無効のとき、無効であることと gh workflow enable の案内が出る"
if grep -q 'disabled_manually' "$WORK/fx/out" && grep -q 'gh workflow enable second-opinion-gate.yml' "$WORK/fx/out"; then pass; else fail "案内が無い: $(tr '\n' ' ' < "$WORK/fx/out")"; fi
GH_DISPATCH_FAIL=1 GH_WF_STATE=active case_ "手動実行に失敗し state が active なら、非 0 で終わる" 1 yes alice alice '[]'
it "active のとき、無効化も候補に挙げた文言が出る"
if grep -q '無効化されている可能性' "$WORK/fx/out" && ! grep -q 'gh workflow enable' "$WORK/fx/out"; then pass; else fail "文言が違う: $(tr '\n' ' ' < "$WORK/fx/out")"; fi
GH_DISPATCH_FAIL=1 case_ "state を読めなくても非 0 で終わる" 1 yes alice alice '[]'
it "state を読めないとき、無効化も候補に挙げた文言が出る"
if grep -q '無効化されている可能性' "$WORK/fx/out"; then pass; else fail "文言が違う: $(tr '\n' ' ' < "$WORK/fx/out")"; fi
GH_DEFAULT_BRANCH= case_ "既定ブランチを読めなければ、非 0 で終わる" 1 yes alice alice '[]'
# 確認側を初めて入れる PR では、既定ブランチにまだワークフローが無い。手動実行は起こさず成功する。
GH_NO_GATE=1 case_ "確認側が既定ブランチに無ければ、手動実行を起こさずに成功する" 0 yes alice alice '[]'

# 起点から索引まで（base:<rev>+staged）の記録は、staged と同じく索引のツリーに紐づく。
# 変更の無い索引は HEAD のツリーと一致するので、その記録は post が投稿できる。
BASE_SCOPE_SHA="$(git -C "$REPO" rev-parse HEAD^{tree})"
( cd "$REPO" && printf 'LGTM\n' | bash "$SCRIPT" save --engine fake --verdict pass --scope "base:$SHA+staged" --runs 1 ) >"$WORK/save-out" 2>&1
save_rc=$?
it "scope が base:<rev>+staged の記録を save できる"
if [[ "$save_rc" == 0 ]] && grep -q "tree=${BASE_SCOPE_SHA:0:12}" "$WORK/save-out"; then pass; else fail "save できない: $(cat "$WORK/save-out")"; fi
it "base:<rev>+staged の記録は、scope と索引のツリーの紐づけを meta に残す"
meta="$(cd "$REPO" && bash "$SCRIPT" show 2>&1)"
if printf '%s' "$meta" | grep "base:$SHA+staged" >/dev/null; then pass; else fail "scope が残っていない: $meta"; fi
case_ "base:<rev>+staged の記録を post が投稿できる（HEAD のツリーと一致するとき）" 0 yes alice alice '[]' "$RUN"
it "起点の無い base:+staged は拒否する"
if ( cd "$REPO" && printf 'LGTM\n' | bash "$SCRIPT" save --engine fake --verdict pass --scope "base:+staged" --runs 1 ) >/dev/null 2>&1; then
  fail "空の起点を受け付けた"
else
  pass
fi

exit_with_result
