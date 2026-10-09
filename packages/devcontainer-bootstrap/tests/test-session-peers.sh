#!/usr/bin/env bash
# 同じプロジェクトで動くほかのセッションの一覧と宛先の解決（scripts/session-peers.sh）を、
# 仕込みの HOME とダミーの json で検証する。実物の ~/.claude には依存しない。
#
#   - 生きている・同じ pidDomain・同じプロジェクトのものだけが出る
#   - PID が再利用されたもの・別の pidDomain・別のリポジトリは出ない
#   - 別の作業ツリーでも同じ git-common-dir なら出る
#   - 台帳の issue が表示に出る
#   - resolve が番号・完全一致・前方一致・#issue・作業ツリー名で 1 件に決まる
#   - 0 件・複数件は非 0
#   - json が壊れているときは fail-open
#
# セッションは sleep のプロセスで模擬し、json の procStart には /proc/<PID>/stat の
# 22 列目を書く（Claude Code 2.1.296 の実測と同じ対応）。bash 3.2 互換。

set -uo pipefail

OWN_TMP_ROOT=""
if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-session-peers-test.XXXXXX")"
  export TEST_TMP_ROOT
  OWN_TMP_ROOT="$TEST_TMP_ROOT"
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-session-peers"

out="$(new_workdir)/out"
run_bootstrap "$out" --with-claude >/dev/null 2>&1
PEERS="$out/scripts/session-peers.sh"
LEDGER="$out/scripts/session-ledger.sh"

it "session-peers.sh が --with-claude で生成され、実行可能である"
if [[ -f "$PEERS" ]]; then assert_mode "$PEERS" "755"; else fail "生成されていない: $PEERS"; fi

it "構文が正しい"
if bash -n "$PEERS" 2>/dev/null; then pass; else fail "syntax error"; fi

# ── フィクスチャ ──────────────────────────────────────────────────────────────

W="$(new_workdir)"
HOME_DIR="$W/home"
SESS="$HOME_DIR/.claude/sessions"
mkdir -p "$SESS"

mkrepo() { # ディレクトリ
  mkdir -p "$1"
  (
    cd "$1" || exit 1
    git init -q . 2>/dev/null
    git config user.name test
    git config user.email test@example.com
    git config commit.gpgsign false
    echo x >f.txt
    git add f.txt
    git commit -q -m init
  ) >/dev/null 2>&1
}
REPO="$W/proj"
OTHER="$W/other-repo"
WT2="$W/proj-wt2"
mkrepo "$REPO"
mkrepo "$OTHER"
(cd "$REPO" && git worktree add -q "$WT2" -b second >/dev/null 2>&1)

DOMAIN="linux::pid:[4026500001]"
OTHER_DOMAIN="linux::pid:[4026599999]"

# 開始時刻の読み取りは、検査対象のスクリプトの proc_start を使う（source ガードで関数だけが入る）。
# shellcheck disable=SC1090
. "$PEERS"

PIDS=""
cleanup() {
  # shellcheck disable=SC2086
  kill $PIDS 2>/dev/null || true
  [[ -z "$OWN_TMP_ROOT" ]] || rm -rf "$OWN_TMP_ROOT"
}
trap cleanup EXIT

# 模擬セッションのプロセスを起こす。PID は変数 SPAWNED に入れる（コマンド置換の中で起こすと
# バックグラウンドのプロセスが親シェルの子にならないため、関数を直接呼ぶ）。
SPAWNED=""
spawn() {
  sleep 600 &
  SPAWNED=$!
  PIDS="$PIDS $SPAWNED"
}

# write_json <PID> <procStart> <名前> <cwd> <pidDomain> [状態] [startedAt]
write_json() {
  jq -n --argjson pid "$1" --arg ps "$2" --arg name "$3" --arg cwd "$4" --arg dom "$5" \
    --arg st "${6:-idle}" --argjson sa "${7:-1000}" \
    '{pid:$pid, procStart:$ps, name:$name, cwd:$cwd, pidDomain:$dom, status:$st, startedAt:$sa, kind:"interactive"}' \
    >"$SESS/$1.json"
}

