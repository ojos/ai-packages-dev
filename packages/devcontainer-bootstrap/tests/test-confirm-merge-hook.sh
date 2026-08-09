#!/usr/bin/env bash
# マージ実行に確認を挟む PreToolUse フックの配置と判定を検証する。
#
# 規範（role-contracts/closer.md）の「既定の merge 方針は手動承認とする」を、呼びかけ
# ではなく機構で担保する配布物にあたる。検証したいのは 2 つある。
#
#   1. 配線が生きていること — --with-claude で scripts/confirm-merge-hook.sh と
#      .claude/settings.json が配置され、settings.json がそのスクリプトを PreToolUse
#      から呼ぶ形になっている。フック本体が正しくても呼ばれなければ何も起きない。
#      「黙って無効になった検知層」がこのフックの防ぎたい状態そのものなので、配線を
#      名指しで検査する。
#   2. 判定が実質であること — 実際にペイロードを流し込み、止めるものと通すものの
#      両方を確かめる。止めるものだけを検査すると、単純な部分一致（何でも ask）でも
#      緑になる。確認が頻発すれば内容を読まずに承認する習慣ができ、機構は形だけになる
#      ため、通すものの検査が本質的にいる。
#
# 実際のマージ操作は行わない。フックは標準入力の JSON だけを見て標準出力へ判定を返す
# ため、gh も git も呼ばずに検証できる。
#
# ネットワークには出ない。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-confirm-merge-hook"

HOOK_REL="scripts/confirm-merge-hook.sh"
SETTINGS_REL=".claude/settings.json"
CLAUDE_IGNORE_REL=".claude/.gitignore"

# ── 配置と配線 ────────────────────────────────────────────────────────────────

out="$(new_workdir)/p"
run_bootstrap "$out" --with-claude --without-playbook >/dev/null 2>&1
HOOK="$out/$HOOK_REL"

it "--with-claude でフック本体が配置される"
assert_file_exists "$HOOK"

it "配置されたフックは実行可能（755）"
assert_mode "$HOOK" "755"

it "--with-claude で .claude/settings.json が配置される"
assert_file_exists "$out/$SETTINGS_REL"

it "--with-claude で .claude/.gitignore が settings.local.json を除外する"
assert_contains "$(cat "$out/$CLAUDE_IGNORE_REL" 2>/dev/null || true)" \
  "settings.local.json" ".claude/.gitignore"

it "settings.json が PreToolUse からフック本体を呼ぶ"
# 「フックが配置されている」だけでは何も保証しない。呼び出し側の JSON を実際に読んで、
# PreToolUse に登録されたコマンドがフック本体を指していることまで見る。
hook_cmd="$(jq -r '.hooks.PreToolUse[0].hooks[0].command // empty' "$out/$SETTINGS_REL" 2>/dev/null)"
assert_contains "$hook_cmd" "confirm-merge-hook.sh" "PreToolUse に登録されたコマンド"

it "settings.json の PreToolUse は Bash ツールへ絞られている"
matcher="$(jq -r '.hooks.PreToolUse[0].matcher // empty' "$out/$SETTINGS_REL" 2>/dev/null)"
assert_eq "$matcher" "Bash" "PreToolUse の matcher"

it "--with-claude なしではフック本体を配置しない"
outn="$(new_workdir)/p"
run_bootstrap "$outn" --without-playbook >/dev/null 2>&1
assert_file_absent "$outn/$HOOK_REL"

it "--with-claude なしでは .claude/ を作らない"
assert_file_absent "$outn/.claude"

it "dry-run は --with-claude 時にフックと配線を計画に含める"
outd="$(new_workdir)/p"
plan="$(run_bootstrap "$outd" --with-claude --without-playbook --dry-run 2>&1)"
if printf '%s' "$plan" | grep -q "$HOOK_REL" \
  && printf '%s' "$plan" | grep -q "$SETTINGS_REL" \
  && printf '%s' "$plan" | grep -q "$CLAUDE_IGNORE_REL"; then
  pass
else
  fail "dry-run の計画に 3 ファイルが揃っていない: $(printf '%s' "$plan" | grep -c 'plan:') plan 行"
fi

# ── 判定（ペイロードを流し込む）────────────────────────────────────────────────

# Bash ツールの PreToolUse ペイロードを組み立てる。実装が読むのは
# .tool_input.command だけだが、実際に届く形へ寄せる。
bash_payload() {
  jq -n --arg cmd "$1" '{
    hook_event_name: "PreToolUse",
    tool_name: "Bash",
    tool_input: { command: $cmd }
  }'
}

# フックへ流し込み、判定（permissionDecision）を返す。無出力なら空文字。
decision_for_payload() {
  local payload="$1" out_json
  out_json="$(printf '%s' "$payload" | bash "$HOOK")"
  [[ -n "$out_json" ]] || return 0
  printf '%s' "$out_json" | jq -r '.hookSpecificOutput.permissionDecision // "(no decision)"'
}

