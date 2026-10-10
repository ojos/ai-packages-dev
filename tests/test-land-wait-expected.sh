#!/usr/bin/env bash
# test-land-wait-expected.sh — land スキルの雛形が、CI の待ちで「動くはずのワークフロー」を
# 求めて抜け落ちを検知できることを、雛形から処理を取り出して実行して検証する（#513）。
#
# ## 背景
#
# 雛形 .ai-playbook/templates/claude-skill-land.md の 2「CI の完了を待つ」は、「30 秒あけて
# 2 回同じ一覧なら抜ける」だけだった。先に作られた実行が完了したあと、別のワークフローの
# 実行の作成が 30 秒を超えて遅れると、そのワークフローを見ないまま RUNS_GREEN になる。
# 修正は、PR の head の .github/workflows/ から動くはずのワークフローを求め、すべてに実行が
# 付くまで抜けない（付かなければ RUNS_MISSING）こと。
#
# ## 検査
#
# 文章を読んで照合するのではなく、雛形の目印（# >>> land:... / # <<< land:...）で囲まれた
# 関数を取り出して実行する。
#   (1) 動くはずのワークフローを求める部分を、仕込みのリポジトリで実行する。
#   (2) 最後の判定を、仕込みの一覧で実行する（実行が付いていないとき RUNS_GREEN を出さない）。
#   (3) 雛形のコードブロックに「パイプの後ろの grep -q」が無い。
#   (4) 判定の出力に RUNS_MISSING があり、既存の 4 つが残っている。
#
# bash 3.2 互換を維持する（mapfile を使わない）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-land-wait-expected"

TEMPLATE="$REPO_ROOT/.ai-playbook/templates/claude-skill-land.md"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/land-wait.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# extract <名前> — 雛形から目印で囲まれた部分を出す（目印の行は含めない）。
extract() {
  awk -v b="# >>> land:$1" -v e="# <<< land:$1" '
    $0 == e { on = 0 }
    on { print }
    $0 == b { on = 1 }' "$TEMPLATE"
}

EXP_SRC="$(extract expected-workflows)"
VERDICT_SRC="$(extract runs-verdict)"

it "雛形から、動くはずのワークフローを求める部分と最後の判定の部分を取り出せる"
if [[ -n "$EXP_SRC" && -n "$VERDICT_SRC" ]]; then pass; else fail "目印で囲まれた部分が空（# >>> land:expected-workflows / land:runs-verdict）"; fi

printf '%s\n' "$EXP_SRC" > "$WORK/expected.sh"
printf '%s\n' "$VERDICT_SRC" > "$WORK/verdict.sh"

# --- (1) 動くはずのワークフロー ---------------------------------------------

REPO="$WORK/repo"
mkdir -p "$REPO/.github/workflows"
git init -q "$REPO"
wf() { printf '%s\n' "${@:2}" > "$REPO/.github/workflows/$1"; }

