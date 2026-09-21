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

# ── 制御語の直後もコマンド位置として扱う（実測で判明した迂回）───────────────
#
# 区切り文字（; && || | (）の直後という条件だけでは、シェルの制御語を 1 つ
# 前置くだけで「コマンド位置」の条件から外れて素通りしていた。
assert_ask 'if gh pr merge 1; then :; fi' 'if の直後'
assert_ask '! gh pr merge 1' '! の直後'
assert_ask 'while gh pr merge 1; do :; done' 'while の直後'
assert_ask 'until gh pr merge 1; do :; done' 'until の直後'
assert_ask 'if false; then gh pr merge 1; fi' 'then の直後'
assert_ask 'if false; then :; elif gh pr merge 1; then :; fi' 'elif の直後'
assert_ask 'while false; do gh pr merge 1; done' 'do の直後'
assert_ask 'if false; then :; else gh pr merge 1; fi' 'else の直後（第二意見の指摘で判明。列挙に無かった）'
# 迂回対処の対照群: 制御語の後ろに素直に別コマンドが続くだけの形は、
# 引き続き無関係なコマンドとして通す（制御語の追加が誤検知を増やしていない）。
assert_silent 'if true; then echo hi; fi' 'if 直後の無関係なコマンド'
assert_silent 'while true; do echo hi; done' 'while 直後の無関係なコマンド'
assert_silent 'if true; then echo hi; else echo bye; fi' 'else 直後の無関係なコマンド'

# ── コマンド境界の解析（) も境界として扱う）───────────────────────────────
#
# ) は case 文の分岐区切りとして現れる。for_each_clause（command_position_has が
# 使う節の切り出し）は ( と同じく ) も境界として扱うため、case 分岐の直後も
# コマンド位置として拾う。
assert_ask 'case x in a) gh pr merge 1;; esac' 'case 分岐の ) 直後'

# ── グループコマンド { ... } ─────────────────────────────────────────────
#
# { gh pr merge 1; } は実際にマージを実行する。{ をコマンド位置の境界として
# 単純に加えると、echo hi { gh pr merge 1 のような「{ 以降も直前のコマンドの
# 引数でしかなく、実際には実行されない」文字列まで拾ってしまう（実測）。解析は
# 「この節の語が環境変数代入・制御語だけで説明できる（＝実コマンドの語をまだ
# 1 つも集めていない）」ことを条件にできるため、真にコマンド位置にある { だけを
# 区別できる。
assert_ask '{ gh pr merge 1; }' '{ グループコマンドの開始'
# 対照群: { が他のコマンドの引数の途中に現れるだけの形（実際には gh pr merge を
# 実行しない）までは拾わない。入れすぎて誤検知を増やさないことの確認。
assert_silent 'echo hi { gh pr merge 1' '{ が引数の途中（実行されない形、対照群）'
assert_silent 'echo hi { echo b' '{ が引数の途中の無関係なコマンド（対照群）'

# ── { の直前に制御語だけを前置いた形（実測で判明した迂回）─────────────────
#
# { を読み飛ばす条件を「その節でまだ語を 1 つも集めていない」だけにしていたとき
# は、if などの制御語を 1 つ前置くだけで { が語として残ってしまい、解析が
# gh pr merge へ到達できずに素通りしていた（実測）。制御語・環境変数代入だけを
# 前置きとして許すよう判定を広げ、この迂回を塞ぐ。
assert_ask 'if { gh pr merge 1; }; then :; fi' 'if の直後の { グループコマンド開始'
assert_ask 'FOO=bar { gh pr merge 1; }' '環境変数代入の直後の { グループコマンド開始'
# 対照群: 制御語ではない普通のコマンドを前置いた形は、これまで通り { を素通しの
# 文字として扱う（入れすぎて誤検知を増やしていないことの確認）。
assert_silent 'echo { gh pr merge 1; }' '制御語ではないコマンドの直後の {（対照群）'
# 対照群: 実コマンドの語（gh）の直後の { は素通しの文字として扱われるため、
# 続く pr / merge はその { という語の後ろに連なるだけで、コマンド位置の先頭
# （gh の直後）には来ない。{ の読み飛ばし条件を誤って広げても（すべての節で
# 無条件に読み飛ばすなど）、コマンド位置の一致はここでは崩れない — 一致は
# 「読み飛ばし後の先頭語から」を要求するため、{ を挟んで並んだだけの語列が
# 誤って一致することはない。
assert_silent 'gh { pr merge 1' 'gh の直後の {（実コマンド語の後ろ、対照群）'