decision_for_command() {
  decision_for_payload "$(bash_payload "$1")"
}

# 止めるべきもの。第 2 引数は表示ラベル（省略時はコマンドそのもの）。改行を含む
# コマンド（行継続のテスト）をそのまま表示すると出力が複数行に割れて読みにくいため、
# その場合だけ呼び出し側から短いラベルを渡す。
assert_ask() {
  local cmd="$1" label="${2:-$1}"
  it "確認を求める: $label"
  assert_eq "$(decision_for_command "$cmd")" "ask" "判定"
}

# 通すべきもの。無出力＝フックは何も言わない（既定の許可判定に任せる）。
assert_silent() {
  local cmd="$1" label="${2:-$1}"
  it "確認を求めない: $label"
  assert_eq "$(decision_for_command "$cmd")" "" "判定"
}

# 票の受け入れ条件そのもの。
assert_ask   'gh pr merge 1'
assert_ask   'cd /x && gh pr merge 1'
assert_ask   'gh api --method PUT repos/o/r/pulls/1/merge'
assert_silent 'gh api repos/o/r/pulls/1/merge'
assert_silent "grep -rn 'mergePullRequest' ."

# REST 経由の綴りの揺れ。--method=PUT（= 連結）・-XPUT（連結形）・--method put（小文字）は
# いずれも意図的な迂回ではなく普通の綴りで、gh が実際に受理する（第二意見の指摘）。
assert_ask   'gh api --method=PUT repos/o/r/pulls/1/merge'
assert_ask   'gh api -XPUT repos/o/r/pulls/1/merge'
assert_ask   'gh api --method put repos/o/r/pulls/1/merge'
# GET 側には波及しない。マージ済みか調べるだけの読み取りは対象外のまま。
assert_silent 'gh api --method=GET repos/o/r/pulls/1/merge'
assert_silent 'gh api -XGET repos/o/r/pulls/1/merge'
# merge エンドポイントを含まない行での PUT は対象にしない（同一行の条件を維持）。
assert_silent 'gh api --method PUT repos/o/r/issues/1/labels'

it "壊れた JSON でも確認を求める（fail-open にしない）"
# jq がコマンドを取り出せない場合はペイロード全体を検査対象にする。「取れなければ
# 通す」にすると、jq が無い環境・壊れた JSON・将来のペイロード変更のいずれでも検査を
# 黙って飛ばす。検知層が黙って無効化されるのは最悪の壊れ方で、このフックが防ごうと
# している状態そのものを再現する。
assert_eq "$(decision_for_payload '{"tool_input": {"command": "gh pr merge 1"')" \
  "ask" "壊れた JSON に対する判定"

it "壊れた JSON でも無関係なコマンドは通す"
# 「壊れていたら常に ask」ではないことを確かめる。常に ask にすると、壊れた形が
# 続いたときに内容を読まずに承認する習慣ができる。
assert_eq "$(decision_for_payload '{"tool_input": {"command": "ls -la"')" \
  "" "壊れた JSON（無関係なコマンド）に対する判定"

# コマンド位置の判定。引用符の内側は通し、コマンド位置にあるものは止める。
assert_ask   'GH_TOKEN=x gh pr merge 1'
assert_silent "git log -S 'gh pr merge'"
assert_silent 'echo "gh pr merge"'
assert_silent 'gh pr list'
assert_silent 'gh pr mergequeue 1'

# REST / GraphQL 経由。permissions の前方一致では捕捉できない経路。
assert_ask   'curl -X PUT https://api.github.com/repos/o/r/pulls/1/merge'
assert_ask   'gh api graphql -f query="mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"'
assert_silent 'gh api graphql -f query="query { viewer { login } }"'

# ── バックスラッシュ行継続（第二意見の指摘。実測で漏れを確認済み）──────────────

# 陽性: \ + 改行で PUT と merge エンドポイントが別行に分かれていても検知する。
# 長い REST 呼び出しを \ で複数行に分けるのは普通の書き方で、-XPUT / --method=PUT
# と同じ「うっかり実行」側にあたる。
assert_ask $'gh api --method PUT \\\n  repos/o/r/pulls/1/merge' \
  'gh api --method PUT \<改行>repos/o/r/pulls/1/merge（行継続）'

# 陰性: 行継続のないただの 2 行（1 行目に merge エンドポイント、2 行目に PUT）は
# 対象にしない。改行を一律に潰していないことの対照 —一律に潰すと、無関係な 2 行
# が結合してこの入力も誤って ask になる。
assert_silent $'echo repos/o/r/pulls/1/merge\ngh api --method PUT repos/o/r/issues/1' \
  'echo ...merge<改行>gh api --method PUT ...issues/1（継続なしの別行）'

