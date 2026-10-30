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
#   (c) 相手が登録している作業ツリーでの git rebase は拒否される（add / commit / rm / mv も。#438）
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

it "settings.json: PostToolUseFailure の Bash からフックを呼ぶ（失敗した呼び出しの登録を解放する）"
assert_contains "$(wired '.hooks.PostToolUseFailure | map(select(.matcher == "Bash"))')" "session-coord-hook.sh" "PostToolUseFailure(Bash) のコマンド"

it "settings.json: SessionEnd からフックを呼ぶ"
assert_contains "$(wired '.hooks.SessionEnd')" "session-coord-hook.sh" "SessionEnd のコマンド"

it "settings.json: 既存の確認フックの配線は PreToolUse の先頭に残る（挙動を変えない）"
first_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$SETTINGS" 2>/dev/null)"
first_matcher="$(jq -r '.hooks.PreToolUse[0].matcher // empty' "$SETTINGS" 2>/dev/null)"
if [[ "$first_cmd" == *confirm-merge-hook.sh* && "$first_matcher" == "Bash" ]]; then pass; else fail "matcher=$first_matcher cmd=$first_cmd"; fi

it "settings.json: JSON として読める"
if jq -e . "$SETTINGS" >/dev/null 2>&1; then pass; else fail "JSON として読めない"; fi

it "settings.json: permissions は締める側のキーだけを持つ（許可リストを clone した全員へ配らない）"
# 許してよいキーの一覧はここだけ。allow / ask / deny / additionalDirectories / defaultMode は含めない。
bad="$(jq -r --argjson ok '["blockWritesOutsideWorkingDirectories"]' \
  '(.permissions // {}) | keys[] | select(. as $k | $ok | index($k) | not)' "$SETTINGS" 2>&1)"
if [[ -z "$bad" ]]; then pass; else fail "許可されないキー: $bad"; fi

it "settings.json: blockWritesOutsideWorkingDirectories が true"
assert_eq "$(jq -r '.permissions.blockWritesOutsideWorkingDirectories // empty' "$SETTINGS" 2>/dev/null)" "true" "blockWritesOutsideWorkingDirectories"

it "settings.json: 確認フックの hook には onFailure=block があり、セッション協調フックの hook には無い"
confirm_of="$(jq -r '[.. | objects | select((.command? // "") | contains("confirm-merge-hook.sh")) | .onFailure // "none"] | unique | join(",")' "$SETTINGS" 2>/dev/null)"
coord_of="$(jq -r '[.. | objects | select((.command? // "") | contains("session-coord-hook.sh")) | .onFailure // "none"] | unique | join(",")' "$SETTINGS" 2>/dev/null)"
assert_eq "$confirm_of" "block" "確認フックの onFailure"
assert_eq "$coord_of" "none" "セッション協調フックの onFailure"

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

pl_bash() { # イベント cwd コマンド [tool_use_id]
  jq -n --arg ev "$1" --arg cwd "$2" --arg cmd "$3" --arg id "${4:-}" \
    '{hook_event_name: $ev, tool_name: "Bash", cwd: $cwd, tool_input: {command: $cmd}}
     + (if $id != "" then {tool_use_id: $id} else {} end)'
}
pl_edit() { # cwd パス
  jq -n --arg cwd "$1" --arg p "$2" \
    '{hook_event_name: "PreToolUse", tool_name: "Edit", cwd: $cwd, tool_input: {file_path: $p, old_string: "a", new_string: "b"}}'
}
pl_event() { # イベント cwd
  jq -n --arg ev "$1" --arg cwd "$2" '{hook_event_name: $ev, cwd: $cwd}'
}

pre_bash() { hook_raw "$1" "$(pl_bash PreToolUse "$2" "$3" "${4:-}")"; }
post_bash() { hook_raw "$1" "$(pl_bash PostToolUse "$2" "$3" "${4:-}")"; }
fail_bash() { hook_raw "$1" "$(pl_bash PostToolUseFailure "$2" "$3" "${4:-}")"; }
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

it "(c) index を変える add / commit / rm / mv も同じ作業ツリーでは拒否される（#438）"
bad=""
for c in 'git add -A' 'git add docs/a.md' 'git commit -m "fix: x"' 'git commit --amend --no-edit' 'git rm --cached a' 'git mv a b' 'git -C . commit -m x'; do
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
for c in 'git status' 'git log --oneline -5' 'git diff HEAD' 'git stash list' 'git log --grep "docs: git rebase の手順"' 'echo "git rebase main"' "grep -rn 'git reset' ." 'git branch --list' 'gh pr view 5' 'gh pr create --title x --body y' 'gh issue view 395'; do
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

it "(d) 引数を取るオプション（-o / +o / -O / --rcfile）の引数をスクリプト名と取り違えず、ゲートとして拒否する"
bad=""
for c in 'bash -o pipefail scripts/verify.sh' 'bash +o history scripts/loop-gate.sh' 'bash -O extglob scripts/verify.sh' 'bash --rcfile /dev/null scripts/verify.sh' 'bash -eo pipefail scripts/verify.sh'; do
  pre_bash s-b "$repo" "$c"
  [[ "$(decision)" == "deny" ]] || bad="$bad | $c => $(decision)"
done
if [[ -z "$bad" ]]; then pass; else fail "拒否されなかった: $bad"; fi

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

# ── 失敗した呼び出し・拒否時・重複判定 ──────────────────────────────────────

it "失敗した Bash 呼び出し（PostToolUseFailure）でも、実行のあいだだけの登録を解放する"
pre_bash s-a "$repo" 'bash scripts/verify.sh' toolu_x
pre_bash s-b "$repo" 'bash scripts/loop-gate.sh'
held="$(decision)"
hook_raw s-a "$(jq -n --arg cwd "$repo" --arg cmd 'bash scripts/verify.sh' '{hook_event_name:"PostToolUseFailure",tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd},tool_use_id:"toolu_x",error:"Exit code 1",is_interrupt:false}')"
fail_rc="$HRC"
pre_bash s-b "$repo" 'bash scripts/loop-gate.sh'
if [[ "$held" == "deny" && "$fail_rc" -eq 0 && "$(decision)" == "none" ]]; then pass; else fail "失敗前=$held rc=$fail_rc 解放後=$(decision) out=$HOUT"; fi
post_bash s-b "$repo" 'bash scripts/loop-gate.sh'
reset_ledger