# ── in の直後は対象にしない（for のワードリストは実行されるコマンドではない）──
#
# for x in gh pr merge 1; do ...; done の「gh pr merge 1」は for が x へ順に
# 代入する値であって、実行されるコマンドではない。in の直後をコマンド位置として
# 扱うとここが誤検知になるため、意図的に対象外にしている。
assert_silent 'for x in gh pr merge 1; do :; done' 'for の in 直後（ワードリスト、対照群）'
# shellcheck disable=SC2016  # $x はフックへ渡す文字列そのもので、ここでは展開しない
assert_silent 'for x in gh pr merge 1; do echo $x; done' 'for の in 直後（ワードリスト、対照群、本体が echo）'

# ── クォートされた予約語は実コマンド名として扱う（第二意見の指摘で判明した誤検知）
#
# 'if' gh pr merge 1 は「if という名前のコマンドを実行する入力」であり、gh は
# 実行されない。かつて予約語の判定はクォートを剥がした語（'if' も "if" になる）
# に対して行っており、実際には実行されないこの形まで確認を求めていた（実測）。
# 予約語として読み飛ばすのは、その語がクォート・バックスラッシュエスケープを
# 1 文字も含まないときだけにして直した。
assert_silent "'if' gh pr merge 1" 'クォートされた予約語 if（単一引用符）は実コマンド名'
assert_silent '"if" gh pr merge 1' 'クォートされた予約語 if（二重引用符）も同様'
# 対照群: gh / pr / merge 自体をクォートしても、実行されるコマンドは変わらない
# （bash はクォートを剥がしてから起動するため）。ここまで silent 側へ倒すと
# 迂回になる。
assert_ask "'gh' 'pr' 'merge' 1" 'コマンド名自体のクォートは実行対象を変えない（回帰）'

# ── クォートの中の ; を区切り文字と誤認しない（第二意見の指摘で判明した誤検知）
#
# echo "x; gh pr merge 1" は echo に 1 個の引数を渡すだけで gh は実行されない。
# かつてはクォートを認識しない grep 側の経路が、二重引用符の中の ; まで区切り
# 文字として扱い、確認を求めていた（実測）。コマンド位置の判定をクォート認識の
# 解析だけに一本化したことで、この誤検知は起きない。
assert_silent 'echo "x; gh pr merge 1"' '二重引用符内の ; を区切り文字と誤認しない'
assert_silent "grep -rn 'gh pr merge' ." "grep -rn 'gh pr merge' .（対照群。導入時からの性質）"

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

# ── 誤検知: 同一行の別コマンド（実測で判明した誤検知）───────────────────────
#
# merge エンドポイントと PUT が「同じ物理行」にあることだけを条件にすると、
# ; & | で連結された無関係な 2 つのコマンドまで同じコマンドとして誤って
# 一致する。判定の単位を「行」ではなく「コマンド節」にすることで区別する。
assert_silent 'echo repos/o/r/pulls/1/merge; gh api --method PUT repos/o/r/issues/1/labels' \
  '; で連結された無関係な 2 コマンド'
assert_silent 'echo repos/o/r/pulls/1/merge && gh api --method PUT repos/o/r/issues/1/labels' \
  '&& で連結された無関係な 2 コマンド'
assert_silent 'gh api --method PUT repos/o/r/issues/1/labels | cat repos/o/r/pulls/1/merge' \
  '| で連結された無関係な 2 コマンド'
