#!/usr/bin/env bash
# セッションの宛先名を自動で付ける起動ラッパー（scripts/claude-session-wrapper.sh）と、
# その配線（--with-claude の生成物）を検証する。
#
#   - ラベルありで、名前の形が <ラベル>-<作業ツリー名>-<$$ の 16 進> になる
#   - 起動のたびに名前が変わる
#   - ラベルなし・既に設定済み・計算の失敗のどれでも、引数がそのまま exec される
#   - export 記法・CRLF・git worktree でも、ラッパーと /peers の署名が同じラベルを返す
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
PEERS="$out/scripts/session-peers.sh"

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
printf 'PIDHEX=%x\n' "$$"
for a in "$@"; do printf 'ARG=%s\n' "$a"; done
STUBEOF
chmod +x "$STUB"

# field <キー> <スタブの出力> : KEY=値 の行から値を取り出す。
field() { printf '%s\n' "$2" | sed -n "s/^$1=//p"; }

# ラッパーと session-peers.sh を置く場所（scripts/ の 1 つ上が .env の置き場所）。
# 引数が 2 つなら（空文字でも）.env を書く。
mkproject() { # ディレクトリ [ラベル]
  local d="$1"
  mkdir -p "$d/scripts"
  cp "$WRAPPER" "$PEERS" "$d/scripts/"
  if [[ "$#" -ge 2 ]]; then printf 'SESSION_HOST_LABEL=%s\n' "$2" >"$d/.env"; fi
}
REPO="$WORK/my-repo"
mkdir -p "$REPO"
(cd "$REPO" && git init -q . >/dev/null 2>&1)

# run_wrapper <プロジェクト> <cwd> [env の指定…]
run_wrapper() {
  local proj="$1" cwd="$2"; shift 2
  (cd "$cwd" && env -u CLAUDE_CODE_SESSION_NAME -u SESSION_HOST_LABEL "$@" bash "$proj/scripts/claude-session-wrapper.sh" "$STUB" --flag "two words" 2>/dev/null)
}

# whoami_label <プロジェクト> <cwd> : /peers の署名の「場所」の値。
whoami_label() {
  local sig
  sig="$(cd "$2" && env -u SESSION_HOST_LABEL SESSION_PEERS_SELF_PID=999999 bash "$1/scripts/session-peers.sh" whoami 2>/dev/null)"
  sig="${sig#*場所: }"
  printf '%s' "${sig%% |*}"
}

P1="$WORK/p1"
mkproject "$P1" "lab"

it "ラベルありで、名前が <ラベル>-<作業ツリー名>-<ラッパーの PID の 16 進> になる"
res="$(run_wrapper "$P1" "$REPO")"
name="$(field NAME "$res")"
if [[ "$name" == "lab-my-repo-$(field PIDHEX "$res")" ]]; then pass; else fail "名前=$name PIDHEX=$(field PIDHEX "$res")"; fi

it "ラベルありでも、本体のパスと引数がそのまま渡る（空白を含む引数も 1 個のまま）"
if [[ "$(field ARGC "$res")" == "2" ]] \
  && printf '%s\n' "$res" | command grep -qx 'ARG=--flag' \
  && printf '%s\n' "$res" | command grep -qx 'ARG=two words'; then
  pass
else
  fail "$res"
fi

it "別のプロセスで起動すると、名前が異なる（末尾はラッパー自身の PID の 16 進）"
first="$name"
n2="$(field NAME "$(run_wrapper "$P1" "$REPO")")"
if [[ -n "$n2" && "$n2" != "$first" ]]; then pass; else fail "名前が同じ: $first / $n2"; fi

it "ラベルに使えない文字は _ に直る"
P2="$WORK/p2"
mkproject "$P2" "ho st/ラベル"
n3="$(field NAME "$(run_wrapper "$P2" "$REPO")")"
if [[ "$n3" =~ ^[A-Za-z0-9._-]+-my-repo-[0-9a-f]+$ && "$n3" == ho_st_* ]]; then pass; else fail "名前=$n3"; fi

it "ラベルが環境変数にだけあっても使う（.env が無いとき）"
P3="$WORK/p3"
mkproject "$P3"
n4="$(field NAME "$(run_wrapper "$P3" "$REPO" SESSION_HOST_LABEL=envlab)")"
if [[ "$n4" =~ ^envlab-my-repo-[0-9a-f]+$ ]]; then pass; else fail "名前=$n4"; fi