it "拒否した呼び出しでは、issue を登録しない（git が衝突して checkout -b が拒否される）"
pre_bash s-a "$repo" 'git rebase main'
pre_bash s-b "$repo" 'git checkout -b feat/395-x'
d_issue="$(decision)"
run_issue="$(ledger s-a "$repo" check issue 395 | sed -n 1p)"
if [[ "$d_issue" == "deny" && "$run_issue" == "LEDGER_OK" ]] && ! has_claim s-b issue; then pass; else fail "判定=$d_issue 相手から見た issue=$run_issue"; fi
post_bash s-a "$repo" 'git rebase main'
reset_ledger

it "拒否しない checkout -b では、従来どおり issue を登録する"
pre_bash s-b "$repo" 'git checkout -b feat/395-x'
if [[ "$(decision)" == "none" ]] && has_claim s-b issue; then pass; else fail "out=$HOUT"; fi
post_bash s-b "$repo" 'git checkout -b feat/395-x'
reset_ledger

it "ブランチの作成が失敗（PostToolUseFailure）したら、その呼び出しで新しく登録した issue を解放する"
pre_bash s-b "$repo" 'git checkout -b feat/395-x' toolu_f1
held="$(ledger s-a "$repo" check issue 395 | sed -n 1p)"
fail_bash s-b "$repo" 'git checkout -b feat/395-x' toolu_f1
gone="$(ledger s-a "$repo" check issue 395 | sed -n 1p)"
if [[ "$held" == "LEDGER_WARN" && "$gone" == "LEDGER_OK" ]]; then pass; else fail "失敗前=$held 失敗後=$gone"; fi
reset_ledger

it "(#514) ブランチを作ってから失敗した呼び出し（git switch -c 77-x && npm test）では、issue の登録を残す"
pre_bash s-b "$repo" 'git switch -c 77-x && npm test' toolu_f4
git -C "$repo" branch 77-x >/dev/null 2>&1
fail_bash s-b "$repo" 'git switch -c 77-x && npm test' toolu_f4
kept="$(ledger s-a "$repo" check issue 77 | sed -n 1p)"
git -C "$repo" branch -D 77-x >/dev/null 2>&1
assert_eq "$kept" "LEDGER_WARN" "ブランチが作られた後の失敗"
reset_ledger

it "(#514) ブランチが作られずに失敗した呼び出しでは、従来どおり issue の登録を解放する"
pre_bash s-b "$repo" 'git switch -c 88-x && npm test' toolu_f5
fail_bash s-b "$repo" 'git switch -c 88-x && npm test' toolu_f5
gone="$(ledger s-a "$repo" check issue 88 | sed -n 1p)"
assert_eq "$gone" "LEDGER_OK" "ブランチが作られない失敗"
reset_ledger

it "(#514) 同じ名前のブランチが呼び出しの前から既にあり、checkout -b が失敗した呼び出しでは、issue の登録を解放する"
git -C "$repo" branch feat/66-x >/dev/null 2>&1
pre_bash s-b "$repo" 'git checkout -b feat/66-x' toolu_g1
fail_bash s-b "$repo" 'git checkout -b feat/66-x' toolu_g1
gone="$(ledger s-a "$repo" check issue 66 | sed -n 1p)"
git -C "$repo" branch -D feat/66-x >/dev/null 2>&1
assert_eq "$gone" "LEDGER_OK" "既にあったブランチ"
reset_ledger

it "(#514) 同じ番号の別のブランチが（別の作業ツリーを含め）あっても、作るのに失敗した呼び出しでは、issue の登録を解放する"
git -C "$repo" branch 55-y >/dev/null 2>&1
pre_bash s-b "$repo" 'git switch -c 55-x && false' toolu_g2
fail_bash s-b "$repo" 'git switch -c 55-x && false' toolu_g2
gone="$(ledger s-a "$repo" check issue 55 | sed -n 1p)"
git -C "$repo" branch -D 55-y >/dev/null 2>&1
assert_eq "$gone" "LEDGER_OK" "同じ番号の別のブランチ"
reset_ledger

repo3="$(dirname "$repo")/repo3"
mkdir -p "$repo3"
(
  cd "$repo3" || exit 1
  git init -q . 2>/dev/null
  git config user.name test
  git config user.email test@example.com
  git config commit.gpgsign false
  echo x > f.txt
  git add f.txt
  git commit -q -m init
) >/dev/null 2>&1

it "(#514) 別のリポジトリへ cd してブランチを作ってから失敗した呼び出しでは、issue の登録を残す"
pre_bash s-b "$repo" "cd $repo3 && git switch -c 44-x && false" toolu_g3
git -C "$repo3" branch 44-x >/dev/null 2>&1
fail_bash s-b "$repo" "cd $repo3 && git switch -c 44-x && false" toolu_g3
kept="$(ledger s-a "$repo" check issue 44 | sed -n 1p)"
git -C "$repo3" branch -D 44-x >/dev/null 2>&1
assert_eq "$kept" "LEDGER_WARN" "cd 先で作ったブランチ"
reset_ledger

it "(#514) git -C で別のリポジトリにブランチを作ってから失敗した呼び出しでは、issue の登録を残す"
pre_bash s-b "$repo" "git -C $repo3 switch -c 43-x && make" toolu_g4
git -C "$repo3" branch 43-x >/dev/null 2>&1
fail_bash s-b "$repo" "git -C $repo3 switch -c 43-x && make" toolu_g4
kept="$(ledger s-a "$repo" check issue 43 | sed -n 1p)"
git -C "$repo3" branch -D 43-x >/dev/null 2>&1
assert_eq "$kept" "LEDGER_WARN" "git -C 先で作ったブランチ"
reset_ledger

