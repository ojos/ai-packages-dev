#!/usr/bin/env bash
# 並行セッションの共有台帳を操作の直前に確かめるフック（scripts/session-coord-hook.sh）の
# 配置・配線と判定を、模擬のセッション 2 本で検証する。
#
# 台帳そのものの挙動は test-session-ledger.sh が見る。ここで見るのは、フックが
#   - 正しいイベントから呼ばれるように配線されていること
#   - 止めるべき操作を拒否し、警告すべき操作を警告し、それ以外を黙って通すこと
#   - 台帳が壊れていても通すこと
# である。確認フック（test-confirm-merge-hook.sh）と同じく、模擬の入力 JSON をフックへ
# 流して、標準出力の判定を見る。実際の gh も git の書き込みも行わない（git は作業ツリーの
# 作成にだけ使う）。ネットワークには出ない。
#
# 受け入れ条件との対応（票 #395）:
#   (a) 同じ issue への着手は警告して通る
#   (b) 相手が merge を登録している間の gh pr merge は拒否される
#   (c) 相手が登録している作業ツリーでの git rebase は拒否される
#   (d) 重いゲートの同時起動は拒否される
#   (e) 相手が登録している文書の Edit は警告して通る
#   (f) 持ち主の PID が消えた登録は失効し、通る
#   (g) 自分の登録では止まらない
#   (h) 台帳が壊れていても、警告を出して通る
#   (i) 拒否・警告の出力に、相手の識別子・登録の種類・調整の手順が含まれる
#   (j) SessionStart の出力に、他セッションの登録の要約が含まれる
#   (k) 相手が release した後は、同じ操作が通る
#
# セッションは SESSION_LEDGER_ID と SESSION_LEDGER_PID で模擬する。bash 3.2 互換。

set -uo pipefail

# run-tests.sh を介さず直接実行されたときは、自前で一時領域を作って後で消す。
OWN_TMP_ROOT=""
if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-session-coord-test.XXXXXX")"
  export TEST_TMP_ROOT
  OWN_TMP_ROOT="$TEST_TMP_ROOT"
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-session-coord-hook"

HOOK_REL="scripts/session-coord-hook.sh"
SETTINGS_REL=".claude/settings.json"

# ── 配置と配線 ────────────────────────────────────────────────────────────────

out="$(new_workdir)/p"
run_bootstrap "$out" --with-claude --without-playbook >/dev/null 2>&1
HOOK="$out/$HOOK_REL"
LEDGER="$out/scripts/session-ledger.sh"
SETTINGS="$out/$SETTINGS_REL"

it "--with-claude でフック本体が配置され、実行可能（755）である"
if [[ -f "$HOOK" ]]; then assert_mode "$HOOK" "755"; else fail "生成されていない: $HOOK"; fi

it "構文が正しい"
if bash -n "$HOOK" 2>/dev/null; then pass; else fail "syntax error"; fi

it "--with-claude なしではフック本体を配置しない（台帳は常に配置する）"
outn="$(new_workdir)/p"
run_bootstrap "$outn" --without-playbook >/dev/null 2>&1
if [[ ! -e "$outn/$HOOK_REL" && -f "$outn/scripts/session-ledger.sh" ]]; then pass; else fail "hook=$(ls "$outn/$HOOK_REL" 2>&1) ledger=$(ls "$outn/scripts/session-ledger.sh" 2>&1)"; fi

it "dry-run は --with-claude 時にフックを計画に含める"
plan="$(run_bootstrap "$(new_workdir)/p" --with-claude --without-playbook --dry-run 2>&1)"
assert_contains "$plan" "$HOOK_REL" "dry-run の計画"

# 配線は、フック本体が配置されているだけでは何も保証しない。イベントごとに、settings.json の
# JSON を実際に読んで、登録されたコマンドがフック本体を指していることまで見る。
wired() { # jq フィルタ（コマンドの配列を返す）
  jq -r "$1 // [] | map(.hooks[].command) | join(\"\\n\")" "$SETTINGS" 2>/dev/null
}

it "settings.json: SessionStart からフックを呼ぶ"
assert_contains "$(wired '.hooks.SessionStart')" "session-coord-hook.sh" "SessionStart のコマンド"

it "settings.json: PreToolUse の Bash からフックを呼ぶ"
assert_contains "$(wired '.hooks.PreToolUse | map(select(.matcher == "Bash"))')" "session-coord-hook.sh" "PreToolUse(Bash) のコマンド"

it "settings.json: PreToolUse の Edit|Write からフックを呼ぶ"
assert_contains "$(wired '.hooks.PreToolUse | map(select(.matcher == "Edit|Write"))')" "session-coord-hook.sh" "PreToolUse(Edit|Write) のコマンド"