# A1 = 自分。A2 = 別の作業ツリー。いずれも生きていて、同じ pidDomain・同じリポジトリ。
spawn; PID_A1="$SPAWNED"
spawn; PID_A2="$SPAWNED"
spawn; PID_B="$SPAWNED"
spawn; PID_D="$SPAWNED"
spawn; PID_R="$SPAWNED"
spawn; PID_X="$SPAWNED"
write_live() { # PID 名前 cwd pidDomain 状態 startedAt（開始時刻は実プロセスから読む）
  proc_start "$1"
  write_json "$1" "$PROC_START" "$2" "$3" "$4" "$5" "$6"
}
write_live "$PID_A1" "lab-proj-a1" "$REPO" "$DOMAIN" idle 1000
write_live "$PID_A2" "lab-proj-wt2-b2" "$WT2" "$DOMAIN" busy 2000
# 別のリポジトリ
write_live "$PID_B" "private-chat" "$OTHER" "$DOMAIN" idle 3000
# 別の pidDomain（前のコンテナの json が残ったもの）
write_live "$PID_D" "stale-domain" "$REPO" "$OTHER_DOMAIN" idle 4000
# PID は生きているが、procStart が違う（PID が再利用された別のプロセス）
write_json "$PID_R" "1" "reused-pid" "$REPO" "$DOMAIN" idle 5000
# 終了したプロセス
write_live "$PID_X" "dead-proc" "$REPO" "$DOMAIN" idle 6000
kill "$PID_X" 2>/dev/null
wait "$PID_X" 2>/dev/null

# 台帳の操作 <PID> <サブコマンド> [引数…]。セッション識別子は pid-<PID>-<開始時刻> にする。
ledger_as() {
  local pid="$1"; shift
  proc_start "$pid"
  (cd "$REPO" && SESSION_LEDGER_ID="pid-$pid-$PROC_START" SESSION_LEDGER_PID="$pid" bash "$LEDGER" "$@" >/dev/null 2>&1)
}
# 台帳: A1 は #502、A2 は #7 と #8 に着手している。
ledger_as "$PID_A1" claim issue 502
ledger_as "$PID_A2" claim issue 7
ledger_as "$PID_A2" claim issue 8

peers() { # 引数… （自分 = A1 の作業ツリーから実行する）
  (cd "$REPO" && HOME="$HOME_DIR" SESSION_PEERS_PID_DOMAIN="$DOMAIN" SESSION_PEERS_SELF_PID="$PID_A1" bash "$PEERS" "$@")
}

# ── list ──────────────────────────────────────────────────────────────────────

it "list: 生きている・同じ pidDomain・同じプロジェクトのものだけが出る"
names="$(peers list --names 2>/dev/null | sort | tr '\n' ' ')"
assert_eq "$names" "lab-proj-a1 lab-proj-wt2-b2 " "宛先名"

tbl="$(peers list 2>/dev/null)"

it "list: PID が再利用されたもの（procStart 不一致）は出ない"
if ! printf '%s\n' "$tbl" | command grep -q 'reused-pid'; then pass; else fail "出ている"; fi

it "list: 別の pidDomain のものは出ない"
if ! printf '%s\n' "$tbl" | command grep -q 'stale-domain'; then pass; else fail "出ている"; fi

it "list: 別のリポジトリのものは出ない"
if ! printf '%s\n' "$tbl" | command grep -q 'private-chat'; then pass; else fail "出ている"; fi

it "list: 終了したプロセスのものは出ない"
if ! printf '%s\n' "$tbl" | command grep -q 'dead-proc'; then pass; else fail "出ている"; fi

it "list: 別の作業ツリーでも、同じ git-common-dir ならその作業ツリー名で出る"
if [[ "$(printf '%s\n' "$tbl" | cut -f1-3 | sed -n '3p')" == "$(printf '2\tlab-proj-wt2-b2\tproj-wt2')" ]]; then pass; else fail "$tbl"; fi