it "(#514) git -C を重ねた（後の相対パスは前の -C から解決される）ブランチの作成が失敗しても、作れていれば登録を残す"
pre_bash s-b "$repo" "git -C $(dirname "$repo3") -C repo3 switch -c 42-x && false" toolu_g6
git -C "$repo3" branch 42-x >/dev/null 2>&1
fail_bash s-b "$repo" "git -C $(dirname "$repo3") -C repo3 switch -c 42-x && false" toolu_g6
kept="$(ledger s-a "$repo" check issue 42 | sed -n 1p)"
git -C "$repo3" branch -D 42-x >/dev/null 2>&1
assert_eq "$kept" "LEDGER_WARN" "-C を重ねた先で作ったブランチ"
reset_ledger

repo5="$(dirname "$repo")/repo5"
mkdir -p "$repo5"
git -C "$repo5" init -q . >/dev/null 2>&1

it "(#514) まだコミットの無いリポジトリでブランチを作ってから失敗した呼び出しでは、issue の登録を残す"
pre_bash s-b "$repo" "git -C $repo5 checkout -b 41-x && false" toolu_g7
git -C "$repo5" symbolic-ref HEAD refs/heads/41-x >/dev/null 2>&1
fail_bash s-b "$repo" "git -C $repo5 checkout -b 41-x && false" toolu_g7
kept="$(ledger s-a "$repo" check issue 41 | sed -n 1p)"
assert_eq "$kept" "LEDGER_WARN" "コミットの無いリポジトリ"
reset_ledger

it "(#514) コミットの無いリポジトリで HEAD が呼び出しの前から指しているブランチは、作らずに失敗したら解放する"
repo7="$(dirname "$repo")/repo7"
mkdir -p "$repo7"
git -C "$repo7" init -q . >/dev/null 2>&1
git -C "$repo7" symbolic-ref HEAD refs/heads/39-x >/dev/null 2>&1
pre_bash s-b "$repo" "git -C $repo7 switch -c 39-x" toolu_g9
fail_bash s-b "$repo" "git -C $repo7 switch -c 39-x" toolu_g9
gone="$(ledger s-a "$repo" check issue 39 | sed -n 1p)"
assert_eq "$gone" "LEDGER_OK" "前から HEAD が指しているブランチ"
reset_ledger

# タブ・改行を含むパス（#528）。台帳はタブ区切り、登録の対象と解放の一覧は改行区切りなので、
# 含むパスは 1 つの値として持てない。入口（フックの作業ディレクトリ・cd 先・git -C 先・作る
# ブランチの控え）で除き、警告して通す。末尾がタブ・改行のパスは、読み取りや $(...) で
# 末尾が削られてから判定すると見分けられないため、別々に確かめる。
count_claims() { # セッション。台帳に残った claim の行数（種類を問わない）
  if [[ -f "$DIR/$1.tsv" ]]; then grep -c "$(printf '\tclaim\t')" "$DIR/$1.tsv"; else echo 0; fi
}
unsafe_n=60
check_unsafe_path() { # ラベル パス
  local label="$1" p="$2" bad="" id n mark
  unsafe_n=$((unsafe_n + 1))
  n="$unsafe_n"
  mkdir -p "$p"
  git -C "$p" init -q . >/dev/null 2>&1
  # git -C 先
  id="toolu_u${n}a"
  pre_bash s-b "$repo" "git -C \"$p\" fetch" "$id"
  [[ "$HRC" -eq 0 && "$(decision)" == "none" ]] || bad="$bad | -C 先の判定: $HOUT"
  [[ "$(count_claims s-b)" == "0" ]] || bad="$bad | -C 先で登録が残った: $(count_claims s-b)"
  [[ "$(sysmsg)" == *"タブか改行"* ]] || bad="$bad | -C 先の警告が無い: $HOUT"
  post_bash s-b "$repo" "git -C \"$p\" fetch" "$id"
  reset_ledger
  # 重ねた -C 先
  id="toolu_u${n}b"
  pre_bash s-b "$repo" "git -C \"${p%/*}\" -C \"${p##*/}\" fetch" "$id"
  [[ "$(count_claims s-b)" == "0" ]] || bad="$bad | 重ねた -C 先で登録が残った: $(count_claims s-b)"
  post_bash s-b "$repo" "git -C \"${p%/*}\" -C \"${p##*/}\" fetch" "$id"
  reset_ledger
  # cd 先
  id="toolu_u${n}c"
  pre_bash s-b "$repo" "cd \"$p\" && git fetch" "$id"
  [[ "$HRC" -eq 0 && "$(decision)" == "none" ]] || bad="$bad | cd 先の判定: $HOUT"
  [[ "$(count_claims s-b)" == "0" ]] || bad="$bad | cd 先で登録が残った: $(count_claims s-b)"
  post_bash s-b "$repo" "cd \"$p\" && git fetch" "$id"
  reset_ledger
  # フックの作業ディレクトリ自身が危険な作業ツリーのとき、その作業ツリーは登録しない
  id="toolu_u${n}d"
  pre_bash s-b "$p" 'git fetch' "$id"
  [[ "$HRC" -eq 0 && "$(decision)" == "none" ]] || bad="$bad | 作業ディレクトリの判定: $HOUT"
  [[ "$(count_claims s-b)" == "0" ]] || bad="$bad | 作業ディレクトリで登録が残った: $(count_claims s-b)"
  [[ "$(sysmsg)" == *"タブか改行"* ]] || bad="$bad | 作業ディレクトリの警告が無い: $HOUT"
  reset_ledger
  # 作るブランチの控え（印に壊れたパスを書かず、失敗時は issue を解放する）
  id="toolu_u${n}e"
  pre_bash s-b "$repo" "git -C \"$p\" checkout -b ${n}-x && false" "$id"
  mark="$(cat "${TMPDIR:-/tmp}/session-coord-$id" 2>/dev/null)"
  case "$mark" in
    *$'\t'*) bad="$bad | 印にタブ区切りの欄がある: $mark" ;;
    '' | "$n") ;;
    *) bad="$bad | 印の中身: $mark" ;;
  esac
  [[ "$(count_claims s-b)" == "1" ]] || bad="$bad | ブランチの作成で issue 以外が登録された: $(count_claims s-b)"
  git -C "$p" symbolic-ref HEAD "refs/heads/${n}-x" >/dev/null 2>&1
  fail_bash s-b "$repo" "git -C \"$p\" checkout -b ${n}-x && false" "$id"
  [[ "$(ledger s-a "$repo" check issue "$n" | sed -n 1p)" == "LEDGER_OK" ]] || bad="$bad | 失敗後も issue が残った"
  reset_ledger
  if [[ -z "$bad" ]]; then pass; else fail "$label:$bad"; fi
}