it "settings.json: PostToolUse の Bash からフックを呼ぶ（実行のあいだだけの登録を解放する）"
assert_contains "$(wired '.hooks.PostToolUse | map(select(.matcher == "Bash"))')" "session-coord-hook.sh" "PostToolUse(Bash) のコマンド"

it "settings.json: SessionEnd からフックを呼ぶ"
assert_contains "$(wired '.hooks.SessionEnd')" "session-coord-hook.sh" "SessionEnd のコマンド"

it "settings.json: 既存の確認フックの配線は PreToolUse の先頭に残る（挙動を変えない）"
first_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$SETTINGS" 2>/dev/null)"
first_matcher="$(jq -r '.hooks.PreToolUse[0].matcher // empty' "$SETTINGS" 2>/dev/null)"
if [[ "$first_cmd" == *confirm-merge-hook.sh* && "$first_matcher" == "Bash" ]]; then pass; else fail "matcher=$first_matcher cmd=$first_cmd"; fi

it "settings.json: permissions を持たない"
assert_eq "$(jq -r 'has("permissions")' "$SETTINGS" 2>/dev/null)" "false" "permissions の有無"

it "settings.json: 配線の呼び出し先がすべて生成物の中に実在する"
missing=""
for c in $(jq -r '.. | .command? // empty' "$SETTINGS" 2>/dev/null | sed -n 's/.*\/\(scripts\/[A-Za-z0-9._-]*\)\\*".*/\1/p' | sort -u); do
  [[ -f "$out/$c" ]] || missing="$missing $c"
done
if [[ -z "$missing" ]]; then pass; else fail "実在しない:$missing"; fi

# ── フィクスチャ ──────────────────────────────────────────────────────────────

repo="$(new_workdir)/repo"
wt2="$(dirname "$repo")/wt2"
mkdir -p "$repo"
(
  cd "$repo" || exit 1
  git init -q . 2>/dev/null
  git config user.name test
  git config user.email test@example.com
  git config commit.gpgsign false
  echo x > f.txt
  git add f.txt
  git commit -q -m init
  git worktree add -q "$wt2" -b other 2>/dev/null
) >/dev/null 2>&1

# 生きている持ち主の代わりになるプロセス。
sleep 600 &
PID_A=$!
sleep 600 &
PID_B=$!
cleanup() {
  kill "$PID_A" "$PID_B" "${PID_C:-}" 2>/dev/null || true
  [[ -z "$OWN_TMP_ROOT" ]] || rm -rf "$OWN_TMP_ROOT"
}
trap cleanup EXIT

pid_of() {
  case "$1" in
    s-a) printf '%s' "$PID_A" ;;
    s-b) printf '%s' "$PID_B" ;;
    *) printf '%s' "${PID_C:-$PID_B}" ;;
  esac
}

COMMON="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)"
DIR="$COMMON/session-ledger"

# 台帳の CLI（セッションを指定して直接呼ぶ）。フックの外で相手の登録を作るのに使う。
ledger() { # セッション 作業ツリー 引数...
  local sid="$1" dir="$2"; shift 2
  (cd "$dir" && SESSION_LEDGER_ID="$sid" SESSION_LEDGER_PID="$(pid_of "$sid")" bash "$LEDGER" "$@" 2>&1)
}

# フックへ JSON を流す。結果は HOUT（標準出力）と HRC（終了コード）。
HOUT=""
HRC=0
hook_raw() { # セッション ペイロード
  local sid="$1" payload="$2"
  HOUT="$(printf '%s' "$payload" | SESSION_LEDGER_ID="$sid" SESSION_LEDGER_PID="$(pid_of "$sid")" bash "$HOOK" 2>/dev/null)"
  HRC=$?
}

pl_bash() { # イベント cwd コマンド
  jq -n --arg ev "$1" --arg cwd "$2" --arg cmd "$3" \
    '{hook_event_name: $ev, tool_name: "Bash", cwd: $cwd, tool_input: {command: $cmd}}'
}
pl_edit() { # cwd パス
  jq -n --arg cwd "$1" --arg p "$2" \
    '{hook_event_name: "PreToolUse", tool_name: "Edit", cwd: $cwd, tool_input: {file_path: $p, old_string: "a", new_string: "b"}}'
}
pl_event() { # イベント cwd
  jq -n --arg ev "$1" --arg cwd "$2" '{hook_event_name: $ev, cwd: $cwd}'
}

pre_bash() { hook_raw "$1" "$(pl_bash PreToolUse "$2" "$3")"; }
post_bash() { hook_raw "$1" "$(pl_bash PostToolUse "$2" "$3")"; }
pre_edit() { hook_raw "$1" "$(pl_edit "$2" "$3")"; }