it "list: 台帳の issue が表示に出る（複数あればカンマ区切り）"
issues_a1="$(printf '%s\n' "$tbl" | sed -n '2p' | cut -f4)"
issues_a2="$(printf '%s\n' "$tbl" | sed -n '3p' | cut -f4)"
if [[ "$issues_a1" == "#502" && ( "$issues_a2" == "#7,#8" || "$issues_a2" == "#8,#7" ) ]]; then pass; else fail "a1=$issues_a1 a2=$issues_a2"; fi

it "list: 台帳に issue が無いセッションは - を出す"
# 台帳から A2 の登録を外して、同じ表示を確かめる。
ledger_as "$PID_A2" release
assert_eq "$(peers list 2>/dev/null | sed -n '3p' | cut -f4)" "-" "issue 欄"
ledger_as "$PID_A2" claim issue 7
ledger_as "$PID_A2" claim issue 8

it "list: SESSION_LEDGER_ID を明示して claim したセッションの issue も出る（pid の列で結ぶ）"
# 識別子が pid-<PID>-<開始時刻> の形でないセッション。A2 の登録を、明示した別名で置き直す。
ledger_as "$PID_A2" release
(cd "$REPO" && SESSION_LEDGER_ID="custom-name" SESSION_LEDGER_PID="$PID_A2" bash "$LEDGER" claim issue 99 >/dev/null 2>&1)
got="$(peers list 2>/dev/null | sed -n '3p' | cut -f4)"
(cd "$REPO" && SESSION_LEDGER_ID="custom-name" SESSION_LEDGER_PID="$PID_A2" bash "$LEDGER" release >/dev/null 2>&1)
ledger_as "$PID_A2" claim issue 7
ledger_as "$PID_A2" claim issue 8
assert_eq "$got" "#99" "issue 欄"

it "list: /proc を読めない環境では、開始時刻と pidDomain の照合を省き、生きていれば出す"
np="$(cd "$REPO" && HOME="$HOME_DIR" SESSION_PEERS_NO_PROC=1 SESSION_PEERS_SELF_PID="$PID_A1" bash "$PEERS" list --names 2>/dev/null | sort | tr '\n' ' ')"
case "$np" in
  *"lab-proj-a1 "*"lab-proj-wt2-b2 "*) pass ;;
  *) fail "一覧=$np" ;;
esac

it "list: /proc を読めない環境でも、終了したプロセスは出ない"
case "$np" in
  *dead-proc*) fail "一覧=$np" ;;
  *) pass ;;
esac

it "list: 状態が出る。自分の行に印が付き、--others では自分が出ない"
if [[ "$(printf '%s\n' "$tbl" | sed -n '3p' | cut -f5)" == "busy" ]] \
  && printf '%s\n' "$tbl" | command grep -q 'idle (自分)' \
  && [[ "$(peers list --names --others 2>/dev/null)" == "lab-proj-wt2-b2" ]]; then
  pass
else
  fail "$tbl"
fi

it "list: 番号は開始時刻の古い順で振られる"
assert_eq "$(printf '%s\n' "$tbl" | sed -n '2p' | cut -f2)" "lab-proj-a1" "1 番"

# ── resolve ───────────────────────────────────────────────────────────────────

it "resolve: 番号で 1 件に決まる"
assert_eq "$(peers resolve 2 2>/dev/null)" "lab-proj-wt2-b2" "宛先名"

it "resolve: 名前の完全一致で 1 件に決まる"
assert_eq "$(peers resolve lab-proj-a1 2>/dev/null)" "lab-proj-a1" "宛先名"

it "resolve: 名前の前方一致で 1 件に決まる"
assert_eq "$(peers resolve lab-proj-wt 2>/dev/null)" "lab-proj-wt2-b2" "宛先名"

