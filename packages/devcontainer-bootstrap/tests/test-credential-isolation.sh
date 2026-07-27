#!/usr/bin/env bash
# test-credential-isolation.sh — ホスト資格情報がコンテナへ暗黙に流入しないことを検証する。
#
# 背景:
#   生成物は GitHub トークン / オーナー / git identity / Gemini API キーを remoteEnv の
#   ${localEnv:...} でホストから注入していた。この構造では、ホスト側と .env に別の値が
#   入っていると、.env を読まない文脈でだけ黙ってホスト側が使われる。実際に別アカウントの
#   PAT が git credential fill から警告なく返る事故が起きた。
#
#   ここでは「注入経路が生成物に存在しないこと」と「廃止フラグが黙殺されないこと」を
#   検証する。前者だけだと、フラグを受け付けたまま無視する実装で通ってしまい、
#   利用者は指定したつもりのまま別の資格情報を使い続ける。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-credential-isolation"

out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
DC="$out/.devcontainer/devcontainer.json"

# ── remoteEnv は作業ディレクトリの受け渡しだけを担う ──────────────────────────

it "remoteEnv のキーが LOCAL_WORKSPACE_FOLDER のみである"
keys="$(jq -r '.remoteEnv | keys | join(",")' "$DC" 2>/dev/null)"
assert_eq "$keys" "LOCAL_WORKSPACE_FOLDER" "remoteEnv のキー集合"

it "devcontainer.json に localEnv 参照が残っていない"
# localWorkspaceFolder（作業ディレクトリのパス）は資格情報ではないので対象外。
if grep -q 'localEnv:' "$DC"; then
  fail "localEnv 参照が残っている: $(grep -o 'localEnv:[A-Za-z0-9_]*' "$DC" | tr '\n' ' ')"
else
  pass
fi

it "AI ツールを選んでも remoteEnv は増えない"
out2="$(new_workdir)/p2"
run_bootstrap "$out2" --with-claude --with-gemini --with-copilot >/dev/null 2>&1
keys2="$(jq -r '.remoteEnv | keys | join(",")' "$out2/.devcontainer/devcontainer.json" 2>/dev/null)"
assert_eq "$keys2" "LOCAL_WORKSPACE_FOLDER" "--with-* 指定時の remoteEnv のキー集合"

# ── トークン供給を前提としたスクリプトを配らない ──────────────────────────────

it "github-account-switch.sh が生成されない"
assert_file_absent "$out/scripts/github-account-switch.sh"

it "生成物に github-account-switch.sh への参照が残っていない"
refs="$(grep -rl 'github-account-switch' "$out" 2>/dev/null || true)"
if [[ -z "$refs" ]]; then pass; else fail "参照が残っている: $refs"; fi

it "生成物に GITHUB_TOKEN_<PROFILE> の環境変数契約が残っていない"
hits="$(grep -rlE 'GITHUB_TOKEN_[A-Z]|GITHUB_OWNER_[A-Z]' "$out" 2>/dev/null || true)"
if [[ -z "$hits" ]]; then pass; else fail "契約が残っている: $hits"; fi

# ── 廃止フラグは黙殺せず停止する ──────────────────────────────────────────────

assert_deprecated_flag() {
  local flag="$1"; shift
  local dir output rc
  dir="$(new_workdir)/dep"
  output="$(run_bootstrap "$dir" "$flag" "$@" 2>&1)"
  rc=$?
  if [[ "$rc" -eq 0 ]]; then
    fail "$flag が受理された（非ゼロ終了しない）"
    return
  fi
  case "$output" in
    *"$flag は廃止されました"*) ;;
    *) fail "$flag の廃止を告げるメッセージがない: $(printf '%s' "$output" | head -c 200)"; return ;;
  esac
  # 生成が始まる前に停止すること（部分生成を残さない）。
  if [[ -e "$dir" ]]; then
    fail "$flag の指定で出力ディレクトリが作られた: $dir"
  else
    pass
  fi
}

it "--github-profiles は廃止フラグとして停止する"
assert_deprecated_flag --github-profiles primary,secondary

it "--gemini-key-env は廃止フラグとして停止する"
assert_deprecated_flag --gemini-key-env MY_GEMINI_KEY

it "usage に廃止フラグが載っていない"
usage_out="$(bash "$BOOTSTRAP" --help 2>&1)"
case "$usage_out" in
  *--github-profiles*|*--gemini-key-env*) fail "usage に廃止フラグが残っている" ;;
  *) pass ;;
esac

exit_with_result