wf block.yml 'name: block' 'on:' '  push:' '  pull_request:' 'jobs: {}'
wf inline.yml 'name: inline' 'on: [push, pull_request]' 'jobs: {}'
wf scalar.yml 'on: pull_request' 'jobs: {}'
wf quoted.yaml '"on":' '  pull_request:' 'jobs: {}'
wf listed.yml 'on:' '  - push' '  - pull_request' 'jobs: {}'
wf paths.yml 'on:' '  pull_request:' '    paths:' '      - "src/**"' 'jobs: {}'
wf ignore.yml 'on:' '  pull_request:' '    paths-ignore:' '      - "docs/**"' 'jobs: {}'
wf inline-paths.yml 'on:' '  pull_request: { paths: ["src/**"] }' 'jobs: {}'
wf types.yml 'on:' '  pull_request:' '    types: [closed]' 'jobs: {}'
wf types-default.yml 'on:' '  pull_request:' '    types: [opened, synchronize, reopened]' 'jobs: {}'
wf types-ready.yml 'on:' '  pull_request:' '    types: [opened, synchronize, reopened, ready_for_review]' 'jobs: {}'
wf types-block.yml 'on:' '  pull_request:' '    types:' '      - opened' '      - synchronize' 'jobs: {}'
wf types-block-flush.yml 'on:' '  pull_request:' '    types:' '    - reopened' '    - opened' '    - synchronize' 'jobs: {}'
wf types-opened.yml 'on:' '  pull_request:' '    types: [opened]' 'jobs: {}'
wf types-reopened.yml 'on:' '  pull_request:' '    types: [reopened, synchronize]' 'jobs: {}'
wf types-block-opened.yml 'on:' '  pull_request:' '    types:' '      - opened' 'jobs: {}'
wf branches.yml 'on:' '  pull_request:' '    branches: [develop]' 'jobs: {}'
wf branches-ignore.yml 'on:' '  pull_request:' '    branches-ignore: [main]' 'jobs: {}'
wf push-only.yml 'on:' '  push:' '    paths: ["x"]' 'jobs: {}'
wf target.yml 'on:' '  pull_request_target:' 'jobs: {}'
wf push-paths.yml 'on:' '  push:' '    paths:' '      - "a"' '  pull_request:' 'jobs: {}'
wf push-branches.yml 'on:' '  push:' '    branches: [main]' '  pull_request:' 'jobs: {}'
wf comment.yml 'on:' '  # pull_request:' '  push:' 'jobs: {}'
wf notyaml.txt 'on: pull_request'
wf base-only.yml 'on: pull_request' 'jobs: {}'
GITC=(git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false)
(
  cd "$REPO" || exit 1
  git add -A
  "${GITC[@]}" commit -q -m base
)
BASE_SHA="$(cd "$REPO" && git rev-parse HEAD)"
# head: base にあったものを消し、新しいものを足す
rm -f "$REPO/.github/workflows/base-only.yml"
wf head-new.yml 'on: pull_request' 'jobs: {}'
(
  cd "$REPO" || exit 1
  git add -A
  "${GITC[@]}" commit -q -m head
)
HEAD_SHA="$(cd "$REPO" && git rev-parse HEAD)"
# 作業ツリーだけにあるワークフローは、コミットの中身ではないので拾わない
wf worktree-only.yml 'on: pull_request' 'jobs: {}'

expected_in() { # <作業ディレクトリ> <head> <base>
  (cd "$1" && bash -c '. "$1"; expected_workflows "$2" "$3"' _ "$WORK/expected.sh" "$2" "$3" 2>&1)
}

# push-paths.yml / push-branches.yml は pull_request 側に絞り込みが無いので含まれる
WANT="$(printf '%s\n' \
  .github/workflows/block.yml \
  .github/workflows/types-default.yml \
  .github/workflows/types-ready.yml \
  .github/workflows/types-block.yml \
  .github/workflows/types-block-flush.yml \
  .github/workflows/inline.yml \
  .github/workflows/listed.yml \
  .github/workflows/quoted.yaml \
  .github/workflows/scalar.yml \
  .github/workflows/push-paths.yml \
  .github/workflows/push-branches.yml | sort)"

it "ブロックの形・1 行の形・引用符付き・リスト形の pull_request を拾い、paths / types / branches 絞り・pull_request なし・コメント・作業ツリーだけのものは除く"
assert_eq "$(expected_in "$REPO" "$HEAD_SHA" "$BASE_SHA")" "$WANT" "動くはずのワークフローの一覧"

it "head だけにあるワークフロー（新しく足したもの）も、base だけにあるワークフロー（head で消えたもの）も数えない"
GOT="$(expected_in "$REPO" "$HEAD_SHA" "$BASE_SHA")"
case "$GOT" in
  *head-new.yml*|*base-only.yml*) fail "片方にしか無いものが入っている: $GOT" ;;
  *) pass ;;
esac

it "サブディレクトリから実行しても、同じ一覧を出す（--full-tree）"
assert_eq "$(expected_in "$REPO/.github/workflows" "$HEAD_SHA" "$BASE_SHA")" "$WANT" "サブディレクトリからの一覧"