it ".env と環境変数の両方にあれば .env が先"
n4b="$(field NAME "$(run_wrapper "$P1" "$REPO" SESSION_HOST_LABEL=envlab)")"
if [[ "$n4b" =~ ^lab-my-repo-[0-9a-f]+$ ]]; then pass; else fail "名前=$n4b"; fi

it "ラベルなしなら名前を変えず、引数がそのまま exec される"
res="$(run_wrapper "$P3" "$REPO")"
if [[ "$(field NAME "$res")" == "<unset>" && "$(field ARGC "$res")" == "2" ]]; then pass; else fail "$res"; fi

it "ラベルが空文字でも名前を変えない"
P4="$WORK/p4"
mkproject "$P4" ""
res="$(run_wrapper "$P4" "$REPO")"
assert_eq "$(field NAME "$res")" "<unset>" "名前"

it "CLAUDE_CODE_SESSION_NAME が設定済みなら上書きせず、引数もそのまま exec される"
res="$(cd "$REPO" && CLAUDE_CODE_SESSION_NAME=given-name bash "$P1/scripts/claude-session-wrapper.sh" "$STUB" --flag "two words" 2>/dev/null)"
if [[ "$(field NAME "$res")" == "given-name" && "$(field ARGC "$res")" == "2" ]]; then pass; else fail "$res"; fi

it "計算に失敗しても（作業ツリー名を決められない）名前を変えず、引数がそのまま exec される"
# PATH を空のディレクトリにして git を使えなくし、cwd を / にする。作業ツリー名が空になり、
# 名前を計算できない。本体はパスで直接指定する。
EMPTY_BIN="$WORK/empty-bin"
mkdir -p "$EMPTY_BIN"
res="$(cd / && env -u CLAUDE_CODE_SESSION_NAME PATH="$EMPTY_BIN" /bin/bash "$P1/scripts/claude-session-wrapper.sh" "$STUB" --flag "two words" 2>/dev/null)"
if [[ "$(field NAME "$res")" == "<unset>" && "$(field ARGC "$res")" == "2" ]] \
  && printf '%s\n' "$res" | command grep -qx 'ARG=two words'; then
  pass
else
  fail "$res"
fi

it "git リポジトリの外から起動しても止まらず、cwd の名前で名前を作る"
NOGIT="$WORK/plain-dir"
mkdir -p "$NOGIT"
n5="$(field NAME "$(run_wrapper "$P1" "$NOGIT")")"
if [[ "$n5" =~ ^lab-plain-dir-[0-9a-f]+$ ]]; then pass; else fail "名前=$n5"; fi

it "引数が無くても止まらない（exec するものが無いだけ）"
(cd "$REPO" && bash "$P1/scripts/claude-session-wrapper.sh" >/dev/null 2>&1)
assert_eq "$?" "0" "終了コード"

# ── ラッパーと /peers の署名が、同じ読み方でラベルを返す ──────────────────────

it "read_host_label の本体が、ラッパーと session-peers.sh で一致する"
extract_fn() { awk '/^read_host_label\(\) \{/ { inside = 1 } inside { print } inside && /^}/ { exit }' "$1"; }
body_w="$(extract_fn "$WRAPPER")"
body_p="$(extract_fn "$PEERS")"
if [[ -n "$body_w" && "$body_w" == "$body_p" ]]; then pass; else fail "本体が食い違う（または抽出できない）"; fi

# agree <名前> <.env に書く生の内容（printf の書式）> <期待するラベル>
agree() {
  local label="$1" raw="$2" want="$3" d got_w got_p
  d="$WORK/agree-$label"
  mkproject "$d"
  # shellcheck disable=SC2059
  printf "$raw" >"$d/.env"
  got_w="$(field NAME "$(run_wrapper "$d" "$REPO")")"
  got_w="${got_w%-my-repo-*}"
  got_p="$(whoami_label "$d" "$REPO")"
  it "ラッパーと whoami が同じラベルを返す（$label）"
  if [[ "$got_w" == "$want" && "$got_p" == "$want" ]]; then pass; else fail "ラッパー=$got_w whoami=$got_p 期待=$want"; fi
}
agree export 'export SESSION_HOST_LABEL=exp\n' exp
agree crlf 'SESSION_HOST_LABEL=crlf\r\n' crlf
agree quoted 'SESSION_HOST_LABEL="quo"\n' quo
agree spaced '  SESSION_HOST_LABEL=  sp  \n' sp
agree last-wins 'SESSION_HOST_LABEL=first\nSESSION_HOST_LABEL=second\n' second