# 対照群: 同じコマンド節の中に両方があれば、引き続き検知する（区切り文字を
# 導入したことで正しい検知まで壊していないことの確認）。
assert_ask 'echo hi; gh api --method PUT repos/o/r/pulls/1/merge' \
  '; の後ろの同一コマンド節に両方がある'

# ── 節の切り出しはクォートを認識する（第二意見の指摘で判明。重い方の欠陥）───
#
# 誤検知を直すために ; & | を区切りとして扱う処理を入れたが、当初はクォートの
# 中身や URL のクエリ文字列に現れる ; & | まで区切りとして扱っており、PUT の
# 指定と merge エンドポイントが別々の節へ分断されて検知漏れになっていた
# （実測）。誤検知を直すために入れた処理そのものが新しい迂回を作っていた形。
# クォート認識の走査（for_each_clause）を PUT / merge エンドポイント判定と
# コマンド位置判定の両方で共有し、二度と食い違わない構造にしている。
assert_ask "gh api 'repos/o/r/pulls/1/merge?commit_title=foo&commit_message=bar' -X PUT" \
  '単一引用符内の URL クエリの & で分断されない'
assert_ask 'gh api repos/o/r/pulls/1/merge -f commit_message="fix bug & test" -X PUT' \
  '二重引用符内の & で分断されない'
assert_ask 'gh api -X PUT -f message="fix; test" repos/o/r/pulls/1/merge' \
  '二重引用符内の ; で分断されない'

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

# ── 環境変数代入は値側のクォートを問わない（第二意見の指摘で判明した迂回）───
#
# VAR="foo" gh pr merge 1 / KEY='bar' gh pr merge 1 は、どちらも値側だけが
# クォートされた代入で、実際には gh がコマンド位置に来る（実測: env で代入と
# して効くことを確認した）。予約語と同じ「語にクォートが 1 文字でもあれば
# 読み飛ばさない」を代入の判定にも適用すると、この 2 例で name= の直後に来る
# gh へ到達できず素通りしていた（実測。grep の列挙を廃した際に、クォートを
# 見ない grep 側のフォールバックが無くなったことで露見した退行）。環境変数
# 代入の判定は、name= の部分にクォートが挟まっていないことだけを見て、値側の
# クォートは問わない形に直した。
assert_ask 'VAR="foo" gh pr merge 1' '値だけを二重引用符で囲んだ環境変数代入'
assert_ask "KEY='bar' gh pr merge 1" '値だけを単一引用符で囲んだ環境変数代入'
assert_ask 'VAR="foo" { gh pr merge 1; }' '値をクォートした代入 + { グループコマンド'
assert_ask 'VAR=foo gh pr merge 1' 'クォートなしの環境変数代入（対照群・回帰）'
# 対照群: name 側にクォートが挟まっている形は、bash 上そもそも代入にならず
# "VAR"=foo という名前のコマンドを探しにいく（実測）。代入として読み飛ばして
# はならず、gh はコマンド位置に来ない。
assert_silent '"VAR"=foo gh pr merge 1' 'name 側をクォートすると代入にならない（対照群）'

# ── 空クォート（'' / ""）も語として数える（第二意見の指摘で判明した迂回・誤検知）
#
# 空クォートは中身の文字を 1 つも追加しないため、「内容が付いたときにだけ語が
# 始まったとみなす」実装だと、空クォートだけの語はいつまでも「語が始まって
# いない」扱いのままになる。その結果、空白や区切り文字に達しても語を確定させる
# 処理（word_start のリセットを含む）が走らず、次の語の先頭で word_start が
# 上書きされないまま残る。直前の空クォートや区切り文字まで巻き込んで語の元
# テキストを切り出してしまい、環境変数代入の判定（name= が引用符を挟まずに
# 始まっているか）が本来の name の手前に無関係な文字が挟まって外れる（実測:
# `echo '' ; FOO=bar gh pr merge 1` が素通りしていた）。
assert_ask "echo '' ; FOO=bar gh pr merge 1" \
  '空クォートの直後の ; を挟んだ環境変数代入（迂回）'