decision() {
  [[ -n "$HOUT" ]] || { echo none; return 0; }
  printf '%s' "$HOUT" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null
}
reason() { printf '%s' "$HOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null; }
context() { printf '%s' "$HOUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }
sysmsg() { printf '%s' "$HOUT" | jq -r '.systemMessage // empty' 2>/dev/null; }

# 自分の台帳ファイルに、種類 kind の claim の行があるか。
has_claim() { # セッション kind
  [[ -f "$DIR/$1.tsv" ]] && grep -q "$(printf '\tclaim\t%s\t' "$2")" "$DIR/$1.tsv"
}

reset_ledger() { rm -rf "$DIR"; }

# 通る（拒否も警告もしない）ことを確かめる。
assert_quiet_pass() { # ラベル
  if [[ "$HRC" -eq 0 && "$(decision)" == "none" && -z "$(context)" ]]; then pass; else fail "$1: rc=$HRC out=$HOUT"; fi
}

# ── (b) merge ────────────────────────────────────────────────────────────────

it "(b) 最初のセッションの gh pr merge はフックが通し、merge を登録する"
pre_bash s-a "$repo" 'gh pr merge 5 --squash'
if [[ "$(decision)" == "none" ]] && has_claim s-a merge; then pass; else fail "decision=$(decision) out=$HOUT"; fi

it "(b) 相手が merge を登録している間の gh pr merge は拒否される"
pre_bash s-b "$repo" 'gh pr merge 6 --squash'
if [[ "$HRC" -eq 0 && "$(decision)" == "deny" ]]; then pass; else fail "rc=$HRC out=$HOUT"; fi

it "(b) 拒否したセッションは merge を登録しない"
if ! has_claim s-b merge; then pass; else fail "登録が残っている"; fi

it "(i) 拒否の理由に、相手の識別子・登録の種類・調整の手順が含まれる"
r="$(reason)"
case "$r" in
  *"session=s-a"*"kind=merge"*"coordinate"*"ListAgents"*"SendMessage"*"利用者"*) pass ;;
  *) fail "理由: $r" ;;
esac

it "(b) 他の merge の経路（gh release create / REST の PUT / GraphQL）も拒否される"
bad=""
for c in \
  'gh release create v1.0.0 --notes x' \
  'gh api repos/o/r/pulls/7/merge -X PUT' \
  'gh api --method=PUT repos/o/r/pulls/7/merge' \
  'cd /tmp && gh pr merge 8'; do
  pre_bash s-b "$repo" "$c"
  [[ "$(decision)" == "deny" ]] || bad="$bad | $c => $(decision)"
done
pre_bash s-b "$repo" 'gh api graphql -f query="mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"'
[[ "$(decision)" == "deny" ]] || bad="$bad | graphql => $(decision)"
if [[ -z "$bad" ]]; then pass; else fail "拒否されなかった: $bad"; fi

it "(g) 自分のセッションの登録では止まらない（同じセッションの 2 回目の merge）"
pre_bash s-a "$repo" 'gh pr merge 5 --squash'
assert_quiet_pass "自分の登録"

it "PostToolUse は、実行のあいだだけ持った merge の登録を解放する"
post_bash s-a "$repo" 'gh pr merge 5 --squash'
run_out="$(ledger s-b "$repo" check merge | sed -n 1p)"
assert_eq "$run_out" "LEDGER_OK" "解放後の check merge"

it "(k) 相手が解放した後は、同じ gh pr merge が通る"
pre_bash s-b "$repo" 'gh pr merge 6 --squash'
if [[ "$(decision)" == "none" ]] && has_claim s-b merge; then pass; else fail "decision=$(decision) out=$HOUT"; fi
post_bash s-b "$repo" 'gh pr merge 6 --squash'
reset_ledger

# ── (c) 作業ツリーの git 操作 ────────────────────────────────────────────────

it "(c) 最初のセッションの git rebase はフックが通し、作業ツリーを登録する"
pre_bash s-a "$repo" 'git rebase main'
if [[ "$(decision)" == "none" ]] && has_claim s-a git; then pass; else fail "decision=$(decision) out=$HOUT"; fi

it "(c) 相手が登録している作業ツリーでの git rebase は拒否される"
pre_bash s-b "$repo" 'git rebase origin/main'
if [[ "$(decision)" == "deny" ]]; then pass; else fail "out=$HOUT"; fi

it "(i) git の拒否の理由に、相手の識別子・登録の種類・作業ツリー・調整の手順が含まれる"
r="$(reason)"
case "$r" in
  *"session=s-a"*"kind=git"*"worktree="*"coordinate"*"SendMessage"*) pass ;;
  *) fail "理由: $r" ;;