# 陽性: CRLF の行継続（\ + CR + LF）でも検知する。LF だけを落とすと \ + CR が残り、
# CR が語末境界として働いて判定が外れる。この経路がフックへ届くことは実測できて
# いないが、置換 1 行で恒久的に問いを消せるため塞いである。
assert_ask $'gh api --method PUT \\\r\n  repos/o/r/pulls/1/merge' \
  'gh api --method PUT \<CRLF>repos/o/r/pulls/1/merge（CRLF 行継続）'

# 陰性: CRLF でも、行継続のないただの 2 行は対象にしない（LF 側と同じ対照）。
assert_silent $'echo repos/o/r/pulls/1/merge\r\ngh api --method PUT repos/o/r/issues/1' \
  'echo ...merge<CRLF>gh api --method PUT ...issues/1（継続なしの別行）'

# gh pr merge / graphql が行継続で壊れていないことの回帰。
assert_ask $'gh pr merge \\\n  1 --squash' \
  'gh pr merge \<改行>1 --squash（行継続。回帰）'
assert_ask $'gh api graphql \\\n  -f query="mutation { mergePullRequest(input: {pullRequestId: 1}) { clientMutationId } }"' \
  'gh api graphql \<改行>-f query=...mergePullRequest...（行継続。回帰）'

# ── 空ペイロード（配線不全の検知。Copilot レビュー指摘）───────────────────────

it "stdin が空なら確認を求める（配線不全の検知。fail-open にしない）"
# ペイロードが届かない＝配線不全の疑い。jq 不在時に「取れなければ通す」を採らな
# かったのと同じ理由（検知層が黙って無効化されるのは最悪の壊れ方）で、ここも通さない。
empty_out="$(printf '' | bash "$HOOK")"
empty_decision="$(printf '%s' "$empty_out" | jq -r '.hookSpecificOutput.permissionDecision // "(no decision)"' 2>/dev/null)"
assert_eq "$empty_decision" "ask" "空ペイロードに対する判定"

it "空ペイロードの理由文はマージ検知ではなく検査不成立を伝える"
# 判定できなかったことと、マージを検知したことは別。理由文が使い回しでないことを見る。
empty_reason="$(printf '%s' "$empty_out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)"
assert_contains "$empty_reason" "空でした" "空ペイロードの理由文"

# 陰性（回帰）: 正常なペイロードでマージ以外のコマンドは、空ペイロードの扱いを
# 変えても通ったままである。空ペイロードだけが特別扱いであることの対照。
assert_silent 'ls -la'

it "確認を求めるときも終了コードは 0"
# 非 0 で落とすと、フックの失敗とマージ確認の区別が付かなくなる。判定は標準出力の
# JSON で伝える。
printf '%s' "$(bash_payload 'gh pr merge 1')" | bash "$HOOK" >/dev/null 2>&1
assert_eq "$?" "0" "終了コード"

it "確認を求める判定には理由が付く"
reason="$(printf '%s' "$(bash_payload 'gh pr merge 1')" | bash "$HOOK" \
  | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
if [[ -n "$reason" ]]; then
  pass
else
  fail "permissionDecisionReason が空（何を確認すべきか読めない）"
fi

it "jq が無い環境でも妥当な JSON を返す"
# 出力側を jq に依存させると、jq の無い環境で判定が届かない（＝黙って通る）。
# PATH から jq を落とし、フォールバックの printf 経路を通す。
nojq="$(new_workdir)/nojq"
mkdir -p "$nojq"
for c in cat grep; do
  src="$(command -v "$c")"
  [[ -n "$src" ]] && ln -sf "$src" "$nojq/$c"
done
# インタプリタは絞った PATH の外から絶対パスで起動する。PATH へ bash を含めると
# 「jq だけが無い環境」ではなくなるため、フックが使う外部コマンド（cat / grep）
# だけを置く。
bash_bin="$(command -v bash)"
fallback="$(printf '%s' "$(bash_payload 'gh pr merge 1')" | PATH="$nojq" "$bash_bin" "$HOOK")"
if printf '%s' "$fallback" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; then
  pass
else
  fail "jq 不在時の出力が妥当な JSON でない、または ask でない: $fallback"
fi

# ── 既知の限界が配布物へ記録されている ────────────────────────────────────────

it "フック本体が既知の限界を記録している"
# 完全であるかのように記録すると、実態より強い保証があると誤認させる
# （shared-ai-rules.md 12 章）。限界の記載そのものを配布物の一部として検査する。
if grep -q '既知の限界' "$HOOK" && grep -q 'security boundary' "$HOOK"; then
  pass
else
  fail "既知の限界（guardrail であって security boundary ではない）の記載が無い"
fi

it "フック本体が deny ではなく ask である理由を記録している"
if grep -q 'deny ではなく ask' "$HOOK"; then
  pass
else
  fail "ask を返す理由の記載が無い"
fi

exit_with_result
