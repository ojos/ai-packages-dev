#!/usr/bin/env bash
# CI の shellcheck の導入手順が、apt のミラーの不調で止まり続けない形かを検査する（#551）。
#
# 2026-10-12、PR #550 の CI で `apt-get update` が apt のミラーに届かず 51 分止まった。
# 手順にもジョブにも時間の上限が無く、ジョブの上限（6 時間）まで待ち続ける形だった。
# ubuntu-latest には shellcheck が最初から入っているので、あれば導入しない形にし、
# 手順に時間の上限を付けた。この形が崩れていないことをここで確かめる。
#
# 見るのは .github/workflows/ci.yml の「Install shellcheck」の手順だけである。

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "$TESTS_DIR/lib.sh"

REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
CI="$REPO_ROOT/.github/workflows/ci.yml"

# 「Install shellcheck」の手順だけを取り出す（次の `- name:` か `- uses:` の手前まで）。
step="$(awk '
  /^ *- name: Install shellcheck *$/ { f = 1; print; next }
  f && /^ *- (name|uses):/ { exit }
  f { print }
' "$CI")"

it "ci.yml に Install shellcheck の手順がある"
if [[ -n "$step" ]]; then pass; else fail "手順が見つからない: $CI"; fi

it "手順の timeout-minutes が 10 分以下である"
tmo="$(printf '%s\n' "$step" | awk '/^ *timeout-minutes:/ { print $2; exit }')"
if [[ "$tmo" =~ ^[0-9]+$ ]] && (( tmo >= 1 && tmo <= 10 )); then pass; else fail "timeout-minutes が無いか、10 分を超える: ${tmo:-なし}"; fi

# 手順の run: のスクリプトを取り出し、偽の道具で実際に動かして確かめる。
# 文字列の位置で見ると、分岐のどちら側に apt-get があるかを取り違えるため。
script="$(printf '%s\n' "$step" | awk '
  /^ *run: *\|/ { f = 1; next }
  f { if (ind == "") { match($0, /^ */); ind = RLENGTH } print substr($0, ind + 1) }
')"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-shellcheck.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/with" "$WORK/without"
# 偽の sudo: 呼ばれた引数を記録するだけ（apt-get は sudo 経由で呼ばれる）
for d in with without; do
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/calls"\n' "$WORK/$d" > "$WORK/$d/sudo"
  chmod +x "$WORK/$d/sudo"
done
# 偽の shellcheck（「あるとき」の側だけに置く）
printf '#!/usr/bin/env bash\necho "ShellCheck - fake"\necho "version: 0"\n' > "$WORK/with/shellcheck"
chmod +x "$WORK/with/shellcheck"
# PATH には、偽の道具の置き場と、スクリプトが使う基本の道具だけをリンクした置き場を渡す。
# 実物のある場所（/usr/bin など）を PATH に入れると、ubuntu-latest のように shellcheck が
# /usr/bin にある環境で、「無いとき」の検査が実物を見つけてしまう。
mkdir -p "$WORK/base"
for c in bash head env cat; do
  ln -s "$(command -v "$c")" "$WORK/base/$c"
done
base_path="$WORK/base"

it "shellcheck があれば、apt-get を呼ばない"
if [[ -z "$script" ]]; then
  fail "run: のスクリプトを取り出せない"
elif PATH="$WORK/with:$base_path" bash -c "$script" >/dev/null 2>&1 && [[ ! -s "$WORK/with/calls" ]]; then
  pass
else
  fail "shellcheck があるのに sudo / apt-get が呼ばれた: $(cat "$WORK/with/calls" 2>/dev/null)"
fi

it "shellcheck が無ければ、apt-get で入れる"
if PATH="$WORK/without:$base_path" bash -c "$script" >/dev/null 2>&1 \
   && grep -q 'apt-get install -y shellcheck' "$WORK/without/calls" 2>/dev/null; then
  pass
else
  fail "shellcheck が無いのに apt-get install が呼ばれない: $(cat "$WORK/without/calls" 2>/dev/null)"
fi

# YAML の検査は、DCB のテストの assert_workflow_valid と同じ 3 段で行う（actionlint →
# PyYAML → 構造の検査）。道具の無い環境でも、検査を飛ばして成功扱いにしない。
it "ci.yml がワークフローとして読める"
tab="$(printf '\t')"
if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$CI" >/dev/null 2>&1; then pass; else fail "actionlint 検査に失敗: $CI"; fi
elif python3 -c 'import yaml' >/dev/null 2>&1; then
  if python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$CI" >/dev/null 2>&1; then pass; else fail "PyYAML の safe_load に失敗: $CI"; fi
elif grep -Eq '^on:' "$CI" && grep -Eq '^jobs:' "$CI" && ! grep -q "^${tab}" "$CI"; then
  pass
else
  fail "必須のトップのキー（on / jobs）の欠落、またはタブのインデント: $CI"
fi

exit_with_result