base_dir="$(dirname "$repo")"
it "(#528) パスにタブを含むとき、台帳に誤った登録が残らず、印に壊れたパスを書かない"
check_unsafe_path "タブ" "$base_dir/re"$'\t'"po6"
it "(#528) パスの末尾がタブのときも、台帳に誤った登録が残らない"
check_unsafe_path "末尾のタブ" "$base_dir/repo8"$'\t'
it "(#528) パスに改行を含むとき、台帳に誤った登録が残らない"
check_unsafe_path "改行" "$base_dir/re"$'\n'"po9"
it "(#528) パスの末尾が改行のときも、台帳に誤った登録が残らない"
check_unsafe_path "末尾の改行" "$base_dir/repo10"$'\n'

# 解放の経路は、cwd が危険なパスでも続ける（#528）。安全な cwd で登録した分を、危険な cwd の
# PostToolUse / PostToolUseFailure / SessionEnd が解放しないと、失効するまで他のセッションを
# 止め続ける。早期終了は登録する経路（PreToolUse）に限る。危険な cwd は repo の下の
# サブディレクトリ（同じ台帳を使う）にする。
check_release_from_unsafe_cwd() { # ラベル サブディレクトリ名
  local label="$1" p="$repo/$2" bad="" id ev
  unsafe_n=$((unsafe_n + 1))
  mkdir -p "$p"
  for ev in post fail end; do
    reset_ledger
    id="toolu_r${unsafe_n}${ev}"
    pre_bash s-b "$repo" "git fetch && gh pr merge 5 && git checkout -b ${unsafe_n}-r" "$id"
    [[ -f "${TMPDIR:-/tmp}/session-coord-${id}.dirs" ]] || bad="$bad | $ev: 登録の印が無い"
    case "$ev" in
      post) post_bash s-b "$p" "git fetch && gh pr merge 5 && git checkout -b ${unsafe_n}-r" "$id" ;;
      fail) fail_bash s-b "$p" "git fetch && gh pr merge 5 && git checkout -b ${unsafe_n}-r" "$id" ;;
      end) hook_raw s-b "$(pl_event SessionEnd "$p")" ;;
    esac
    [[ "$(ledger s-a "$repo" check merge | sed -n 1p)" == "LEDGER_OK" ]] || bad="$bad | $ev: merge の登録が残った"
    [[ "$(ledger s-a "$repo" check git "$repo" | sed -n 1p)" == "LEDGER_OK" ]] || bad="$bad | $ev: git の登録が残った"
    # issue は SessionEnd で解放される（成功した呼び出しでは SessionEnd まで持つ仕様）。
    if [[ "$ev" == "end" ]]; then
      [[ "$(ledger s-a "$repo" check issue "$unsafe_n" | sed -n 1p)" == "LEDGER_OK" ]] || bad="$bad | end: issue の登録が残った"
    fi
    [[ "$ev" == "end" || ! -f "${TMPDIR:-/tmp}/session-coord-${id}.dirs" ]] || bad="$bad | $ev: 印が残った"
    rm -f "${TMPDIR:-/tmp}/session-coord-${id}.dirs" "${TMPDIR:-/tmp}/session-coord-${id}"
  done
  reset_ledger
  rm -rf "$p"
  if [[ -z "$bad" ]]; then pass; else fail "$label:$bad"; fi
}
it "(#528) cwd がタブを含むパスでも、PostToolUse / PostToolUseFailure / SessionEnd は登録を解放する"
check_release_from_unsafe_cwd "タブ" "sub"$'\t'"dir"
it "(#528) cwd の末尾がタブのパスでも、登録を解放する"
check_release_from_unsafe_cwd "末尾のタブ" "sub"$'\t'
it "(#528) cwd が改行を含むパスでも、登録を解放する"
check_release_from_unsafe_cwd "改行" "sub"$'\n'"dir"
it "(#528) cwd の末尾が改行のパスでも、登録を解放する"
check_release_from_unsafe_cwd "末尾の改行" "sub"$'\n'

it "(#528) Edit の file_path がタブを含むとき、別のパスの check doc は走らない"
ledger s-a "$repo" claim doc "docs/a b" >/dev/null
pre_edit s-b "$repo" "$repo/docs/a"$'\t'"b"
assert_quiet_pass "タブを含む file_path"
reset_ledger

it "(#528) Edit の file_path の末尾が改行のとき、末尾が削られた別のパスの check doc は走らない"
ledger s-a "$repo" claim doc docs/nl.md >/dev/null
pre_edit s-b "$repo" "$repo/docs/nl.md"$'\n'
assert_quiet_pass "末尾が改行の file_path"
pre_edit s-b "$repo" "$repo/docs/nl.md"
if [[ "$(context)" == *"kind=doc"* ]]; then pass; else fail "対照: 安全なパスの警告が出ない: $HOUT"; fi
reset_ledger

it "(#528) シンボリックリンクの先が末尾が改行のパスでも、解決した後の値を判定して登録しない"
real_nl="$base_dir/real_nl"$'\n'
mkdir -p "$real_nl"
git -C "$real_nl" init -q . >/dev/null 2>&1
ln -sfn "$real_nl" "$base_dir/lnk_nl"
pre_bash s-b "$repo" "git -C \"$base_dir/lnk_nl\" fetch" toolu_l1
if [[ "$HRC" -eq 0 && "$(decision)" == "none" && "$(count_claims s-b)" == "0" ]]; then pass; else fail "claims=$(count_claims s-b) out=$HOUT"; fi
reset_ledger

it "(#528) 改行を含むクォートの語より後ろの語も、コマンドの判定の対象になる（旧版は 1 行目で切れていた）"
pre_bash s-b "$repo" 'MSG="a
b" gh pr merge 5' toolu_m1
if has_claim s-b merge; then pass; else fail "merge が登録されない: $HOUT"; fi
post_bash s-b "$repo" 'MSG="a
b" gh pr merge 5' toolu_m1
reset_ledger