esac

it "(c) checkout / switch / reset / fetch / pull / merge / stash も同じ作業ツリーでは拒否される"
bad=""
for c in 'git checkout main' 'git switch main' 'git reset --hard HEAD~1' 'git fetch origin' 'git pull' 'git merge other' 'git stash' 'git -C . checkout main' 'git -c core.x=y rebase main' 'GIT_PAGER=cat git rebase main' 'git status && git fetch'; do
  pre_bash s-b "$repo" "$c"
  [[ "$(decision)" == "deny" ]] || bad="$bad | $c => $(decision)"
done
if [[ -z "$bad" ]]; then pass; else fail "拒否されなかった: $bad"; fi

it "(c) 別の作業ツリーでの git 操作は通る"
pre_bash s-b "$wt2" 'git rebase main'
if [[ "$(decision)" == "none" ]]; then pass; else fail "out=$HOUT"; fi
post_bash s-b "$wt2" 'git rebase main'

it "(c) 別の作業ツリーから -C や cd で相手の作業ツリーを指しても拒否される"
pre_bash s-b "$wt2" "git -C $repo checkout main"
d1="$(decision)"
pre_bash s-b "$wt2" "cd $repo && git reset --hard"
d2="$(decision)"
if [[ "$d1" == "deny" && "$d2" == "deny" ]]; then pass; else fail "-C=$d1 cd=$d2"; fi

it "読み取りだけの git・コミットメッセージや引数に操作名を含むだけのコマンドは止めない"
bad=""
for c in 'git status' 'git log --oneline -5' 'git diff HEAD' 'git stash list' 'git commit -m "docs: git rebase の手順"' 'echo "git rebase main"' "grep -rn 'git reset' ." 'git branch --list' 'gh pr view 5' 'gh pr create --title x --body y' 'gh issue view 395'; do
  pre_bash s-b "$repo" "$c"
  [[ "$HRC" -eq 0 && "$(decision)" == "none" && -z "$(context)" ]] || bad="$bad | $c => $HOUT"
done
if [[ -z "$bad" ]]; then pass; else fail "止めた: $bad"; fi

it "ヒアドキュメントの本体に操作名があっても止めない"
hd="$(printf 'gh pr create --body-file - <<'"'"'EOF'"'"'\ngit rebase main\ngh pr merge 5\nEOF\n')"
pre_bash s-b "$repo" "$hd"
assert_quiet_pass "ヒアドキュメント"

it "ヒアドキュメントの後ろの本物の操作は拒否される"
hd2="$(printf 'cat <<'"'"'EOF'"'"'\nnote\nEOF\ngit reset --hard\n')"
pre_bash s-b "$repo" "$hd2"
assert_eq "$(decision)" "deny" "判定"

it "(k) 相手が解放した後は、同じ git 操作が通る"
post_bash s-a "$repo" 'git rebase main'
pre_bash s-b "$repo" 'git rebase origin/main'
if [[ "$(decision)" == "none" ]] && has_claim s-b git; then pass; else fail "decision=$(decision) out=$HOUT"; fi
post_bash s-b "$repo" 'git rebase origin/main'
reset_ledger

# ── (d) 重いゲート ───────────────────────────────────────────────────────────

it "(d) 最初のセッションの verify はフックが通し、gate を登録する"
pre_bash s-a "$repo" 'bash scripts/verify.sh'
if [[ "$(decision)" == "none" ]] && has_claim s-a gate; then pass; else fail "decision=$(decision) out=$HOUT"; fi

it "(d) 重いゲート（verify / loop-gate）を同時に起動すると拒否される"
bad=""
for c in 'bash scripts/verify.sh' 'bash scripts/loop-gate.sh' './scripts/verify.sh' 'bash -x scripts/loop-gate.sh --base main' 'VERIFY_ACCEPTANCE=1 bash scripts/verify.sh' 'cd /tmp && bash scripts/verify.sh'; do
  pre_bash s-b "$repo" "$c"
  [[ "$(decision)" == "deny" ]] || bad="$bad | $c => $(decision)"
done
if [[ -z "$bad" ]]; then pass; else fail "拒否されなかった: $bad"; fi

it "(i) ゲートの拒否の理由に、相手の識別子・登録の種類・調整の手順が含まれる"
r="$(reason)"
case "$r" in
  *"session=s-a"*"kind=gate"*"coordinate"*) pass ;;
  *) fail "理由: $r" ;;
esac

it "他のスクリプトの起動や、ゲートの名前を引数に含むだけのコマンドは止めない"
bad=""
for c in 'bash scripts/session-ledger.sh list' 'cat scripts/verify.sh' 'git add scripts/verify.sh' 'echo bash scripts/verify.sh'; do
  pre_bash s-b "$repo" "$c"
  if [[ "$(decision)" == "deny" ]]; then bad="$bad | $c"; fi