it "git worktree から実行すると、本体の作業コピーの .env へ回り込み、ラッパーと whoami が同じラベルを返す"
MAIN="$WORK/main-repo"
WTREE="$WORK/main-wt"
mkproject "$MAIN"
(
  cd "$MAIN" || exit 1
  git init -q . 2>/dev/null
  git config user.name test
  git config user.email test@example.com
  git config commit.gpgsign false
  git add scripts
  git commit -q -m init
  git worktree add -q "$WTREE" -b wt-branch
) >/dev/null 2>&1
printf 'SESSION_HOST_LABEL=mainlab\n' >"$MAIN/.env"
got_w="$(field NAME "$(run_wrapper "$WTREE" "$WTREE")")"
got_p="$(whoami_label "$WTREE" "$WTREE")"
if [[ "$got_w" =~ ^mainlab-main-wt-[0-9a-f]+$ && "$got_p" == "mainlab" ]]; then pass; else fail "ラッパー=$got_w whoami=$got_p"; fi

# ── 起動役（作業ツリーの外の固定パス。onCreateCommand と on-attach.sh が設置する） ─────────────────

FAKE_HOME="$WORK/fake-home"
LAUNCHER="$WORK/launcher-bin/claude-session-launcher"
mkdir -p "$FAKE_HOME"
run_on_attach() {
  (cd "$out" && HOME="$FAKE_HOME" GIT_CONFIG_GLOBAL="$FAKE_HOME/.gitconfig" CLAUDE_SESSION_LAUNCHER="$LAUNCHER" bash scripts/on-attach.sh 2>&1)
}

it "on-attach.sh が起動役を設置する（実行可能。作業ツリーの外のパス）"
attach1="$(run_on_attach)"
if [[ -x "$LAUNCHER" ]] && printf '%s' "$attach1" | command grep -q 'installed Claude Code launcher'; then pass; else fail "$attach1"; fi

it "on-attach.sh の設置は冪等である（2 回目は何も書き直さない）"
inode1="$(ls -i "$LAUNCHER")"
sum1="$(cksum <"$LAUNCHER")"
attach2="$(run_on_attach)"
inode2="$(ls -i "$LAUNCHER")"
sum2="$(cksum <"$LAUNCHER")"
if [[ "$inode1" == "$inode2" && "$sum1" == "$sum2" ]] && ! printf '%s' "$attach2" | command grep -q 'installed Claude Code launcher'; then pass; else fail "inode $inode1->$inode2 sum $sum1->$sum2"; fi

it "起動役を壊されていても、on-attach.sh が元の内容へ戻す"
printf '#!/bin/sh\nexit 9\n' >"$LAUNCHER"
run_on_attach >/dev/null
if [[ "$(cksum <"$LAUNCHER")" == "$sum1" ]]; then pass; else fail "戻っていない"; fi

it "--with-claude を選ばない生成物の on-attach.sh は、起動役を設置しない"
NOCLAUDE_LAUNCHER="$WORK/no-claude-bin/claude-session-launcher"
(cd "$out_plain" && HOME="$FAKE_HOME" GIT_CONFIG_GLOBAL="$FAKE_HOME/.gitconfig" CLAUDE_SESSION_LAUNCHER="$NOCLAUDE_LAUNCHER" bash scripts/on-attach.sh >/dev/null 2>&1)
if [[ ! -e "$NOCLAUDE_LAUNCHER" ]]; then pass; else fail "設置された"; fi

it "on-attach.sh --install-launcher は、起動役の設置だけを行う（rc 注入など他の処理を走らせない）"
ONLY_HOME="$WORK/only-home"
ONLY_LAUNCHER="$WORK/only-bin/claude-session-launcher"
mkdir -p "$ONLY_HOME"
only_out="$(cd "$out" && HOME="$ONLY_HOME" GIT_CONFIG_GLOBAL="$ONLY_HOME/.gitconfig" CLAUDE_SESSION_LAUNCHER="$ONLY_LAUNCHER" bash scripts/on-attach.sh --install-launcher 2>&1)"
only_rc=$?
if [[ "$only_rc" == "0" && -x "$ONLY_LAUNCHER" && ! -e "$ONLY_HOME/.bashrc" && ! -e "$ONLY_HOME/.zshrc" && ! -e "$ONLY_HOME/.gitconfig" ]] \
  && ! printf '%s' "$only_out" | command grep -q 'bootstrap active'; then
  pass
else
  fail "rc=$only_rc $only_out"
fi