it "コミットを読めなかったときは、空として扱わず失敗（終了コード 1）にする"
set +e
OUT="$(cd "$REPO" && bash -c '. "$1"; expected_workflows "$2" "$3"' _ "$WORK/expected.sh" "$HEAD_SHA" 0000000000000000000000000000000000000000 2>/dev/null)"
RC=$?
if [[ "$RC" -ne 0 && -z "$OUT" ]]; then pass; else fail "終了コード ${RC}、出力 '${OUT}'"; fi

it "動くはずのワークフローが本当に 0 本のときは、成功（終了コード 0）で空を出す"
EMPTY="$WORK/empty"
mkdir -p "$EMPTY/.github/workflows"
git init -q "$EMPTY"
wf2() { printf '%s\n' "${@:2}" > "$EMPTY/.github/workflows/$1"; }
wf2 only-push.yml 'on: push' 'jobs: {}'
( cd "$EMPTY" && git add -A && "${GITC[@]}" commit -q -m e )
ES="$(cd "$EMPTY" && git rev-parse HEAD)"
set +e
OUT="$(expected_in "$EMPTY" "$ES" "$ES")"
RC=$?
if [[ "$RC" -eq 0 && -z "$OUT" ]]; then pass; else fail "終了コード ${RC}、出力 '${OUT}'"; fi

# --- 有効なワークフローだけに絞る ---

ACTIVE_JSON='{"total_count":3,"workflows":[
 {"path":".github/workflows/block.yml","state":"active"},
 {"path":".github/workflows/inline.yml","state":"disabled_manually"},
 {"path":".github/workflows/scalar.yml","state":"disabled_inactivity"}]}'
ACTIVE_JQ="$(bash -c '. "$1"; printf "%s" "$active_jq"' _ "$WORK/expected.sh")"

it "有効なワークフローを読む jq の式が、仕込みの JSON から state が active の path だけを出す"
assert_eq "$(printf '%s' "$ACTIVE_JSON" | jq -r "$ACTIVE_JQ")" ".github/workflows/block.yml" "有効な path"

it "無効にしたワークフローは数えない（filter_active）"
ACT="$(printf '%s' "$ACTIVE_JSON" | jq -r "$ACTIVE_JQ")"
GOT="$(bash -c '. "$1"; filter_active "$2" "$3"' _ "$WORK/expected.sh" "$WANT" "$ACT")"
assert_eq "$GOT" ".github/workflows/block.yml" "有効なものだけ"

# --- (2) 最後の判定 ----------------------------------------------------------

TAB="$(printf '\t')"
# 列: workflow_id, run_number, status, conclusion, name, path
ROW_CI="1${TAB}3${TAB}completed${TAB}success${TAB}ci${TAB}.github/workflows/ci.yml"
ROW_ID="2${TAB}1${TAB}completed${TAB}success${TAB}identity-guard${TAB}.github/workflows/identity-guard.yml"
ROW_BAD="1${TAB}3${TAB}completed${TAB}failure${TAB}ci${TAB}.github/workflows/ci.yml"
ROW_RUN="1${TAB}3${TAB}in_progress${TAB}-${TAB}ci${TAB}.github/workflows/ci.yml"

verdict() { # <listed> <missing> <実行の一覧>
  printf '%s\n' "$3" | bash -c '. "$1"; runs_verdict "$2" "$3"' _ "$WORK/verdict.sh" "$1" "$2"
}
missing() { # <動くはずの一覧> <実行の一覧>
  bash -c '. "$1"; missing_workflows "$2" "$3"' _ "$WORK/verdict.sh" "$1" "$2"
}

EXPECTED_BOTH=".github/workflows/ci.yml
.github/workflows/identity-guard.yml"
ONLY_ID="$ROW_ID"
BOTH="$ROW_ID
$ROW_CI"

it "実行が付いていないワークフローを数える（identity-guard だけ付いて ci が無い）"
assert_eq "$(missing "$EXPECTED_BOTH" "$ONLY_ID")" ".github/workflows/ci.yml" "付いていないワークフロー"

it "すべてに実行が付いていれば、付いていないワークフローは無い"
assert_eq "$(missing "$EXPECTED_BOTH" "$BOTH")" "" "付いていないワークフロー"