assert_ask 'git commit -m "" ; VAR=1 gh pr merge 1' \
  '空の二重引用符引数の直後の ; を挟んだ環境変数代入（迂回）'
assert_ask 'test -z "" && FOO=bar gh pr merge 1' \
  '空の二重引用符引数の直後の && を挟んだ環境変数代入（迂回）'
# 逆方向: 空クォート自体が語として clause_words に入らないと、'' 自身が
# コマンド名（bash はこれを実行しようとし、gh は起動されない）であるにも
# かかわらず、gh が誤って先頭語として扱われ、逆方向の誤検知が起きる（実測）。
assert_silent "'' gh pr merge 1" \
  '空クォートがコマンド名になる（gh は引数、誤検知の対照群）'

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

# ── squash 本文の CI 抑止の綴り ──────────────────────────────────────────────
#
# gh pr merge を検知したときに、squash 本文になるテキスト（PR 本文・コミット
# メッセージ・--body / --body-file / --subject の指定）へ CI 抑止の綴りが無いか
# を追加で見る段を検証する。実際の gh やネットワークは呼ばず、偽の gh を PATH
# の先頭へ差し込んで決定的に検証する。
#
# 綴りそのものをこのファイルへ連続した文字列として書かない。連続した文字列の
# まま git の差分・コミットメッセージへ混ざると GitHub が実際に解釈してしまう
# （この票の発端そのもの）。連結して組み立てることで、このファイル自身には
# 連続した綴りを残さない。

ci_skip_marker() {
  local o='[' c=']'
  printf '%s%s%s' "$o" "$1" "$c"
}

# 偽の gh。pr view が呼ばれたら、実際に渡された --json / --jq を fixture
# （JSON。$FAKE_GH_FIXTURE。複数対象を PR セレクタで出し分けたいときは
# $FAKE_GH_FIXTURE_MAP に "セレクタ<TAB>fixture のパス" を 1 行ずつ書く）へ
# 適用してから返す。--json で要求したフィールドだけを fixture から絞り込んで
# から --jq を適用するため、実装が要求するフィールドや jq 式を削っても、この
# スタブは黙って前と同じ値を返さない（指摘: 固定文字列を返すだけのスタブは
# 取得の契約そのものを検証しない）。$FAKE_GH_RC が 0 以外ならその終了コードで
# 失敗する。$FAKE_GH_ARGS_FILE が設定されていれば、受け取った引数をそのまま
# そこへ書く。pr view 以外は失敗させる（このフックは pr view しか呼ばない）。
make_fake_gh() {
  local dir="$1"
  cat >"$dir/gh" <<'SH'
#!/usr/bin/env bash
if [[ -n "${FAKE_GH_ARGS_FILE:-}" ]]; then
  printf '%s\n' "$*" > "$FAKE_GH_ARGS_FILE"
fi
if [[ "$1" != "pr" || "$2" != "view" ]]; then
  exit 1
fi
if [[ "${FAKE_GH_RC:-0}" != "0" ]]; then
  exit "${FAKE_GH_RC}"
fi
shift 2
selector=""
if [[ $# -gt 0 && "$1" != -* ]]; then
  selector="$1"
  shift
fi
json_fields=""
jq_expr=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)
      json_fields="$2"
      shift 2
      ;;
    --jq)
      jq_expr="$2"
      shift 2
      ;;
    --repo)
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
if [[ -z "$json_fields" || -z "$jq_expr" ]]; then
  echo "fake gh: --json/--jq が渡されていない" >&2
  exit 1
fi
fixture="$FAKE_GH_FIXTURE"
if [[ -n "${FAKE_GH_FIXTURE_MAP:-}" && -f "$FAKE_GH_FIXTURE_MAP" ]]; then
  mapped="$(awk -F'\t' -v sel="$selector" '$1 == sel { print $2; exit }' "$FAKE_GH_FIXTURE_MAP")"
  [[ -n "$mapped" ]] && fixture="$mapped"
