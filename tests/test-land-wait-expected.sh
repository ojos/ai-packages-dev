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

wf block.yml 'name: block' 'on:' '  push:' '  pull_request:' '    branches: [main]' 'jobs: {}'
wf inline.yml 'name: inline' 'on: [push, pull_request]' 'jobs: {}'
wf scalar.yml 'on: pull_request' 'jobs: {}'
wf quoted.yaml '"on":' '  pull_request:' 'jobs: {}'
wf listed.yml 'on:' '  - push' '  - pull_request' 'jobs: {}'
wf paths.yml 'on:' '  pull_request:' '    paths:' '      - "src/**"' 'jobs: {}'
wf ignore.yml 'on:' '  pull_request:' '    paths-ignore:' '      - "docs/**"' 'jobs: {}'
wf inline-paths.yml 'on:' '  pull_request: { paths: ["src/**"] }' 'jobs: {}'
wf push-only.yml 'on:' '  push:' '    paths: ["x"]' 'jobs: {}'
wf target.yml 'on:' '  pull_request_target:' 'jobs: {}'
wf push-paths.yml 'on:' '  push:' '    paths:' '      - "a"' '  pull_request:' 'jobs: {}'
wf comment.yml 'on:' '  # pull_request:' '  push:' 'jobs: {}'
wf notyaml.txt 'on: pull_request'
(
  cd "$REPO" || exit 1
  git add -A
  git -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m init
)
# 作業ツリーだけにあるワークフローは、head の中身ではないので拾わない
wf worktree-only.yml 'on: pull_request' 'jobs: {}'

GOT="$(cd "$REPO" && bash -c '. "$1"; expected_workflows HEAD' _ "$WORK/expected.sh" 2>&1)"
WANT="$(printf '%s\n' \
  .github/workflows/block.yml \
  .github/workflows/inline.yml \
  .github/workflows/listed.yml \
  .github/workflows/quoted.yaml \
  .github/workflows/scalar.yml | sort)"
# push-paths.yml は pull_request 側に paths が無いので含まれる（push の paths は無関係）
WANT="$(printf '%s\n%s\n' "$WANT" .github/workflows/push-paths.yml | sort)"

it "ブロックの形・1 行の形・引用符付き・リスト形の pull_request を拾い、paths 絞り・pull_request なし・コメント・作業ツリーだけのものは除く"
assert_eq "$GOT" "$WANT" "動くはずのワークフローの一覧"

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

it "雛形のコードブロックに、パイプの後ろの grep -q が無い"
G="gre"; G="${G}p"
HITS="$(awk '/^```/ { c = !c; next } c { print NR ": " $0 }' "$TEMPLATE" \
  | command grep -E "[|][[:space:]]*${G}[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(-[A-Za-z]*q|--quiet)" || true)"
assert_eq "$HITS" "" "パイプの後ろの grep -q"

it "判定の出力の一覧に RUNS_MISSING と既存の 4 つがある"
LIST="$(awk '/^- `RUNS_[A-Z_]+`:/ { sub(/^- `/, ""); sub(/`.*/, ""); print }' "$TEMPLATE" | sort | tr '\n' ' ')"
assert_eq "$LIST" "RUNS_GREEN RUNS_MISSING RUNS_NONE RUNS_NOT_GREEN RUNS_UNKNOWN " "判定の出力の一覧"

it "PR の head の取得でリモート名 origin を決め打ちしない"
if command grep -E 'git fetch[^`]*origin' "$TEMPLATE" >/dev/null; then fail "git fetch に origin が書かれている"; else pass; fi

exit_with_result
