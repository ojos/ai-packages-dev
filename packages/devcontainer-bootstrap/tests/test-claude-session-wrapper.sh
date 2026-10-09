#!/usr/bin/env bash
# セッションの宛先名を自動で付ける起動ラッパー（scripts/claude-session-wrapper.sh）と、
# その配線（--with-claude の生成物）を検証する。
#
#   - ラベルありで、名前の形が <ラベル>-<作業ツリー名>-<2桁の16進> になる
#   - 起動のたびに名前が変わる
#   - ラベルなし・既に設定済み・計算の失敗のどれでも、引数がそのまま exec される
#   - --with-claude の生成物に claudeProcessWrapper の配線があり、無いときは配線がない
#   - 生成物の .env.example に SESSION_HOST_LABEL=（値なし）がある
#
# ラッパーは <ラッパー> <本体のパス> <引数…> の形で呼ばれる。本体の代わりに、受け取った
# 引数と CLAUDE_CODE_SESSION_NAME を書き出すスタブを使う。bash 3.2 互換。

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-claude-session-wrapper"

out="$(new_workdir)/out"
run_bootstrap "$out" --with-claude >/dev/null 2>&1
WRAPPER="$out/scripts/claude-session-wrapper.sh"

it "claude-session-wrapper.sh が --with-claude で生成され、実行可能である"
if [[ -f "$WRAPPER" ]]; then assert_mode "$WRAPPER" "755"; else fail "生成されていない: $WRAPPER"; fi

it "構文が正しい"
if bash -n "$WRAPPER" 2>/dev/null; then pass; else fail "syntax error"; fi

it "--with-claude を選ばない生成物には、ラッパーも一覧のスクリプトも出ない"
out_plain="$(new_workdir)/out"
run_bootstrap "$out_plain" >/dev/null 2>&1
if [[ ! -e "$out_plain/scripts/claude-session-wrapper.sh" && ! -e "$out_plain/scripts/session-peers.sh" ]]; then
  pass
else
  fail "ラッパーまたは session-peers.sh が出ている"
fi

# ── スタブとフィクスチャ ──────────────────────────────────────────────────────

WORK="$(new_workdir)"
STUB="$WORK/claude-stub"
cat >"$STUB" <<'STUBEOF'
#!/bin/bash
printf 'NAME=%s\n' "${CLAUDE_CODE_SESSION_NAME-<unset>}"
printf 'ARGC=%s\n' "$#"
for a in "$@"; do printf 'ARG=%s\n' "$a"; done
STUBEOF
chmod +x "$STUB"

# ラッパーを置く場所（scripts/ の 1 つ上が .env の置き場所）と、作業ツリーの名前を持つ git リポジトリ。
mkproject() { # ディレクトリ ラベル（空なら .env を作らない）
  local d="$1" label="$2"
  mkdir -p "$d/scripts"
  cp "$WRAPPER" "$d/scripts/claude-session-wrapper.sh"
  [[ -z "$label" ]] || printf 'SESSION_HOST_LABEL=%s\n' "$label" >"$d/.env"
}
REPO="$WORK/my-repo"
mkdir -p "$REPO"
(cd "$REPO" && git init -q . >/dev/null 2>&1)

# run <プロジェクト> <cwd> [env の指定…] -- <引数…>
run_wrapper() {
  local proj="$1" cwd="$2"; shift 2
  (cd "$cwd" && env -u CLAUDE_CODE_SESSION_NAME -u SESSION_HOST_LABEL "$@" bash "$proj/scripts/claude-session-wrapper.sh" "$STUB" --flag "two words" 2>/dev/null)
}

P1="$WORK/p1"
mkproject "$P1" "lab"

it "ラベルありで、名前が <ラベル>-<作業ツリー名>-<2桁の16進> になる"
res="$(run_wrapper "$P1" "$REPO")"
name="$(printf '%s\n' "$res" | sed -n 's/^NAME=//p')"
if [[ "$name" =~ ^lab-my-repo-[0-9a-f]{2}$ ]]; then pass; else fail "名前=$name"; fi

it "ラベルありでも、本体のパスと引数がそのまま渡る（空白を含む引数も 1 個のまま）"
if [[ "$(printf '%s\n' "$res" | sed -n 's/^ARGC=//p')" == "2" ]] \
  && printf '%s\n' "$res" | command grep -qx 'ARG=--flag' \
  && printf '%s\n' "$res" | command grep -qx 'ARG=two words'; then
  pass
else
  fail "$res"
fi

it "2 回の起動で名前が異なる（16進は起動ごとに変わる。偶然の一致を避けて 30 回まで試す）"
first="$name"
differ=0
for _ in $(seq 1 30); do
  n2="$(run_wrapper "$P1" "$REPO" | sed -n 's/^NAME=//p')"
  if [[ -n "$n2" && "$n2" != "$first" ]]; then differ=1; break; fi
done
if [[ "$differ" -eq 1 ]]; then pass; else fail "30 回起動しても名前が変わらなかった: $first"; fi

it "ラベルに使えない文字は _ に直る"
P2="$WORK/p2"
mkproject "$P2" "ho st/ラベル"
n3="$(run_wrapper "$P2" "$REPO" | sed -n 's/^NAME=//p')"
if [[ "$n3" =~ ^[A-Za-z0-9._-]+-my-repo-[0-9a-f]{2}$ && "$n3" == ho_st_* ]]; then pass; else fail "名前=$n3"; fi