it "動くはずのワークフローに実行が付いていないとき、RUNS_MISSING を出し RUNS_GREEN を出さない"
assert_eq "$(verdict 1 "$(missing "$EXPECTED_BOTH" "$ONLY_ID")" "$ONLY_ID")" "RUNS_MISSING" "判定"

it "すべてに実行が付き通っていれば RUNS_GREEN"
assert_eq "$(verdict 1 "" "$BOTH")" "RUNS_GREEN" "判定"

it "失敗があれば RUNS_NOT_GREEN"
assert_eq "$(verdict 1 "" "$ROW_ID
$ROW_BAD")" "RUNS_NOT_GREEN" "判定"

it "未完了があれば RUNS_NOT_GREEN（時間切れ）"
assert_eq "$(verdict 1 "" "$ROW_RUN")" "RUNS_NOT_GREEN" "判定"

it "一覧が空で読めていれば RUNS_NONE"
assert_eq "$(verdict 1 "" "")" "RUNS_NONE" "判定"

it "一覧を読めなかったときは RUNS_UNKNOWN（付いていない表示より優先）"
assert_eq "$(verdict 0 "x" "")" "RUNS_UNKNOWN" "判定"

# --- (3)(4) 雛形の文面 -------------------------------------------------------

# 判定（PATTERN と find_offenders）は tests/test-no-pipe-to-grep-q.sh のものをそのまま取り出して使う。
# 写しを持つと、検出の仕様が変わったときに片方だけ古くなるため。そのファイルは実行すると検査まで走るので
# source できず、定義の範囲（G=... から find_offenders の閉じ括弧まで）だけを取り出す。
it "雛形のコードブロックに、パイプの後ろの grep -q が無い（test-no-pipe-to-grep-q.sh の判定を使う）"
DEFS="$(awk '/^G="gre"$/ { on = 1 } on { print } on && /^}$/ { exit }' "$TESTS_DIR/test-no-pipe-to-grep-q.sh")"
if [[ "$DEFS" != *find_offenders* ]]; then
  fail "test-no-pipe-to-grep-q.sh から find_offenders を取り出せない"
else
  awk '/^```/ { c = !c; next } c { print }' "$TEMPLATE" > "$WORK/template-code.sh"
  # 判定が働くことの確認（検出対象の綴りは変数で組み立てる）
  G="gre"; G="${G}p"
  printf '%s\n' "x | ${G} -q a" > "$WORK/probe.sh"
  HITS="$(bash -c "$DEFS"'
find_offenders "$1"' _ "$WORK/probe.sh")"
  OFF="$(bash -c "$DEFS"'
find_offenders "$1"' _ "$WORK/template-code.sh")"
  if [[ -z "$HITS" ]]; then fail "取り出した判定が、仕込みの grep -q を検出しない"
  elif [[ -n "$OFF" ]]; then fail "雛形のコードにパイプの後ろの grep -q がある: $OFF"
  else pass; fi
fi

it "判定の出力の一覧に RUNS_MISSING と EXPECTED_UNKNOWN があり、既存の 4 つが残っている"
LIST="$(awk '/^- `(RUNS|EXPECTED)_[A-Z_]+`:/ { sub(/^- `/, ""); sub(/`.*/, ""); print }' "$TEMPLATE" | sort | tr '\n' ' ')"
assert_eq "$LIST" "EXPECTED_UNKNOWN RUNS_GREEN RUNS_MISSING RUNS_NONE RUNS_NOT_GREEN RUNS_UNKNOWN " "判定の出力の一覧"

it "PR の head の取得でリモート名 origin を決め打ちしない"
if command grep -E 'git fetch[^`]*origin' "$TEMPLATE" >/dev/null; then fail "git fetch に origin が書かれている"; else pass; fi

it "RUNS_MISSING の説明に、数えない条件と、数えたのに実行が付かないときの見方がある"
if command grep -E 'RUNS_MISSING.*数えない条件.*数えたのに実行が付かない' "$TEMPLATE" >/dev/null; then pass; else fail "説明が見つからない"; fi

it "path が null の実行でも一覧を読めるよう、jq が .path // \"\" で受ける"
if command grep -F '.path // ' "$TEMPLATE" >/dev/null; then pass; else fail ".path // が無い"; fi

exit_with_result