printf 'SESSION_HOST_LABEL=viaL\n' >"$out/.env"
(cd "$out" && git init -q . >/dev/null 2>&1)

it "起動役は、ラッパーがあるときはそれを呼ぶ（名前が付き、引数がそのまま渡る）"
res="$(cd "$out" && env -u CLAUDE_CODE_SESSION_NAME -u SESSION_HOST_LABEL "$LAUNCHER" "$STUB" --flag "two words" 2>/dev/null)"
if [[ "$(field NAME "$res")" =~ ^viaL-out-[0-9a-f]+$ && "$(field ARGC "$res")" == "2" ]] \
  && printf '%s\n' "$res" | command grep -qx 'ARG=two words'; then
  pass
else
  fail "$res"
fi

it "起動役は、ラッパーが無いブランチでも、引数をそのまま exec する"
mv "$out/scripts/claude-session-wrapper.sh" "$out/scripts/claude-session-wrapper.sh.away"
res="$(cd "$out" && env -u CLAUDE_CODE_SESSION_NAME -u SESSION_HOST_LABEL "$LAUNCHER" "$STUB" --flag "two words" 2>/dev/null)"
rc=$?
if [[ "$rc" == "0" && "$(field NAME "$res")" == "<unset>" && "$(field ARGC "$res")" == "2" ]] \
  && printf '%s\n' "$res" | command grep -qx 'ARG=two words'; then
  pass
else
  fail "rc=$rc $res"
fi

it "起動役は、ラッパーが実行可能でないときも、引数をそのまま exec する"
cp "$out/scripts/claude-session-wrapper.sh.away" "$out/scripts/claude-session-wrapper.sh"
chmod 644 "$out/scripts/claude-session-wrapper.sh"
res="$(cd "$out" && env -u CLAUDE_CODE_SESSION_NAME -u SESSION_HOST_LABEL "$LAUNCHER" "$STUB" --flag "two words" 2>/dev/null)"
if [[ "$(field NAME "$res")" == "<unset>" && "$(field ARGC "$res")" == "2" ]]; then pass; else fail "$res"; fi
rm -f "$out/scripts/claude-session-wrapper.sh"
mv "$out/scripts/claude-session-wrapper.sh.away" "$out/scripts/claude-session-wrapper.sh"

it "起動役の内容は作業ツリーに依存しない（別の作業ツリーから設置しても同じ内容）"
out_b="$(new_workdir)/other-tree"
run_bootstrap "$out_b" --with-claude >/dev/null 2>&1
LAUNCHER_B="$WORK/launcher-bin-b/claude-session-launcher"
(cd "$out_b" && HOME="$FAKE_HOME" GIT_CONFIG_GLOBAL="$FAKE_HOME/.gitconfig" CLAUDE_SESSION_LAUNCHER="$LAUNCHER_B" bash scripts/on-attach.sh --install-launcher >/dev/null 2>&1)
if [[ -x "$LAUNCHER_B" && "$(cksum <"$LAUNCHER")" == "$(cksum <"$LAUNCHER_B")" ]]; then pass; else fail "内容が食い違う"; fi

it "起動役は、起動したときの cwd の作業ツリーのラッパーを呼ぶ（作業ツリーごとに別の .env のラベル）"
printf 'SESSION_HOST_LABEL=treeB\n' >"$out_b/.env"
(cd "$out_b" && git init -q . >/dev/null 2>&1)
res_a="$(cd "$out" && env -u CLAUDE_CODE_SESSION_NAME -u SESSION_HOST_LABEL "$LAUNCHER" "$STUB" 2>/dev/null)"
res_b="$(cd "$out_b" && env -u CLAUDE_CODE_SESSION_NAME -u SESSION_HOST_LABEL "$LAUNCHER" "$STUB" 2>/dev/null)"
if [[ "$(field NAME "$res_a")" =~ ^viaL-out-[0-9a-f]+$ && "$(field NAME "$res_b")" =~ ^treeB-other-tree-[0-9a-f]+$ ]]; then pass; else fail "A=$(field NAME "$res_a") B=$(field NAME "$res_b")"; fi

it "起動役は、git の作業ツリーの外から起動されても、引数をそのまま exec する"
res="$(cd "$WORK" && env -u CLAUDE_CODE_SESSION_NAME -u SESSION_HOST_LABEL "$LAUNCHER" "$STUB" a 2>/dev/null)"
if [[ "$(field NAME "$res")" == "<unset>" && "$(field ARGC "$res")" == "1" ]]; then pass; else fail "$res"; fi