# 守るのは「危険なパスを台帳の欄に書かない」ことだけで、cwd が危険だからといって何もしない形には
# しない（#528）。パスを持たない種類（merge・gate）は、cwd が危険でも確かめて登録し、拒否も効かせる。
# 危険な cwd は repo の下のサブディレクトリ（同じ台帳を使う）にする。
check_pathless_in_unsafe_cwd() { # ラベル サブディレクトリ名
  local label="$1" p="$repo/$2" bad="" id nxd
  unsafe_n=$((unsafe_n + 1))
  mkdir -p "$p"
  reset_ledger
  # 相手が merge / gate を持っているとき、危険な cwd からの merge / gate は拒否される
  ledger s-a "$repo" claim merge >/dev/null
  pre_bash s-b "$p" 'gh pr merge 5' "toolu_p${unsafe_n}a"
  [[ "$(decision)" == "deny" ]] || bad="$bad | merge が拒否されない: $HOUT"
  reset_ledger
  ledger s-a "$repo" claim gate >/dev/null
  pre_bash s-b "$p" 'bash scripts/verify.sh' "toolu_p${unsafe_n}b"
  [[ "$(decision)" == "deny" ]] || bad="$bad | gate が拒否されない: $HOUT"
  reset_ledger
  # 相手がいなければ登録し、登録は他のセッションを止め、解放後は止めない。欄に危険な値は無い
  id="toolu_p${unsafe_n}c"
  pre_bash s-b "$p" 'gh pr merge 5' "$id"
  [[ "$(decision)" == "none" ]] || bad="$bad | 単独の merge が通らない: $HOUT"
  [[ "$(ledger s-a "$repo" check merge | sed -n 1p)" == "LEDGER_DENY" ]] || bad="$bad | merge が登録されない"
  post_bash s-b "$p" 'gh pr merge 5' "$id"
  [[ "$(ledger s-a "$repo" check merge | sed -n 1p)" == "LEDGER_OK" ]] || bad="$bad | merge が解放されない"
  reset_ledger
  # 安全なリポジトリの中の危険なサブディレクトリでの git 操作は、リポジトリを登録する
  pre_bash s-b "$p" 'git fetch' "toolu_p${unsafe_n}d"
  [[ "$(ledger s-a "$repo" check git "$repo" | sed -n 1p)" == "LEDGER_DENY" ]] || bad="$bad | サブディレクトリの git 操作が登録されない: $HOUT"
  post_bash s-b "$p" 'git fetch' "toolu_p${unsafe_n}d"
  reset_ledger
  # 絶対パスの git -C は、基準（cd 先）が危険でも、その先だけで判定する
  nxd="$base_dir/nx${unsafe_n}"$'\t'"x"
  pre_bash s-b "$repo" "cd \"$nxd\" && git -C \"$repo\" fetch" "toolu_p${unsafe_n}e"
  [[ "$(ledger s-a "$repo" check git "$repo" | sed -n 1p)" == "LEDGER_DENY" ]] || bad="$bad | 絶対パスの -C 先が登録されない: $HOUT"
  post_bash s-b "$repo" "cd \"$nxd\" && git -C \"$repo\" fetch" "toolu_p${unsafe_n}e"
  reset_ledger
  # 安全な絶対パスの file_path は、cwd が危険でも確かめる
  ledger s-a "$repo" claim doc docs/x.md >/dev/null
  pre_edit s-b "$p" "$repo/docs/x.md"
  [[ "$(context)" == *"kind=doc"* ]] || bad="$bad | 文書の確認が飛ばされた: $HOUT"
  reset_ledger
  rm -rf "$p"
  if [[ -z "$bad" ]]; then pass; else fail "$label:$bad"; fi
}
it "(#528) cwd がタブを含むパスでも、パスを持たない種類は確かめて拒否し、パスを持つ処理は安全な値で続ける"
check_pathless_in_unsafe_cwd "タブ" "sub"$'\t'"dir"
it "(#528) cwd の末尾がタブのパスでも、同じ"
check_pathless_in_unsafe_cwd "末尾のタブ" "sub"$'\t'
it "(#528) cwd が改行を含むパスでも、同じ"
check_pathless_in_unsafe_cwd "改行" "sub"$'\n'"dir"
it "(#528) cwd の末尾が改行のパスでも、同じ"
check_pathless_in_unsafe_cwd "末尾の改行" "sub"$'\n'