fi
filtered="$(jq --arg f "$json_fields" '
  ($f | split(",")) as $keep
  | with_entries(select(.key as $k | $keep | index($k)))
' "$fixture")" || exit 1
printf '%s' "$filtered" | jq -r "$jq_expr"
exit $?
SH
  chmod +x "$dir/gh"
}

fakebin="$(new_workdir)/fakebin"
mkdir -p "$fakebin"
make_fake_gh "$fakebin"

# フックへペイロードを流し込み、偽の gh を PATH の先頭に置いた状態で判定と
# 理由の両方を、タブ区切りの 1 行で返す。
decision_and_reason_with_fake_gh() {
  local cmd="$1" fixture="$2" rc="${3:-0}" out
  out="$(printf '%s' "$(bash_payload "$cmd")" \
    | FAKE_GH_FIXTURE="$fixture" FAKE_GH_RC="$rc" PATH="$fakebin:$PATH" bash "$HOOK")"
  printf '%s\t%s' \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "(no decision)"')" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
}

BASE_MERGE_REASON='gh pr merge をコマンド位置で実行しようとしています。既定の merge 方針は手動承認です。承認の記録を確認してください。'

# 対象 1 件ぶんの fixture（PR 本文・コミット 1 件のヘッドライン・本文）を JSON
# で作る。fake gh はこの JSON へ、実際にフックが渡した --json / --jq を適用
# する（上のコメント参照）。
make_pr_fixture() {
  local out_file="$1" body="$2" headline="$3" commit_body="$4"
  jq -n --arg body "$body" --arg h "$headline" --arg b "$commit_body" \
    '{body: $body, commits: [{messageHeadline: $h, messageBody: $b}]}' > "$out_file"
}

fx_dir="$(new_workdir)/fixtures"
mkdir -p "$fx_dir"

fixture_clean="$fx_dir/clean.json"
make_pr_fixture "$fixture_clean" "この PR は README を更新します。" "docs: README を更新" ""

# 実際に踏んだ形を再現する: 見出しではなく、検査そのものを説明する文章の
# 途中に綴りが埋め込まれている。PR 本文側にある形。
fixture_body_midsentence="$fx_dir/body-midsentence.json"
make_pr_fixture "$fixture_body_midsentence" \
  "$(printf '%s\n%s' 'この変更は手順を整理するものです。' \
    "あわせて、手順 8 の $(ci_skip_marker 'skip ci') 検査が正しく動くことを確認しました。")" \
  "fix: 手順を整理" ""

# PR 本文はクリーンだが、コミットメッセージ側にだけ綴りがある形。squash 本文の
# 組み立て方（PR_BODY / COMMIT_MESSAGES）のどちらでも見落とさないことの確認。
fixture_commit_only="$fx_dir/commit-only.json"
make_pr_fixture "$fixture_commit_only" "PR 本文はクリーンです。" "fix: 何かを直す" \
  "詳細: $(ci_skip_marker 'ci skip') という綴りをコミット側に書いた（テスト用）。"

it "squash 本文の途中（見出しではない）に綴りがあっても検知する"
result="$(decision_and_reason_with_fake_gh 'gh pr merge 1' "$fixture_body_midsentence")"
r_decision="${result%%$'\t'*}"
r_reason="${result#*$'\t'}"
assert_eq "$r_decision" "ask" "判定"
assert_contains "$r_reason" "squash 本文になるテキスト" "理由（見出しではない綴りの検知）"

it "PR 本文ではなくコミットメッセージ側の綴りも検知する"
result="$(decision_and_reason_with_fake_gh 'gh pr merge 1' "$fixture_commit_only")"
r_decision="${result%%$'\t'*}"
r_reason="${result#*$'\t'}"
assert_eq "$r_decision" "ask" "判定"
assert_contains "$r_reason" "squash 本文になるテキスト" "理由（コミットメッセージ側の綴りの検知）"