it "ラベルが環境変数にだけあっても使う（.env が無いとき）"
P3="$WORK/p3"
mkproject "$P3" ""
n4="$(cd "$REPO" && env -u CLAUDE_CODE_SESSION_NAME SESSION_HOST_LABEL=envlab bash "$P3/scripts/claude-session-wrapper.sh" "$STUB" 2>/dev/null | sed -n 's/^NAME=//p')"
if [[ "$n4" =~ ^envlab-my-repo-[0-9a-f]{2}$ ]]; then pass; else fail "名前=$n4"; fi

it "ラベルなしなら名前を変えず、引数がそのまま exec される"
res="$(run_wrapper "$P3" "$REPO")"
if [[ "$(printf '%s\n' "$res" | sed -n 's/^NAME=//p')" == "<unset>" && "$(printf '%s\n' "$res" | sed -n 's/^ARGC=//p')" == "2" ]]; then
  pass
else
  fail "$res"
fi

it "ラベルが空文字でも名前を変えない"
P4="$WORK/p4"
mkdir -p "$P4/scripts"
cp "$WRAPPER" "$P4/scripts/claude-session-wrapper.sh"
printf 'SESSION_HOST_LABEL=\n' >"$P4/.env"
res="$(run_wrapper "$P4" "$REPO")"
if [[ "$(printf '%s\n' "$res" | sed -n 's/^NAME=//p')" == "<unset>" ]]; then pass; else fail "$res"; fi

it "CLAUDE_CODE_SESSION_NAME が設定済みなら上書きせず、引数もそのまま exec される"
res="$(cd "$REPO" && CLAUDE_CODE_SESSION_NAME=given-name bash "$P1/scripts/claude-session-wrapper.sh" "$STUB" --flag "two words" 2>/dev/null)"
if [[ "$(printf '%s\n' "$res" | sed -n 's/^NAME=//p')" == "given-name" && "$(printf '%s\n' "$res" | sed -n 's/^ARGC=//p')" == "2" ]]; then
  pass
else
  fail "$res"
fi

it "計算に失敗しても（外部コマンドが使えない）名前を変えず、引数がそのまま exec される"
# PATH を、ラッパーが使う外部コマンドを含まない空のディレクトリにする。本体はパスで直接指定する。
EMPTY_BIN="$WORK/empty-bin"
mkdir -p "$EMPTY_BIN"
res="$(cd "$REPO" && env -u CLAUDE_CODE_SESSION_NAME PATH="$EMPTY_BIN" /bin/bash "$P1/scripts/claude-session-wrapper.sh" "$STUB" --flag "two words" 2>/dev/null)"
if [[ "$(printf '%s\n' "$res" | sed -n 's/^NAME=//p')" == "<unset>" && "$(printf '%s\n' "$res" | sed -n 's/^ARGC=//p')" == "2" ]] \
  && printf '%s\n' "$res" | command grep -qx 'ARG=two words'; then
  pass
else
  fail "$res"
fi

it "git リポジトリの外から起動しても止まらず、cwd の名前で名前を作る"
NOGIT="$WORK/plain-dir"
mkdir -p "$NOGIT"
n5="$(run_wrapper "$P1" "$NOGIT" | sed -n 's/^NAME=//p')"
if [[ "$n5" =~ ^lab-plain-dir-[0-9a-f]{2}$ ]]; then pass; else fail "名前=$n5"; fi

it "引数が無くても止まらない（exec するものが無いだけ）"
(cd "$REPO" && bash "$P1/scripts/claude-session-wrapper.sh" >/dev/null 2>&1)
assert_eq "$?" "0" "終了コード"

# ── 配線（生成物） ────────────────────────────────────────────────────────────

DC="$out/.devcontainer/devcontainer.json"

it "--with-claude の生成物の devcontainer.json が claudeProcessWrapper を絶対パスで配線する"
wired="$(jq -r '.customizations.vscode.settings["claudeCode.claudeProcessWrapper"] // empty' "$DC" 2>/dev/null)"
assert_eq "$wired" "/workspaces/test/scripts/claude-session-wrapper.sh" "配線先"

it "配線先は、生成されたラッパーのパス（/workspaces/<プロジェクト名>/…）に対応する"
if [[ "$wired" == "/workspaces/test/${WRAPPER#"$out"/}" ]]; then pass; else fail "$wired"; fi

it "--with-claude を選ばない生成物には claudeProcessWrapper の配線がない"
if ! command grep -q 'claudeProcessWrapper' "$out_plain/.devcontainer/devcontainer.json"; then pass; else fail "配線が残っている"; fi

it "--with-claude を選ばない生成物の devcontainer.json も JSON として読める"
if jq -e . "$out_plain/.devcontainer/devcontainer.json" >/dev/null 2>&1; then pass; else fail "JSON として読めない"; fi

it "--with-claude の生成物の devcontainer.json が JSON として読める"
if jq -e . "$DC" >/dev/null 2>&1; then pass; else fail "JSON として読めない"; fi

it "--with-claude の生成物の .env.example に SESSION_HOST_LABEL=（値なし）がある"
if command grep -qx 'SESSION_HOST_LABEL=' "$out/.env.example"; then pass; else fail "SESSION_HOST_LABEL= の行が無い"; fi

it "--with-claude を選ばない生成物の .env.example には SESSION_HOST_LABEL が無い"
if ! command grep -q 'SESSION_HOST_LABEL' "$out_plain/.env.example"; then pass; else fail "記入欄が残っている"; fi

it "パッケージの既定値にラベルの値が入っていない（.env.example の値は空）"
val="$(sed -n 's/^SESSION_HOST_LABEL=//p' "$out/.env.example")"
assert_eq "$val" "" "既定値"

exit_with_result