it "resolve: #issue で 1 件に決まる"
assert_eq "$(peers resolve '#502' 2>/dev/null)" "lab-proj-a1" "宛先名"

it "resolve: 作業ツリー名で 1 件に決まる"
assert_eq "$(peers resolve proj-wt2 2>/dev/null)" "lab-proj-wt2-b2" "宛先名"

it "resolve: 0 件は非 0（1）で、標準出力に何も出さず、候補を標準エラーへ出す"
sout="$(peers resolve no-such-session 2>/dev/null)"
err="$(peers resolve no-such-session 2>&1 >/dev/null)"
peers resolve no-such-session >/dev/null 2>&1
rc=$?
if [[ "$rc" == "1" && -z "$sout" ]] && printf '%s' "$err" | command grep -q 'lab-proj-a1'; then pass; else fail "rc=$rc out=$sout err=$err"; fi

it "resolve: 複数件は非 0（3）で、標準出力に何も出さず、候補を標準エラーへ出す"
sout="$(peers resolve lab-proj 2>/dev/null)"
err="$(peers resolve lab-proj 2>&1 >/dev/null)"
peers resolve lab-proj >/dev/null 2>&1
rc=$?
if [[ "$rc" == "3" && -z "$sout" ]] && printf '%s' "$err" | command grep -q 'lab-proj-wt2-b2'; then pass; else fail "rc=$rc out=$sout err=$err"; fi

it "resolve: 範囲外の番号は 0 件扱い（非 0）"
peers resolve 99 >/dev/null 2>&1
assert_eq "$?" "1" "終了コード"

it "resolve: 指定が無いと使い方の誤りで 2"
peers resolve >/dev/null 2>&1
assert_eq "$?" "2" "終了コード"

# ── whoami ────────────────────────────────────────────────────────────────────

it "whoami: 宛先名・場所・作業ツリー・issue の署名の行を出す"
sig="$(cd "$REPO" && HOME="$HOME_DIR" SESSION_PEERS_PID_DOMAIN="$DOMAIN" SESSION_PEERS_SELF_PID="$PID_A1" SESSION_HOST_LABEL=lab bash "$PEERS" whoami 2>/dev/null)"
assert_eq "$sig" "[from: lab-proj-a1 | 場所: lab | 作業ツリー: proj | issue: #502]" "署名"

it "whoami: 自分の json を特定できなくても 0 で終わり、署名の形は保つ"
sig2="$(cd "$REPO" && HOME="$HOME_DIR" SESSION_PEERS_PID_DOMAIN="$DOMAIN" SESSION_PEERS_SELF_PID=999999 bash "$PEERS" whoami 2>/dev/null)"
rc=$?
if [[ "$rc" == "0" && "$sig2" == '[from: '* ]]; then pass; else fail "rc=$rc $sig2"; fi

it "whoami: 場所は宛先名と同じ置き換え（英数字と ._- 以外は _）をかける"
sig3="$(cd "$REPO" && HOME="$HOME_DIR" SESSION_PEERS_PID_DOMAIN="$DOMAIN" SESSION_PEERS_SELF_PID="$PID_A1" SESSION_HOST_LABEL='ho st/x' bash "$PEERS" whoami 2>/dev/null)"
case "$sig3" in
  *"場所: ho_st_x |"*) pass ;;
  *) fail "$sig3" ;;
esac

# 祖先の PID と同じ名前の json で、自分を特定する。peers を起動するサブシェルが、その親になる。
# 末尾の true は、サブシェルが最後のコマンドを exec で置き換えて親の関係が崩れるのを防ぐ。
whoami_via_ancestor() { # 親の json の pidDomain 名前
  (
    cd "$REPO" || exit 1
    if [[ "$1" == "stale" ]]; then
      write_json "$BASHPID" "1" "stale-self" "$REPO" "$OTHER_DOMAIN" idle 7000
    else
      write_live "$BASHPID" "adopted-self" "$REPO" "$DOMAIN" idle 7000
    fi
    HOME="$HOME_DIR" SESSION_PEERS_PID_DOMAIN="$DOMAIN" bash "$PEERS" whoami 2>/dev/null
    rm -f "$SESS/$BASHPID.json"
    true
  )
}