# 危険な cwd で登録した merge / gate の解放は、PostToolUse の cwd が変わっても（コマンドの cd）、
# 登録した台帳へ行う。印には、登録した cwd を符号化して控える（#528）。登録した台帳を失うと、
# merge の登録が失効まで残り、他のセッションの merge を拒否し続ける。
check_cd_away_release() { # ラベル 危険なサブディレクトリ名
  local label="$1" p="$repo/$2" bad="" id other rows cmd
  unsafe_n=$((unsafe_n + 1))
  other="$base_dir/other_${unsafe_n}"
  mkdir -p "$p" "$other"
  git -C "$other" init -q . >/dev/null 2>&1
  cmd="cd \"$other\" && gh pr merge 5"
  # 危険なサブディレクトリの cwd（安全なリポジトリの中）から cd して merge する
  reset_ledger
  id="toolu_c${unsafe_n}a"
  pre_bash s-b "$p" "$cmd" "$id"
  [[ "$(decision)" == "none" ]] || bad="$bad | merge が通らない: $HOUT"
  [[ "$(ledger s-a "$repo" check merge | sed -n 1p)" == "LEDGER_DENY" ]] || bad="$bad | merge が登録されない"
  post_bash s-b "$other" "$cmd" "$id"
  [[ "$(ledger s-a "$repo" check merge | sed -n 1p)" == "LEDGER_OK" ]] || bad="$bad | cd した先の PostToolUse で、元の台帳の merge が解放されない"
  rows="$(grep -c "$(printf '\trelease\t')" "$DIR/s-b.tsv" 2>/dev/null)"
  [[ "$rows" == "1" ]] || bad="$bad | 解放の行が $rows 件（1 件のはず）"
  reset_ledger
  # cd せずに同じ cwd で解放するときも、解放の行は 1 件
  id="toolu_c${unsafe_n}b"
  pre_bash s-b "$p" 'gh pr merge 5' "$id"
  post_bash s-b "$p" 'gh pr merge 5' "$id"
  rows="$(grep -c "$(printf '\trelease\t')" "$DIR/s-b.tsv" 2>/dev/null)"
  [[ "$rows" == "1" ]] || bad="$bad | 同じ cwd での解放の行が $rows 件（1 件のはず）"
  reset_ledger
  # cd しない呼び出しで、PostToolUse の cwd だけが別のリポジトリになっても、解放の行き先を失わない
  id="toolu_c${unsafe_n}c"
  pre_bash s-b "$p" 'gh pr merge 5' "$id"
  post_bash s-b "$other" 'gh pr merge 5' "$id"
  [[ "$(ledger s-a "$repo" check merge | sed -n 1p)" == "LEDGER_OK" ]] || bad="$bad | merge の解放先を失った"
  reset_ledger
  rm -rf "$p" "$other"
  if [[ -z "$bad" ]]; then pass; else fail "$label:$bad"; fi
}
check_cd_away_unsafe_root() { # ラベル 危険な作業ツリーのパス（それ自身がリポジトリ）
  local label="$1" p="$2" bad="" id other cmd
  unsafe_n=$((unsafe_n + 1))
  other="$base_dir/other_${unsafe_n}"
  mkdir -p "$p" "$other"
  git -C "$p" init -q . >/dev/null 2>&1
  git -C "$other" init -q . >/dev/null 2>&1
  cmd="cd \"$other\" && gh pr merge 5"
  id="toolu_c${unsafe_n}d"
  pre_bash s-b "$p" "$cmd" "$id"
  [[ "$(decision)" == "none" ]] || bad="$bad | merge が通らない: $HOUT"
  [[ "$(ledger s-a "$p" check merge | sed -n 1p)" == "LEDGER_DENY" ]] || bad="$bad | 危険な作業ツリーで merge が登録されない"
  post_bash s-b "$other" "$cmd" "$id"
  [[ "$(ledger s-a "$p" check merge | sed -n 1p)" == "LEDGER_OK" ]] || bad="$bad | 危険な作業ツリーの merge が解放されない"
  rm -f "${TMPDIR:-/tmp}/session-coord-${id}.dirs"
  rm -rf "$p" "$other"
  if [[ -z "$bad" ]]; then pass; else fail "$label:$bad"; fi
}
it "(#528) 危険なサブディレクトリ（タブ）の cwd から cd して merge しても、PostToolUse の cwd が変わっても元の台帳を解放し、解放の行は重複しない"
check_cd_away_release "タブ" "sub"$'\t'"dir"
it "(#528) 同じ（末尾の改行）"
check_cd_away_release "末尾の改行" "sub"$'\n'
it "(#528) 同じ（改行）"
check_cd_away_release "改行" "sub"$'\n'"dir"
it "(#528) 危険な作業ツリーそのものから cd して merge しても、解放の行き先を失わない（タブ・改行）"
check_cd_away_unsafe_root "タブ" "$base_dir/ur"$'\t'"x"
it "(#528) 同じ（末尾の改行）"
check_cd_away_unsafe_root "末尾の改行" "$base_dir/ur"$'\n'

# 存在しない危険な -C 先は、安全な基準へ置き換えて、基準のリポジトリの git 操作として登録しない（#528）。
check_missing_unsafe_dash_c() { # ラベル 存在しない危険なパス
  local label="$1" nx="$2" bad="" id
  unsafe_n=$((unsafe_n + 1))
  id="toolu_m${unsafe_n}"
  reset_ledger
  pre_bash s-b "$repo" "git -C \"$nx\" fetch" "$id"
  [[ "$HRC" -eq 0 && "$(decision)" == "none" ]] || bad="$bad | 判定: $HOUT"
  [[ "$(count_claims s-b)" == "0" ]] || bad="$bad | 基準の git 操作として登録された: $(count_claims s-b)"
  [[ "$(sysmsg)" == *"タブか改行"* ]] || bad="$bad | 警告が無い: $HOUT"
  post_bash s-b "$repo" "git -C \"$nx\" fetch" "$id"
  reset_ledger
  if [[ -z "$bad" ]]; then pass; else fail "$label:$bad"; fi
}
it "(#528) 存在しない危険な -C 先（タブ）は、基準の git 操作として登録しない"
check_missing_unsafe_dash_c "タブ" "$base_dir/none"$'\t'"x"
it "(#528) 存在しない危険な -C 先（改行）は、基準の git 操作として登録しない"
check_missing_unsafe_dash_c "改行" "$base_dir/none"$'\n'"x"
it "(#528) 存在しない危険な -C 先（末尾の改行）は、基準の git 操作として登録しない"
check_missing_unsafe_dash_c "末尾の改行" "$base_dir/none"$'\n'

it "(#528) 危険な作業ツリーでブランチを作っても、同じ警告は 1 行だけ出る"
unsafe_n=$((unsafe_n + 1))
wl="$base_dir/wl"$'\t'"x"
mkdir -p "$wl"
git -C "$wl" init -q . >/dev/null 2>&1
pre_bash s-b "$repo" "git -C \"$wl\" checkout -b ${unsafe_n}-x" "toolu_w${unsafe_n}"
wn="$(printf '%s\n' "$(sysmsg)" | command grep -c "タブか改行")"
fail_bash s-b "$repo" "git -C \"$wl\" checkout -b ${unsafe_n}-x" "toolu_w${unsafe_n}"
pre_bash s-b "$wl" "git checkout -b ${unsafe_n}-y" "toolu_w${unsafe_n}b"
wn2="$(printf '%s\n' "$(sysmsg)" | command grep -c "タブか改行")"
fail_bash s-b "$wl" "git checkout -b ${unsafe_n}-y" "toolu_w${unsafe_n}b"
if [[ "$wn" == "1" && "$wn2" == "1" ]]; then pass; else fail "-C 先=$wn cwd=$wn2"; fi
reset_ledger