done
if [[ -z "$bad" ]]; then pass; else fail "止めた: $bad"; fi

it "(k) 相手のゲートが終わった（PostToolUse）後は、同じ起動が通る"
post_bash s-a "$repo" 'bash scripts/verify.sh'
pre_bash s-b "$repo" 'bash scripts/loop-gate.sh'
if [[ "$(decision)" == "none" ]] && has_claim s-b gate; then pass; else fail "decision=$(decision) out=$HOUT"; fi
post_bash s-b "$repo" 'bash scripts/loop-gate.sh'
reset_ledger

# ── (a) issue ────────────────────────────────────────────────────────────────

it "(a) ブランチ作成での着手は issue を登録する"
pre_bash s-a "$repo" 'git checkout -b feat/395-session-hooks'
if [[ "$(decision)" == "none" ]] && has_claim s-a issue; then pass; else fail "decision=$(decision) out=$HOUT"; fi
post_bash s-a "$repo" 'git checkout -b feat/395-session-hooks'

it "(a) 同じ issue への着手は、警告を出して通る（拒否しない）"
pre_bash s-b "$wt2" 'git switch -c fix/395-other'
c="$(context)"
if [[ "$HRC" -eq 0 && "$(decision)" == "none" && "$c" == *警告* ]]; then pass; else fail "decision=$(decision) out=$HOUT"; fi

it "(i) issue の警告に、相手の識別子・登録の種類・調整の手順が含まれる"
case "$c" in
  *"session=s-a"*"kind=issue"*"target=395"*"coordinate"*"SendMessage"*) pass ;;
  *) fail "文脈: $c" ;;
esac

it "(a) 警告は利用者にも見える（systemMessage）"
assert_contains "$(sysmsg)" "session=s-a" "systemMessage"
post_bash s-b "$wt2" 'git switch -c fix/395-other'

it "(a) 別の issue や、番号を含まないブランチでは警告しない"
pre_bash s-b "$wt2" 'git checkout -b feat/396-other'
a1="$(context)"
post_bash s-b "$wt2" 'git checkout -b feat/396-other'
pre_bash s-b "$wt2" 'git checkout -b release/v1-2'
a2="$(context)"
post_bash s-b "$wt2" 'git checkout -b release/v1-2'
if [[ -z "$a1" && -z "$a2" ]]; then pass; else fail "396=$a1 release=$a2"; fi

it "(a) gh issue develop でも同じ issue への着手を警告する"
pre_bash s-b "$wt2" 'gh issue develop 395'
if [[ "$(decision)" == "none" && "$(context)" == *"kind=issue"* ]]; then pass; else fail "out=$HOUT"; fi
reset_ledger

# ── (e) 文書の編集 ───────────────────────────────────────────────────────────

it "(e) 相手が登録していない文書の Edit は黙って通る"
pre_edit s-b "$repo" "$repo/docs/design.md"
assert_quiet_pass "登録なし"

it "(e) 相手が登録している文書の Edit は、警告を出して通る（拒否しない）"
ledger s-a "$repo" claim doc docs/design.md >/dev/null
pre_edit s-b "$repo" "$repo/docs/design.md"
c="$(context)"
if [[ "$HRC" -eq 0 && "$(decision)" == "none" && "$c" == *警告* ]]; then pass; else fail "decision=$(decision) out=$HOUT"; fi

it "(i) 文書の警告に、相手の識別子・登録の種類・調整の手順が含まれる"
case "$c" in
  *"session=s-a"*"kind=doc"*"coordinate"*"ListAgents"*"SendMessage"*) pass ;;
  *) fail "文脈: $c" ;;
esac

it "(e) 別の作業ツリーの同じ文書でも警告する（作業ツリーをまたぐ）"
pre_edit s-b "$wt2" "$wt2/docs/design.md"
assert_contains "$(context)" "session=s-a" "文脈"

it "(e) Write でも同じ（ツールの種別を問わない）"
hook_raw s-b "$(jq -n --arg cwd "$repo" --arg p "$repo/docs/design.md" '{hook_event_name:"PreToolUse",tool_name:"Write",cwd:$cwd,tool_input:{file_path:$p,content:"x"}}')"
assert_contains "$(context)" "kind=doc" "文脈"

it "(e) 登録していない別の文書は警告しない"
pre_edit s-b "$repo" "$repo/docs/other.md"
assert_quiet_pass "別の文書"

it "(g) 自分が登録した文書の Edit では止まらない"
pre_edit s-a "$repo" "$repo/docs/design.md"
assert_quiet_pass "自分の登録"