it "squash 本文に綴りが無ければ理由は従来どおり（対照群、追記されない）"
result="$(decision_and_reason_with_fake_gh 'gh pr merge 1' "$fixture_clean")"
r_reason="${result#*$'\t'}"
assert_eq "$r_reason" "$BASE_MERGE_REASON" "クリーンな squash 本文の理由"

it "gh コマンドが無いときは「綴りが無い」と扱わず、確認できていないことを理由に書く"
nogh_dir="$(new_workdir)/nogh"
mkdir -p "$nogh_dir"
for c in cat grep jq; do
  src="$(command -v "$c")"
  [[ -n "$src" ]] && ln -sf "$src" "$nogh_dir/$c"
done
bash_bin="$(command -v bash)"
nogh_out="$(printf '%s' "$(bash_payload 'gh pr merge 1')" | PATH="$nogh_dir" "$bash_bin" "$HOOK")"
nogh_reason="$(printf '%s' "$nogh_out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
assert_contains "$nogh_reason" "gh コマンドが無い" "gh 不在時の理由"

it "gh pr view が失敗したときも「綴りが無い」と扱わない"
result="$(decision_and_reason_with_fake_gh 'gh pr merge 1' "$fixture_clean" 1)"
r_decision="${result%%$'\t'*}"
r_reason="${result#*$'\t'}"
assert_eq "$r_decision" "ask" "判定"
assert_contains "$r_reason" "PR 情報を取得できなかった" "gh pr view 失敗時の理由"

it "コマンド文字列を取り出せない（壊れた JSON）ときも「綴りが無い」と扱わない"
broken_out="$(printf '%s' '{"tool_input": {"command": "gh pr merge 1"' \
  | FAKE_GH_FIXTURE="$fixture_clean" PATH="$fakebin:$PATH" bash "$HOOK")"
broken_reason="$(printf '%s' "$broken_out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
assert_contains "$broken_reason" "コマンド文字列を取り出せていない" "壊れた JSON のときの理由"

it "REST 経由の merge には squash 本文の検査を広げていない（対照群）"
rest_out="$(printf '%s' "$(bash_payload 'gh api --method PUT repos/o/r/pulls/1/merge')" | bash "$HOOK")"
rest_reason="$(printf '%s' "$rest_out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
case "$rest_reason" in
  *"squash 本文になるテキスト"*) fail "REST 経路にまで squash 本文検査が意図せず広がっている" ;;
  *) pass ;;
esac

it "PR セレクタと --repo を、gh pr merge の後続の語から正しく抜き出す"
args_file="$(new_workdir)/gh-args.txt"
printf '%s' "$(bash_payload 'gh pr merge 42 --repo owner/repo --squash')" \
  | FAKE_GH_FIXTURE="$fixture_clean" FAKE_GH_ARGS_FILE="$args_file" PATH="$fakebin:$PATH" bash "$HOOK" >/dev/null
gh_args_seen="$(cat "$args_file" 2>/dev/null || true)"
case "$gh_args_seen" in
  "pr view 42 --repo owner/repo "*) pass ;;
  *) fail "gh へ渡された引数が期待と異なる: $gh_args_seen" ;;
esac

it "gh へ渡す --json は body と commits の両方を要求する（指摘: 取得の契約の検査）"
assert_contains "$gh_args_seen" "--json body,commits" "gh へ渡された --json"

it "gh へ渡す --jq は本文と全コミットのヘッドライン・本文を取り出す式である（指摘: 取得の契約の検査）"
assert_contains "$gh_args_seen" "--jq .body, (.commits[] | .messageHeadline, .messageBody)" "gh へ渡された --jq"

# ── --body / --body-file / --subject（指摘: 実測で判明した漏れ）───────────────
#
# gh pr merge --body "..." のように squash 本文を CLI 側で直接渡すと、リモート
# の PR 本文が綺麗でも、渡した文面に綴りがあれば CI は飛ぶ。しかも squash 前の
# 人手の回復手順（land スキル）は「該当行が出たら、その指示を除いた本文を
# ファイルに書き、--body-file で差し替えてマージする」と定めており、--body 系
# を見ないと回復手順そのものがこの検査をすり抜ける経路になっていた。