it "(#514) 番号だけの古い書式の印は、従来どおり失敗時に解放する"
pre_bash s-b "$repo" 'git checkout -b feat/33-x' toolu_g5
printf '33\n' >"${TMPDIR:-/tmp}/session-coord-toolu_g5"
git -C "$repo" branch feat/33-x >/dev/null 2>&1
fail_bash s-b "$repo" 'git checkout -b feat/33-x' toolu_g5
gone="$(ledger s-a "$repo" check issue 33 | sed -n 1p)"
git -C "$repo" branch -D feat/33-x >/dev/null 2>&1
assert_eq "$gone" "LEDGER_OK" "古い書式の印"
reset_ledger

it "対照: 呼び出しの前から持っていた issue の登録は、失敗しても外さない"
ledger s-b "$repo" claim issue 395 >/dev/null
pre_bash s-b "$repo" 'git checkout -b feat/395-x' toolu_f2
fail_bash s-b "$repo" 'git checkout -b feat/395-x' toolu_f2
kept="$(ledger s-a "$repo" check issue 395 | sed -n 1p)"
assert_eq "$kept" "LEDGER_WARN" "前から持っていた issue"
reset_ledger

it "対照: ブランチの作成が成功（PostToolUse）したら、issue は SessionEnd まで持つ"
pre_bash s-b "$repo" 'git checkout -b feat/395-x' toolu_f3
post_bash s-b "$repo" 'git checkout -b feat/395-x' toolu_f3
kept="$(ledger s-a "$repo" check issue 395 | sed -n 1p)"
hook_raw s-b "$(pl_event SessionEnd "$repo")"
ended="$(ledger s-a "$repo" check issue 395 | sed -n 1p)"
if [[ "$kept" == "LEDGER_WARN" && "$ended" == "LEDGER_OK" ]]; then pass; else fail "成功後=$kept SessionEnd 後=$ended"; fi
reset_ledger

it "失敗の解放は、その呼び出しの tool_use_id の印だけを使う（別の呼び出しの失敗では外さない）"
pre_bash s-b "$repo" 'git checkout -b feat/395-x' toolu_f4
fail_bash s-b "$repo" 'git checkout -b feat/395-y' toolu_other
kept="$(ledger s-a "$repo" check issue 395 | sed -n 1p)"
fail_bash s-b "$repo" 'git checkout -b feat/395-x' toolu_f4
if [[ "$kept" == "LEDGER_WARN" ]]; then pass; else fail "別の呼び出しの失敗で外れた: $kept"; fi
reset_ledger

it "1 つのコマンドで /repo2 のような接頭辞が共通の作業ツリーと /repo を対象にしても、両方を登録する"
repo2="${repo}2"
mkdir -p "$repo2"
(cd "$repo2" && git init -q . 2>/dev/null && git config user.name t && git config user.email t@example.com && git commit -q --allow-empty -m i) >/dev/null 2>&1
pre_bash s-a "$repo" "git -C $repo2 fetch; git -C $repo fetch"
pre_bash s-b "$repo" 'git fetch'
c1="$(decision)"
pre_bash s-b "$repo2" 'git fetch'
c2="$(decision)"
if [[ "$c1" == "deny" && "$c2" == "deny" ]]; then pass; else fail "repo=$c1 repo2=$c2"; fi
post_bash s-a "$repo" "git -C $repo2 fetch; git -C $repo fetch"
reset_ledger


# ── 呼び出しごとの解放（#425）──────────────────────────────────────────────────

it "(#425) 同じセッションで merge が並行しても、先に終わった呼び出しの解放で、他方の登録は外れない"
pre_bash s-a "$repo" 'gh pr merge 5 --squash' toolu_m1
pre_bash s-a "$repo" 'gh pr merge 6 --squash' toolu_m2
post_bash s-a "$repo" 'gh pr merge 5 --squash' toolu_m1
held="$(ledger s-b "$repo" check merge | sed -n 1p)"
post_bash s-a "$repo" 'gh pr merge 6 --squash' toolu_m2
gone="$(ledger s-b "$repo" check merge | sed -n 1p)"
if [[ "$held" == "LEDGER_DENY" && "$gone" == "LEDGER_OK" ]]; then pass; else fail "1 本目の後=$held 2 本目の後=$gone"; fi
reset_ledger

it "(#425) 失敗した呼び出し（PostToolUseFailure）の解放も、その呼び出しの登録だけを外す"
pre_bash s-a "$repo" 'bash scripts/verify.sh' toolu_g1
pre_bash s-a "$repo" 'bash scripts/loop-gate.sh' toolu_g2
fail_bash s-a "$repo" 'bash scripts/verify.sh' toolu_g1
held="$(ledger s-b "$repo" check gate | sed -n 1p)"
post_bash s-a "$repo" 'bash scripts/loop-gate.sh' toolu_g2
gone="$(ledger s-b "$repo" check gate | sed -n 1p)"
if [[ "$held" == "LEDGER_DENY" && "$gone" == "LEDGER_OK" ]]; then pass; else fail "失敗した 1 本の後=$held 2 本とも終わった後=$gone"; fi
reset_ledger

it "(#425) git も同様。同じ作業ツリーで並行する 2 本のうち 1 本が終わっても、別セッションの git は拒否のまま"
pre_bash s-a "$repo" 'git fetch origin' toolu_c1
pre_bash s-a "$repo" 'git rebase main' toolu_c2
post_bash s-a "$repo" 'git fetch origin' toolu_c1
pre_bash s-b "$repo" 'git rebase main'
held="$(decision)"
post_bash s-a "$repo" 'git rebase main' toolu_c2
pre_bash s-b "$repo" 'git rebase main'
if [[ "$held" == "deny" && "$(decision)" == "none" ]]; then pass; else fail "1 本目の後=$held 2 本目の後=$(decision)"; fi
reset_ledger