it "(k) 相手が release した後は、同じ文書の Edit が警告なしで通る"
ledger s-a "$repo" release doc docs/design.md >/dev/null
pre_edit s-b "$repo" "$repo/docs/design.md"
assert_quiet_pass "release 後"
reset_ledger

# ── (f) 失効 ─────────────────────────────────────────────────────────────────

it "(f) 持ち主の PID が消えた登録は失効し、通る"
sleep 600 &
PID_C=$!
ledger s-c "$repo" claim merge >/dev/null
pre_bash s-b "$repo" 'gh pr merge 9'
before="$(decision)"
post_bash s-b "$repo" 'gh pr merge 9'
kill "$PID_C" 2>/dev/null
wait "$PID_C" 2>/dev/null
pre_bash s-b "$repo" 'gh pr merge 9'
after="$(decision)"
if [[ "$before" == "deny" && "$after" == "none" ]]; then pass; else fail "消える前=$before 消えた後=$after"; fi
post_bash s-b "$repo" 'gh pr merge 9'
reset_ledger

# ── (j) SessionStart ─────────────────────────────────────────────────────────

it "(j) 他のセッションの登録が無いときは、SessionStart は何も出さない"
hook_raw s-b "$(pl_event SessionStart "$repo")"
if [[ "$HRC" -eq 0 && -z "$HOUT" ]]; then pass; else fail "rc=$HRC out=$HOUT"; fi

it "(j) SessionStart の出力に、他セッションの登録の要約が含まれる"
ledger s-a "$repo" claim issue 395 >/dev/null
ledger s-a "$repo" claim doc docs/design.md >/dev/null
hook_raw s-b "$(pl_event SessionStart "$repo")"
c="$(context)"
if [[ "$c" == *"2 件"* && "$c" == *"session=s-a"* && "$c" == *"kind=issue"* && "$c" == *"target=395"* \
  && "$c" == *"kind=doc"* && "$c" == *"target=docs/design.md"* && "$c" == *ListAgents* ]]; then
  pass
else
  fail "文脈: $c"
fi

it "(j) SessionStart の出力は hookEventName を持つ有効な JSON である"
assert_eq "$(printf '%s' "$HOUT" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" "SessionStart" "hookEventName"

it "(j) SessionStart は自分の登録を他セッションの登録として数えない"
hook_raw s-a "$(pl_event SessionStart "$repo")"
if [[ -z "$HOUT" ]]; then pass; else fail "out=$HOUT"; fi

# ── SessionEnd ───────────────────────────────────────────────────────────────

it "SessionEnd は自分の登録をすべて解放する"
pre_bash s-a "$repo" 'git rebase main'
ledger s-a "$repo" claim merge >/dev/null
hook_raw s-a "$(pl_event SessionEnd "$repo")"
rc_end="$HRC"
out_end="$HOUT"
pre_bash s-b "$repo" 'git rebase main'
d1="$(decision)"
post_bash s-b "$repo" 'git rebase main'
pre_bash s-b "$repo" 'gh pr merge 3'
d2="$(decision)"
post_bash s-b "$repo" 'gh pr merge 3'
list_after="$(ledger s-b "$repo" list --others)"
if [[ "$rc_end" -eq 0 && -z "$out_end" && "$d1" == "none" && "$d2" == "none" && -z "$list_after" ]]; then pass; else fail "rc=$rc_end out=$out_end git=$d1 merge=$d2 list=$list_after"; fi
reset_ledger

# ── 作業ツリーの別表記（正規化）──────────────────────────────────────────────

it "同じ作業ツリーの別表記（symlink 経由の cd・-C の ./ と末尾 /・..）でも、相手の git の登録と一致して拒否される"
ln -s "$repo" "$(dirname "$repo")/repo-link"
pre_bash s-a "$repo" 'git rebase main'
pre_bash s-b "$wt2" "cd $(dirname "$repo")/repo-link && git reset --hard"
n1="$(decision)"
pre_bash s-b "$wt2" "git -C $repo/./ checkout main"
n2="$(decision)"
pre_bash s-b "$wt2" "git -C $repo/../repo/ fetch"
n3="$(decision)"
if [[ "$n1" == "deny" && "$n2" == "deny" && "$n3" == "deny" ]]; then pass; else fail "symlink=$n1 ./=$n2 ..=$n3"; fi
post_bash s-a "$repo" 'git rebase main'
reset_ledger

# ── 解放の失敗 ───────────────────────────────────────────────────────────────