# ── 配線（生成物） ────────────────────────────────────────────────────────────

DC="$out/.devcontainer/devcontainer.json"

it "--with-claude の生成物の devcontainer.json が claudeProcessWrapper を絶対パスで配線する"
wired="$(jq -r '.customizations.vscode.settings["claudeCode.claudeProcessWrapper"] // empty' "$DC" 2>/dev/null)"
assert_eq "$wired" "/home/vscode/.local/bin/claude-session-launcher" "配線先"

it "配線先は作業ツリーの外の固定パスで、ラッパーを直接指さない"
if [[ "$wired" == /home/*/.local/bin/* && "$wired" != /workspaces/* ]]; then pass; else fail "$wired"; fi

it "--with-claude の生成物の onCreateCommand は on-attach.sh を呼ばず、postAttachCommand の設置は残る"
oc="$(jq -r '.onCreateCommand // empty' "$DC" 2>/dev/null)"
pa="$(jq -r '.postAttachCommand // empty' "$DC" 2>/dev/null)"
if [[ -n "$oc" && "$oc" == *"claude-session-launcher"* ]] \
  && ! printf '%s' "$oc" | command grep -q 'on-attach' \
  && [[ "$pa" == *"scripts/on-attach.sh"* ]]; then pass; else fail "onCreate=$oc postAttach=$pa"; fi

it "--with-claude を選ばない生成物には onCreateCommand がない"
if ! command grep -q 'onCreateCommand' "$out_plain/.devcontainer/devcontainer.json" \
  && [[ -z "$(jq -r '.onCreateCommand // empty' "$out_plain/.devcontainer/devcontainer.json" 2>/dev/null)" ]]; then pass; else fail "onCreateCommand が残っている"; fi

# onCreateCommand の書き出し先は決め打ちの /home/vscode/…（HOME に依らない）。試験では、その
# 接頭辞だけを仕込みのホームへ置き換えて実行する。
# run_oncreate <ホーム> [コマンド] : コンテナが使うのと同じ形（sh -c）で実行する。
run_oncreate() { local c="${2:-$oc}"; (cd "$out" && sh -c "${c//\/home\/vscode/$1}" 2>&1); }

it "onCreateCommand の実行で、実行可能な起動役が置かれ、on-attach.sh が置くものとバイト一致する"
OC_HOME="$WORK/oc-home"
mkdir -p "$OC_HOME"
run_oncreate "$OC_HOME" >/dev/null
OC_LAUNCHER="$OC_HOME/.local/bin/claude-session-launcher"
if [[ -x "$OC_LAUNCHER" ]] && cmp -s "$OC_LAUNCHER" "$LAUNCHER" && [[ ! -e "$OC_LAUNCHER.oncreate.tmp" ]]; then pass; else fail "置かれていない、または内容が違う"; fi

it "onCreateCommand を 2 回実行しても、起動役の内容は変わらない"
sum_before="$(cksum <"$OC_LAUNCHER")"
run_oncreate "$OC_HOME" >/dev/null
if [[ "$(cksum <"$OC_LAUNCHER")" == "$sum_before" && -x "$OC_LAUNCHER" ]]; then pass; else fail "内容が変わった"; fi

it "onCreateCommand が置いた起動役を壊されていても、もう一度実行すれば元へ戻る"
printf '#!/bin/sh\nexit 9\n' >"$OC_LAUNCHER"
run_oncreate "$OC_HOME" >/dev/null
if [[ "$(cksum <"$OC_LAUNCHER")" == "$sum_before" ]]; then pass; else fail "戻っていない"; fi

it "中心の場面: on-attach.sh が --install-launcher を知らない古い版でも、onCreateCommand で起動役が置かれる"
# 設置を知らない古い on-attach.sh を模す（引数を無視して何もしない）。onCreateCommand が
# それを呼ぶなら、起動役は置かれない。
out_old="$(new_workdir)/old-attach"
run_bootstrap "$out_old" --with-claude >/dev/null 2>&1
printf '#!/usr/bin/env bash\necho "[on-attach] bootstrap active"\n' >"$out_old/scripts/on-attach.sh"
oc_old="$(jq -r '.onCreateCommand // empty' "$out_old/.devcontainer/devcontainer.json" 2>/dev/null)"
OLD_HOME="$WORK/old-home"
mkdir -p "$OLD_HOME"
run_oncreate "$OLD_HOME" "$oc_old" >/dev/null
if [[ -x "$OLD_HOME/.local/bin/claude-session-launcher" ]] && cmp -s "$OLD_HOME/.local/bin/claude-session-launcher" "$LAUNCHER"; then pass; else fail "起動役が置かれていない"; fi

it "設置できない場合（HOME の下に書けない）も、警告を出して成功終了する（コンテナの作成を止めない）"
BAD_HOME="$WORK/bad-home"
mkdir -p "$BAD_HOME"
: >"$BAD_HOME/.local"
bad_rc=0
bad_out="$(run_oncreate "$BAD_HOME")" || bad_rc=$?
if [[ "$bad_rc" == "0" ]] && printf '%s' "$bad_out" | command grep -q 'WARN'; then pass; else fail "rc=$bad_rc out=$bad_out"; fi

it "onCreateCommand の書き出し先と claudeProcessWrapper の配線先が同じパスである（HOME に依らない）"
if [[ "$oc" == *"f=\"$wired\""* && "$oc" != *'$HOME'* ]]; then pass; else fail "wired=$wired"; fi

# 壊した雛形（on-attach.sh の LAUNCHER ヒアドキュメント）で、生成がエラーになること。
# bootstrap.sh のコピーの雛形だけを書き換え、パッケージの他のファイルは相対位置で解決させる。
BROKEN_DIR="$(new_workdir)/broken-pkg"
cp -R "$PKG_DIR" "$BROKEN_DIR"
broken_gen() { # <sed 式> : LAUNCHER 内の行を python で書き換えた bootstrap.sh で生成する
  python3 -I - "$BROKEN_DIR/bootstrap.sh" "$1" <<'PYEOF'
import sys
p, mode = sys.argv[1], sys.argv[2]
s = open(p, encoding='utf-8').read()
a = s.index("<<'LAUNCHER'\n") + len("<<'LAUNCHER'\n")
b = s.index("\nLAUNCHER\n", a)
body = s[a:b]
if mode == 'empty':
    s = s[:a - len("<<'LAUNCHER'\n")] + "<<'LAUNCHER_X'\n" + s[a:]
elif mode == 'quote':
    body = body + "\necho 'x'"
    s = s[:a] + body + s[b:]
elif mode == 'tab':
    body = body + "\n\techo x"
    s = s[:a] + body + s[b:]
open(p, 'w', encoding='utf-8').write(s)
PYEOF
}
BROKEN_ORIG="$(cat "$BROKEN_DIR/bootstrap.sh")"
run_broken() { # <mode> : 終了コードと標準エラーを返す
  printf '%s\n' "$BROKEN_ORIG" >"$BROKEN_DIR/bootstrap.sh"
  broken_gen "$1"
  bash "$BROKEN_DIR/bootstrap.sh" --project-name test --languages node --with-claude \
    --base-image mcr.microsoft.com/devcontainers/base:ubuntu --output-dir "$(new_workdir)/o" 2>&1 >/dev/null
}

it "起動役の中身を雛形から取り出せないとき、生成が終了コード 1 で止まり、理由を出す"
broken_rc=0
broken_err="$(run_broken empty)" || broken_rc=$?
if [[ "$broken_rc" == "1" && "$broken_err" == *"取り出せませんでした"* ]]; then pass; else fail "rc=$broken_rc err=$broken_err"; fi

it "起動役の中身に単一引用符があるとき、生成が終了コード 1 で止まり、理由を出す"
broken_rc=0
broken_err="$(run_broken quote)" || broken_rc=$?
if [[ "$broken_rc" == "1" && "$broken_err" == *"単一引用符"* ]]; then pass; else fail "rc=$broken_rc err=$broken_err"; fi

it "起動役の中身に制御文字（タブ）があるとき、生成が終了コード 1 で止まり、理由を出す"
broken_rc=0
broken_err="$(run_broken tab)" || broken_rc=$?
if [[ "$broken_rc" == "1" && "$broken_err" == *"制御文字"* ]]; then pass; else fail "rc=$broken_rc err=$broken_err"; fi

it "onCreateCommand の起動役は、引用符を含む中身も崩れずにそのまま書き出される（行数と exec の行）"
if [[ "$(wc -l <"$OC_LAUNCHER" | tr -d ' ')" == "9" ]] && command grep -qxF 'exec "$@"' "$OC_LAUNCHER" \
  && command grep -qF 't="$(git rev-parse --show-toplevel 2>/dev/null)" || t=""' "$OC_LAUNCHER"; then pass; else fail "$(cat "$OC_LAUNCHER")"; fi

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