it "(#425) 複合コマンドが拒否されたとき、同じセッションの先行する登録は残り、その呼び出しの登録だけが外れる"
pre_bash s-a "$repo" 'gh pr merge 5 --squash' toolu_p1
ledger s-b "$wt2" claim git "$wt2" >/dev/null
pre_bash s-a "$repo" "gh pr merge 6 --squash && git -C $wt2 rebase main" toolu_p2
d_compound="$(decision)"
# 拒否された呼び出しでは merge も残さない（先行する toolu_p1 の登録だけが残る）。
kept="$(ledger s-b "$repo" check merge | sed -n 1p)"
post_bash s-a "$repo" 'gh pr merge 5 --squash' toolu_p1
after_p1="$(ledger s-b "$repo" check merge | sed -n 1p)"
if [[ "$d_compound" == "deny" && "$kept" == "LEDGER_DENY" && "$after_p1" == "LEDGER_OK" ]]; then pass; else fail "判定=$d_compound 拒否後=$kept 先行の解放後=$after_p1"; fi
reset_ledger

it "(#425) フックが台帳へ渡す識別子は tool_use_id である（台帳の 8 列目に入る）"
pre_bash s-a "$repo" 'gh pr merge 5 --squash' toolu_id1
col8="$(awk -F'\t' '$2 == "claim" && $3 == "merge" {print $8}' "$DIR/s-a.tsv" | tail -1)"
post_bash s-a "$repo" 'gh pr merge 5 --squash' toolu_id1
rel8="$(awk -F'\t' '$2 == "release" {print $8}' "$DIR/s-a.tsv" | tail -1)"
if [[ "$col8" == "toolu_id1" && "$rel8" == "toolu_id1" ]]; then pass; else fail "claim=$col8 release=$rel8"; fi
reset_ledger

it "(#425) tool_use_id が入力に無いときは、従来どおり種類と対象の単位で登録・解放する"
pre_bash s-a "$repo" 'gh pr merge 5 --squash'
col8="$(awk -F'\t' '$2 == "claim" && $3 == "merge" {print $8}' "$DIR/s-a.tsv" | tail -1)"
post_bash s-a "$repo" 'gh pr merge 5 --squash'
gone="$(ledger s-b "$repo" check merge | sed -n 1p)"
if [[ "$col8" == "-" && "$gone" == "LEDGER_OK" ]]; then pass; else fail "claim の識別子=$col8 解放後=$gone"; fi
reset_ledger


# 別のリポジトリ（別の台帳）への git 操作。台帳はリポジトリごとなので、解放は登録した台帳へ行う。
repo_x="$(new_workdir)/repo_x"
mkdir -p "$repo_x"
(
  cd "$repo_x" || exit 1
  git init -q . 2>/dev/null
  git config user.name test
  git config user.email test@example.com
  git config commit.gpgsign false
  echo x > f.txt
  git add f.txt
  git commit -q -m init
) >/dev/null 2>&1

it "(#425) git -C で別のリポジトリへ登録した呼び出しは、終わったとき（PostToolUse）にその台帳の登録も解放する"
pre_bash s-a "$repo" "git -C $repo_x fetch origin" toolu_x1
held="$(ledger s-b "$repo_x" check git "$repo_x" | sed -n 1p)"
post_bash s-a "$repo" "git -C $repo_x fetch origin" toolu_x1
gone="$(ledger s-b "$repo_x" check git "$repo_x" | sed -n 1p)"
if [[ "$held" == "LEDGER_DENY" && "$gone" == "LEDGER_OK" ]]; then pass; else fail "実行中=$held 終了後=$gone"; fi
reset_ledger
rm -rf "$repo_x/.git/session-ledger"

it "(#425) 失敗した呼び出し（PostToolUseFailure）でも、別のリポジトリの登録を解放する"
pre_bash s-a "$repo" "git -C $repo_x fetch origin && git rebase main" toolu_x2
fail_bash s-a "$repo" "git -C $repo_x fetch origin && git rebase main" toolu_x2
gone_x="$(ledger s-b "$repo_x" check git "$repo_x" | sed -n 1p)"
gone_r="$(ledger s-b "$repo" check git "$repo" | sed -n 1p)"
if [[ "$gone_x" == "LEDGER_OK" && "$gone_r" == "LEDGER_OK" ]]; then pass; else fail "別のリポジトリ=$gone_x cwd=$gone_r"; fi
reset_ledger
rm -rf "$repo_x/.git/session-ledger"

it "(#425) 拒否したときの巻き戻しも、別のリポジトリの先に登録した分を外す"
ledger s-b "$repo" claim git "$repo" >/dev/null
pre_bash s-a "$repo" "git -C $repo_x fetch origin && git rebase main" toolu_x3
d_x="$(decision)"
left_x="$(ledger s-b "$repo_x" check git "$repo_x" | sed -n 1p)"
if [[ "$d_x" == "deny" && "$left_x" == "LEDGER_OK" ]]; then pass; else fail "判定=$d_x 別のリポジトリ=$left_x"; fi
reset_ledger
rm -rf "$repo_x/.git/session-ledger"

it "(#425) 印が無い（PostToolUse だけが来た）ときは、従来どおり cwd の台帳へ解放する"
pre_bash s-a "$repo" 'gh pr merge 5 --squash' toolu_x4
rm -f "${TMPDIR:-/tmp}/session-coord-toolu_x4.dirs"
post_bash s-a "$repo" 'gh pr merge 5 --squash' toolu_x4
gone="$(ledger s-b "$repo" check merge | sed -n 1p)"
assert_eq "$gone" "LEDGER_OK" "解放後"
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

it "(#528) jq が無くても、タブを含むパスは台帳の対象にしない（file_path・git -C 先・cwd）"
ledger s-a "$repo" claim doc "docs/a b" >/dev/null
nojq_hook s-b "$(pl_edit "$repo" "$repo/docs/a"$'\t'"b")"
assert_quiet_pass "jq なし・タブを含む file_path"
reset_ledger
nj_dir="$base_dir/nj"$'\t'"dir"
mkdir -p "$nj_dir"
git -C "$nj_dir" init -q . >/dev/null 2>&1
nojq_hook s-b "$(pl_bash PreToolUse "$repo" "git -C \"$nj_dir\" fetch" toolu_nj1)"
c1="$(count_claims s-b)"
reset_ledger
nojq_hook s-b "$(pl_bash PreToolUse "$nj_dir" 'git fetch' toolu_nj2)"
c2="$(count_claims s-b)"
reset_ledger
if [[ "$c1" == "0" && "$c2" == "0" ]]; then pass; else fail "-C 先の登録=$c1 cwd の登録=$c2"; fi

exit_with_result