it "SessionEnd で解放の行を書けなかったときは、通したうえで、登録が残ったことを systemMessage で知らせる"
mkdir -p "$DIR"
ledger s-rel "$repo" claim issue 901 >/dev/null
rm -f "$DIR/s-rel.tsv"
mkdir "$DIR/s-rel.tsv"
hook_raw s-rel "$(pl_event SessionEnd "$repo")"
rel_rc="$HRC"
rel_msg="$(sysmsg)"
rmdir "$DIR/s-rel.tsv"
if [[ "$rel_rc" -eq 0 && "$rel_msg" == *"登録は残っています"* ]]; then pass; else fail "rc=$rel_rc out=$HOUT"; fi

it "PostToolUse で解放できなかったときも、拒否せず、systemMessage で知らせる"
pre_bash s-rel "$repo" 'gh pr merge 5'
rm -f "$DIR/s-rel.tsv.bak"
cp "$DIR/s-rel.tsv" "$DIR/s-rel.bak"
rm -f "$DIR/s-rel.tsv"
mkdir "$DIR/s-rel.tsv"
post_bash s-rel "$repo" 'gh pr merge 5'
rel_rc="$HRC"
rel_msg="$(sysmsg)"
rel_dec="$(decision)"
rmdir "$DIR/s-rel.tsv"
if [[ "$rel_rc" -eq 0 && "$rel_dec" == "none" && "$rel_msg" == *"登録は残っています"* ]]; then pass; else fail "rc=$rel_rc out=$HOUT"; fi
reset_ledger

# ── 更新（長いセッションの失効を避ける）──────────────────────────────────────

it "PreToolUse のたびに、自分の登録の更新時刻を新しくする（一定時間たっていれば）"
mkdir -p "$DIR"
old=$(( $(date +%s) - 1000 ))
printf '%s\tclaim\tissue\t900\t%s\t%s\n' "$old" "$PID_A" "$repo" > "$DIR/s-a.tsv"
pre_bash s-a "$repo" 'git status'
age="$(ledger s-b "$repo" list | sed -n 's/.*session=s-a.*age=\([0-9]*\)s.*/\1/p' | sed -n 1p)"
if [[ -n "$age" && "$age" -lt 100 ]]; then pass; else fail "age=$age"; fi

it "Edit の PreToolUse でも更新する"
printf '%s\tclaim\tissue\t900\t%s\t%s\n' "$old" "$PID_A" "$repo" > "$DIR/s-a.tsv"
pre_edit s-a "$repo" "$repo/docs/x.md"
age="$(ledger s-b "$repo" list | sed -n 's/.*session=s-a.*age=\([0-9]*\)s.*/\1/p' | sed -n 1p)"
if [[ -n "$age" && "$age" -lt 100 ]]; then pass; else fail "age=$age"; fi

it "最近更新したばかりなら、台帳へ行を足さない（台帳が膨らまない）"
n1="$(grep -c . "$DIR/s-a.tsv")"
pre_bash s-a "$repo" 'git status'
pre_bash s-a "$repo" 'git status'
n2="$(grep -c . "$DIR/s-a.tsv")"
assert_eq "$n2" "$n1" "行数"
reset_ledger

# ── (h) 台帳が壊れていても通る ────────────────────────────────────────────────

it "(h) 壊れた行があっても、他セッションの正しい登録は効き、通すべきものは通る"
mkdir -p "$DIR"
printf 'これは台帳の行ではない\n\001\002 garbage\n' > "$DIR/s-broken.tsv"
ledger s-a "$repo" claim merge >/dev/null
pre_bash s-b "$repo" 'gh pr merge 5'
d1="$(decision)"
post_bash s-a "$repo" 'gh pr merge 5'
ledger s-a "$repo" release >/dev/null
pre_bash s-b "$repo" 'gh pr merge 5'
d2="$(decision)"
if [[ "$d1" == "deny" && "$d2" == "none" && "$HRC" -eq 0 ]]; then pass; else fail "壊れた行つき=$d1 解放後=$d2"; fi
post_bash s-b "$repo" 'gh pr merge 5'
reset_ledger

it "(h) 台帳の置き場所を作れないときは、警告を出して通す（拒否しない）"
blocker="$(new_workdir)/not-a-dir"
: > "$blocker"
HOUT="$(printf '%s' "$(pl_bash PreToolUse "$repo" 'gh pr merge 5')" | SESSION_LEDGER_DIR="$blocker/ledger" SESSION_LEDGER_ID=s-b SESSION_LEDGER_PID="$PID_B" bash "$HOOK" 2>/dev/null)"
HRC=$?
if [[ "$HRC" -eq 0 && "$(decision)" == "none" && -n "$(sysmsg)" ]]; then pass; else fail "rc=$HRC out=$HOUT"; fi

it "(h) 警告の内容は、台帳を確かめずに通したことを伝える"
assert_contains "$(sysmsg)" "WARN" "systemMessage"