it "--body に渡した文字列の綴りを検知する（実測で判明した漏れ）"
body_arg="この変更につき、$(ci_skip_marker 'skip ci') を含む本文を直接渡す（テスト用）。"
cmd="gh pr merge 1 --squash --body \"${body_arg}\""
result="$(decision_and_reason_with_fake_gh "$cmd" "$fixture_clean")"
r_decision="${result%%$'\t'*}"
r_reason="${result#*$'\t'}"
assert_eq "$r_decision" "ask" "判定"
assert_contains "$r_reason" "squash 本文になるテキスト" "--body の綴りの検知"

it "--body がクリーンでも、リモートの本文・コミットは別途見る（安全側に倒す設計）"
cmd="gh pr merge 1 --squash --body \"この本文はクリーンです。\""
result="$(decision_and_reason_with_fake_gh "$cmd" "$fixture_body_midsentence")"
r_reason="${result#*$'\t'}"
assert_contains "$r_reason" "squash 本文になるテキスト" "--body がクリーンでもリモート側の綴りを検知する"

it "--body に綴りが無く、リモートもクリーンなら理由は従来どおり（対照群）"
cmd="gh pr merge 1 --squash --body \"この本文はクリーンです。\""
result="$(decision_and_reason_with_fake_gh "$cmd" "$fixture_clean")"
r_reason="${result#*$'\t'}"
assert_eq "$r_reason" "$BASE_MERGE_REASON" "--body・リモートともにクリーンなときの理由"

it "--body-file の中身は読まず、確認できていない扱いにする（実測で判明した漏れ）"
result="$(decision_and_reason_with_fake_gh 'gh pr merge 1 --squash --body-file notes.md' "$fixture_clean")"
r_decision="${result%%$'\t'*}"
r_reason="${result#*$'\t'}"
assert_eq "$r_decision" "ask" "判定"
assert_contains "$r_reason" "確認できていません" "--body-file 使用時の理由"
assert_contains "$r_reason" "body-file" "--body-file 使用時の理由に具体的な対象が書かれている"

it "--body-file（= 連結）でも同じく確認できていない扱いにする"
result="$(decision_and_reason_with_fake_gh 'gh pr merge 1 --squash --body-file=notes.md' "$fixture_clean")"
r_reason="${result#*$'\t'}"
assert_contains "$r_reason" "確認できていません" "--body-file（= 連結）使用時の理由"

it "--body-file があっても --subject に綴りがあれば found が優先される（優先順位の確認）"
subj_arg="$(ci_skip_marker 'skip actions')"
cmd="gh pr merge 1 --squash --body-file notes.md --subject \"${subj_arg}\""
result="$(decision_and_reason_with_fake_gh "$cmd" "$fixture_clean")"
r_reason="${result#*$'\t'}"
assert_contains "$r_reason" "squash 本文になるテキスト" "--body-file と --subject 併存時、found が優先される"

it "--subject（= 連結）に渡した文字列の綴りも検知する"
cmd="gh pr merge 1 --squash --subject=\"$(ci_skip_marker 'no ci')\""
result="$(decision_and_reason_with_fake_gh "$cmd" "$fixture_clean")"
r_reason="${result#*$'\t'}"
assert_contains "$r_reason" "squash 本文になるテキスト" "--subject（= 連結）の綴りの検知"

# ── 複数の gh pr merge を同じコマンドで実行する場合（指摘: 実測で判明した漏れ）─
#
# gh pr merge 1 && gh pr merge 2 のように 1 つのコマンドへ複数の対象があると、
# 承認は 1 回しか出ない。片方だけを照会して判定を確定させると、確認していない
# 側の対象がそのまま実行されてしまう。