it "self: 祖先と同じ PID の名前で別の pidDomain の古い json が残っていても、取り違えない"
sig_stale="$(whoami_via_ancestor stale)"
case "$sig_stale" in
  *"stale-self"*) fail "古い json を自分として採った: $sig_stale" ;;
  '[from: (宛先名不明)'*) pass ;;
  *) fail "$sig_stale" ;;
esac

it "self: 祖先と同じ PID の名前で pidDomain と procStart が一致する json は、自分として採る"
sig_ok="$(whoami_via_ancestor ok)"
case "$sig_ok" in
  '[from: adopted-self |'*) pass ;;
  *) fail "$sig_ok" ;;
esac

it "json に pidDomain / procStart が欠けていると、警告と ListAgents の案内を stderr に出す"
spawn; PID_MISSING="$SPAWNED"
printf '{"pid":%s,"name":"missing-fields","cwd":"%s","status":"idle","startedAt":8000}' "$PID_MISSING" "$REPO" >"$SESS/$PID_MISSING.json"
warn_out="$(peers list 2>&1 >/dev/null)"
if printf '%s' "$warn_out" | command grep -q 'WARN' && printf '%s' "$warn_out" | command grep -q 'ListAgents' && printf '%s' "$warn_out" | command grep -q "$PID_MISSING.json"; then pass; else fail "$warn_out"; fi
rm -f "$SESS/$PID_MISSING.json"

# ── fail-open ─────────────────────────────────────────────────────────────────

it "json が壊れていても 0 で終わり、警告を出して、読める json は出す"
spawn; PID_BROKEN="$SPAWNED"
printf '{ this is not json' >"$SESS/$PID_BROKEN.json"
out_broken="$(peers list 2>&1)"
rc=$?
if [[ "$rc" == "0" ]] && printf '%s' "$out_broken" | command grep -q 'WARN' && printf '%s' "$out_broken" | command grep -q 'lab-proj-a1'; then pass; else fail "rc=$rc $out_broken"; fi

it "形が違う json（pid が数字でない・name が無い）も読み飛ばして 0 で終わる"
spawn; PID_ODD1="$SPAWNED"
spawn; PID_ODD2="$SPAWNED"
printf '{"pid":"abc","name":"x"}' >"$SESS/$PID_ODD1.json"
printf '{"pid":%s,"procStart":"1"}' "$PID_ODD2" >"$SESS/$PID_ODD2.json"
peers list >/dev/null 2>&1
assert_eq "$?" "0" "終了コード"

it "壊れた json があっても resolve は読める分で解決できる"
assert_eq "$(peers resolve lab-proj-a1 2>/dev/null)" "lab-proj-a1" "宛先名"

it "セッションの置き場所が無いときは 0 で終わり、ListAgents を使う案内を出す"
msg="$(cd "$REPO" && HOME="$W/no-such-home" SESSION_PEERS_PID_DOMAIN="$DOMAIN" bash "$PEERS" list 2>&1)"
rc=$?
if [[ "$rc" == "0" ]] && printf '%s' "$msg" | command grep -q 'ListAgents'; then pass; else fail "rc=$rc $msg"; fi

it "git リポジトリの外から実行しても 0 で終わり、ListAgents を使う案内を出す"
msg="$(cd "$W" && HOME="$HOME_DIR" SESSION_PEERS_PID_DOMAIN="$DOMAIN" bash "$PEERS" list 2>&1)"
rc=$?
if [[ "$rc" == "0" ]] && printf '%s' "$msg" | command grep -q 'ListAgents'; then pass; else fail "rc=$rc $msg"; fi

it "使い方の誤りは 2"
peers frobnicate >/dev/null 2>&1
assert_eq "$?" "2" "終了コード"

exit_with_result