it "(h) git リポジトリの外では、警告を出して通す"
nogit="$(new_workdir)"
HOUT="$(printf '%s' "$(pl_bash PreToolUse "$nogit" 'gh pr merge 5')" | GIT_CEILING_DIRECTORIES="$nogit/.." SESSION_LEDGER_ID=s-b SESSION_LEDGER_PID="$PID_B" bash "$HOOK" 2>/dev/null)"
HRC=$?
if [[ "$HRC" -eq 0 && "$(decision)" == "none" && -n "$(sysmsg)" ]]; then pass; else fail "rc=$HRC out=$HOUT"; fi

it "(h) 台帳のスクリプトが見つからないときも、警告を出して通す"
solo="$(new_workdir)"
cp "$HOOK" "$solo/session-coord-hook.sh"
HOUT="$(printf '%s' "$(pl_bash PreToolUse "$repo" 'gh pr merge 5')" | SESSION_LEDGER_ID=s-b SESSION_LEDGER_PID="$PID_B" bash "$solo/session-coord-hook.sh" 2>/dev/null)"
HRC=$?
if [[ "$HRC" -eq 0 && "$(decision)" == "none" && "$(sysmsg)" == *見つかりません* ]]; then pass; else fail "rc=$HRC out=$HOUT"; fi

it "(h) ペイロードが空でも、警告を出して通す（終了コード 0）"
HOUT="$(printf '' | SESSION_LEDGER_ID=s-b SESSION_LEDGER_PID="$PID_B" bash "$HOOK" 2>/dev/null)"
HRC=$?
if [[ "$HRC" -eq 0 && "$(decision)" == "none" && -n "$(sysmsg)" ]]; then pass; else fail "rc=$HRC out=$HOUT"; fi

it "対象外のイベント・ツールは何も出さずに通す"
hook_raw s-b "$(jq -n --arg cwd "$repo" '{hook_event_name:"PreToolUse",tool_name:"Read",cwd:$cwd,tool_input:{file_path:"/x"}}')"
if [[ "$HRC" -eq 0 && -z "$HOUT" ]]; then pass; else fail "rc=$HRC out=$HOUT"; fi
hook_raw s-b "$(jq -n --arg cwd "$repo" '{hook_event_name:"Notification",cwd:$cwd}')"
it "未知のイベントも何も出さずに通す"
if [[ "$HRC" -eq 0 && -z "$HOUT" ]]; then pass; else fail "rc=$HRC out=$HOUT"; fi

# ── jq が無い環境 ────────────────────────────────────────────────────────────

# jq を含まない PATH を作る。フックと台帳が使う道具だけを入れる。
nojq="$(new_workdir)/bin"
mkdir -p "$nojq"
for t in bash git ps tr awk date mkdir cat sed head grep kill mktemp rm dirname basename sleep sort wc cut ls; do
  p="$(command -v "$t" 2>/dev/null || true)"
  [[ -n "$p" && -x "$p" ]] && ln -sf "$p" "$nojq/$t"
done

nojq_hook() { # セッション ペイロード
  HOUT="$(printf '%s' "$2" | PATH="$nojq" SESSION_LEDGER_ID="$1" SESSION_LEDGER_PID="$(pid_of "$1")" "$nojq/bash" "$HOOK" 2>/dev/null)"
  HRC=$?
}

it "jq が無くても、拒否の JSON を返す（有効な JSON で、相手の情報を含む）"
ledger s-a "$repo" claim merge >/dev/null
nojq_hook s-b "$(pl_bash PreToolUse "$repo" 'gh pr merge 5 --squash')"
d="$(decision)"
r="$(reason)"
if [[ "$HRC" -eq 0 && "$d" == "deny" && "$r" == *"session=s-a"* && "$r" == *"kind=merge"* && "$r" == *coordinate* ]]; then pass; else fail "rc=$HRC out=$HOUT"; fi

it "jq が無くても、拒否すべきでないものは通す"
nojq_hook s-b "$(pl_bash PreToolUse "$repo" 'git status')"
assert_quiet_pass "jq なし・対象外のコマンド"

it "jq が無くても、警告（additionalContext）と SessionStart の要約を返す"
ledger s-a "$repo" claim doc docs/design.md >/dev/null
nojq_hook s-b "$(pl_edit "$repo" "$repo/docs/design.md")"
w1="$(context)"
nojq_hook s-b "$(pl_event SessionStart "$repo")"
w2="$(context)"
if [[ "$w1" == *"kind=doc"* && "$w2" == *"session=s-a"* ]]; then pass; else fail "edit=$w1 start=$w2"; fi
ledger s-a "$repo" release >/dev/null
reset_ledger

exit_with_result