it "複数の対象のうち 2 件目にだけ綴りがあっても検知する（実測で判明した漏れの再現）"
map_file="$(new_workdir)/map-2nd.tsv"
printf '1\t%s\n2\t%s\n' "$fixture_clean" "$fixture_body_midsentence" > "$map_file"
out="$(printf '%s' "$(bash_payload 'gh pr merge 1 && gh pr merge 2')" \
  | FAKE_GH_FIXTURE="$fixture_clean" FAKE_GH_FIXTURE_MAP="$map_file" PATH="$fakebin:$PATH" bash "$HOOK")"
r_reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
assert_contains "$r_reason" "squash 本文になるテキスト" "複数対象のうち 2 件目の綴りの検知"

it "複数の対象のうち 1 件目にだけ綴りがあっても検知する（順序に依らないことの確認）"
map_file="$(new_workdir)/map-1st.tsv"
printf '1\t%s\n2\t%s\n' "$fixture_body_midsentence" "$fixture_clean" > "$map_file"
out="$(printf '%s' "$(bash_payload 'gh pr merge 1 && gh pr merge 2')" \
  | FAKE_GH_FIXTURE="$fixture_clean" FAKE_GH_FIXTURE_MAP="$map_file" PATH="$fakebin:$PATH" bash "$HOOK")"
r_reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
assert_contains "$r_reason" "squash 本文になるテキスト" "複数対象のうち 1 件目の綴りの検知"

it "複数の対象がいずれもクリーンなら理由は従来どおり（対照群。多いだけで unavailable へ倒していない）"
map_file="$(new_workdir)/map-both-clean.tsv"
printf '1\t%s\n2\t%s\n' "$fixture_clean" "$fixture_clean" > "$map_file"
out="$(printf '%s' "$(bash_payload 'gh pr merge 1 && gh pr merge 2')" \
  | FAKE_GH_FIXTURE="$fixture_clean" FAKE_GH_FIXTURE_MAP="$map_file" PATH="$fakebin:$PATH" bash "$HOOK")"
r_reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')"
assert_eq "$r_reason" "$BASE_MERGE_REASON" "複数対象がいずれもクリーンなときの理由"

# ── フックと land 雛形の綴り一覧が一致すること（指摘）───────────────────────────
#
# scripts/confirm-merge-hook.sh の SQUASH_CI_SKIP_RE と、squash 前に人手で同じ
# 判定を行う手順（.ai-playbook/templates/claude-skill-land.md の対応する手順）
# の grep パターンは、独立した文字列として存在する。どちらかへだけ綴りを足すと
# 人手の手順とフックの検査がずれ、見落としか誤警告になる。一致を機械で検査し、
# 食い違いに気づけるようにする。
#
# .ai-playbook/templates/claude-skill-land.md はこのフックの所有物ではない。
# 読み取りと、一致を検査するこのテストの追加だけをこの指摘に限り行い、雛形
# 自体は編集しない。
#
# 抽出は単一引用符区切りのフィールド分割（awk -F"'"）で行う。両ファイルとも
# 対象の行にはパターンを挟む単一引用符が 1 組しか無いため、sed の後方参照や
# GNU 拡張に頼らず、BSD 系の awk でも同じ結果になる（移植性）。

it "フックと land 雛形の CI 抑止の綴り一覧が一致する"
hook_re="$(awk -F"'" '/SQUASH_CI_SKIP_RE=/{print $2}' "$HOOK")"
land_re="$(awk -F"'" '/grep -n -i -E /{print $2}' "$PLAYBOOK_SRC/templates/claude-skill-land.md")"
if [[ -z "$hook_re" ]]; then
  fail "フック側の SQUASH_CI_SKIP_RE を抽出できなかった（抽出そのものが壊れている疑い）"
elif [[ -z "$land_re" ]]; then
  fail "land 雛形側の grep パターンを抽出できなかった（抽出そのものが壊れている疑い）"
else
  assert_eq "$hook_re" "$land_re" "CI 抑止の綴り一覧（フック側 vs land 雛形側）"
fi

exit_with_result
