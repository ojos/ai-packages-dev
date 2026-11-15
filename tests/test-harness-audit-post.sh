#!/usr/bin/env bash
# scripts/harness-audit-post.sh と .github/workflows/harness-audit.yml の検査（#724）。
#
# - 前回の印の選び方: このリポジトリの Actions（github-actions[bot]）の、形の正しい印だけを拾い、
#   人のコメント（第三者・MEMBER・OWNER）や形の崩れた印は拾わない
# - コメントの本文: 冒頭に承認の根拠にならない旨を置く。失敗のときは理由と前回の印を写す
# - run の通し: 偽の gh で、前回の印を起点に回し、追跡 issue へ 1 件だけコメントする
# - ワークフローの配線: schedule と workflow_dispatch を持ち、権限は contents: read と
#   issues: write だけで、harness-audit-post.sh run を呼び、投稿先が手順書の追跡 issue と一致する
#
# 検査は「ルートを受け取る関数」にしてあり、壊したフィクスチャへも同じ関数を当てる。
# ネットワークへは出ない（変更履歴は HARNESS_AUDIT_CHANGELOG でファイルを渡す）。
#
# bash 3.2 互換を維持する（連想配列・mapfile を使わない）。jq を要する（スクリプト自身の依存）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-harness-audit-post"

POST="$REPO_ROOT/scripts/harness-audit-post.sh"
WF_REL=".github/workflows/harness-audit.yml"
DOC_REL="docs/harness-audit.md"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-harness-audit-post.XXXXXX")"
trap 'rm -rf "$T"' EXIT

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq が見つかりません" >&2
  exit 1
fi

H='## ハーネスの棚卸し'

# コメントを 1 件の JSON にする。$1 = login、$2 = type、$3 = author_association、$4 = 本文。
comment() {
  jq -n --arg l "$1" --arg t "$2" --arg a "$3" --arg b "$4" \
    '{user: {login: $l, type: $t}, author_association: $a, body: $b}'
}

# --- 前回の印の選び方 ---

{
  printf '['
  comment github-actions[bot] Bot NONE "$H
<!-- harness-audit: checked-version=2.1.2 -->"
  printf ','
  comment stranger User NONE "$H
<!-- harness-audit: checked-version=2.1.9 -->"
  printf ','
  comment member User MEMBER "$H
<!-- harness-audit: checked-version=2.1.8 -->"
  printf ','
  comment owner User OWNER "$H
<!-- harness-audit: checked-version=2.1.7 -->"
  printf ']'
} > "$T/c1.json"

it "このリポジトリの Actions のコメントを拾い、後に付いた人のコメント（第三者・MEMBER・OWNER）は拾わない"
got="$("$POST" select "$T/c1.json")"
if [[ "$got" == *"checked-version=2.1.2"* ]]; then pass; else fail "got: $got"; fi

{
  printf '['
  comment github-actions[bot] Bot NONE "$H
<!-- harness-audit: checked-version=2.1.1 -->"
  printf ','
  comment github-actions[bot] User NONE "$H
<!-- harness-audit: checked-version=2.1.8 -->"
  printf ']'
} > "$T/c2.json"

it "名前だけ github-actions[bot] の利用者（種別が Bot でない）は拾わない"
got="$("$POST" select "$T/c2.json")"
if [[ "$got" == *"checked-version=2.1.1"* ]]; then pass; else fail "got: $got"; fi

{
  printf '['
  comment github-actions[bot] Bot NONE "$H
<!-- harness-audit: checked-version=2.1.3 -->"
  printf ','
  comment github-actions[bot] Bot NONE "見出しの無いコメント <!-- harness-audit: checked-version=2.1.6 -->"
  printf ','
  comment github-actions[bot] Bot NONE "$H 印の無いコメント"
  printf ','
  comment github-actions[bot] Bot NONE "$H
<!-- harness-audit: checked-version=2.1.x -->"
  printf ']'
  # ページごとの配列が並ぶ形（gh api --paginate の出力）
  printf '['
  comment github-actions[bot] Bot NONE "$H
<!-- harness-audit: checked-version=2.1.4 -->"
  printf ','
  comment github-actions[bot] Bot NONE "$H
<!-- harness-audit: checked-version=v2 -->"
  printf ']'
} > "$T/c3.json"

it "見出しと形の正しい印の両方を持つものだけを拾い、ページをまたいで最後の 1 件を選ぶ（形の崩れた印は飛ばす）"
got="$("$POST" select "$T/c3.json")"
if [[ "$got" == *"checked-version=2.1.4"* && "$got" != *"2.1.3"* ]]; then pass; else fail "got: $got"; fi

it "該当するコメントが無ければ空を出す"
printf '[]' > "$T/c4.json"
got="$("$POST" select "$T/c4.json")"
assert_eq "$got" "" "空の一覧"

# --- コメントの本文 ---

printf '> 自動の報告で、承認の根拠になりません。\n\n%s\n本文\n<!-- harness-audit: checked-version=2.1.5 -->\n' "$H" > "$T/out.md"
printf 'エラーの理由 ```x```\n' > "$T/err.txt"
printf '前回\n<!-- harness-audit: checked-version=2.1.4 -->\n' > "$T/prev.md"
: > "$T/empty.md"

it "成功の本文は、冒頭に承認の根拠にならない旨を置き、棚卸しの出力をそのまま載せる"
"$POST" compose 0 "$T/out.md" "$T/err.txt" "$T/prev.md" > "$T/body.md"
first="$(head -1 "$T/body.md")"
if [[ "$first" == *"承認の根拠になりません"* ]] && grep -qxF "$H" "$T/body.md" \
  && grep -q 'checked-version=2.1.5' "$T/body.md" && ! grep -q 'checked-version=2.1.4' "$T/body.md"; then
  pass
else
  fail "$(cat "$T/body.md")"
fi

it "失敗の本文は、見出し・理由・前回の印を持ち、コードブロックを閉じさせない"
"$POST" compose 2 "$T/out.md" "$T/err.txt" "$T/prev.md" > "$T/body.md"
if [[ "$(head -1 "$T/body.md")" == *承認の根拠になりません* ]] && grep -qxF "$H" "$T/body.md" \
  && grep -q 'エラーの理由' "$T/body.md" && grep -q '終了コード 2' "$T/body.md" \
  && grep -q 'checked-version=2.1.4' "$T/body.md" && ! grep -q 'checked-version=2.1.5' "$T/body.md" \
  && [[ "$(grep -c '^```$' "$T/body.md")" -eq 2 ]]; then
  pass
else
  fail "$(cat "$T/body.md")"
fi

it "失敗の本文は、前回の印が無ければ印を写さない"
"$POST" compose 2 "$T/out.md" "$T/err.txt" "$T/empty.md" > "$T/body.md"
if ! grep -q 'checked-version=' "$T/body.md"; then pass; else fail "$(cat "$T/body.md")"; fi

it "印の形と失敗のときの注意書きが、harness-audit.sh のものと一致する（複製の追随漏れ）"
a_re="$(sed -n "s/^CHECKED_MARK_RE='\(.*\)'$/\1/p" "$REPO_ROOT/scripts/harness-audit.sh")"
p_re="$(sed -n "s/^MARK_RE='\(.*\)'$/\1/p" "$POST")"
p_notice="$(sed -n "s/^NOTICE='\(.*\)'$/\1/p" "$POST")"
if [[ -n "$a_re" && "$a_re" == "$p_re" ]] && grep -qF "echo \"$p_notice\"" "$REPO_ROOT/scripts/harness-audit.sh"; then
  pass
else
  fail "印: [$a_re] [$p_re] / 注意書き: [$p_notice]"
fi

# --- run の通し（偽の gh） ---

mkdir -p "$T/bin" "$T/posted"
cat > "$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
# 偽の gh: コメントの一覧を返し、コメントの投稿を記録する。
case "${1:-} ${2:-}" in
  "api --paginate") cat "$FAKE_COMMENTS" ;;
  "issue comment")
    shift 2
    printf '%s\n' "$*" >> "$FAKE_POSTED/args"
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--body-file" ]]; then cp "$2" "$FAKE_POSTED/body.md"; fi
      shift
    done ;;
  *) echo "偽の gh: 想定外の呼び出し: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$T/bin/gh"

cat > "$T/changelog.md" <<'EOF'
# Changelog

## 2.1.4

- Fixed a third thing

## 2.1.3

- Fixed something

## 2.1.2

- Fixed another thing
EOF

# run を偽の gh で回す。$1 = 変更履歴のファイル。終了コードは RC に入る。
run_post() {
  rm -f "$T/posted/args" "$T/posted/body.md"
  PATH="$T/bin:$PATH" FAKE_COMMENTS="$T/c1.json" FAKE_POSTED="$T/posted" GITHUB_REPOSITORY="example/repo" \
    HARNESS_AUDIT_CHANGELOG="$1" "$POST" run > "$T/run.out" 2> "$T/run.err"
  RC=$?
}

it "run は前回の印（2.1.2）を起点に回し（2.1.2 は含まない）、追跡 issue へ 1 件だけコメントする"
run_post "$T/changelog.md"
issue="$(sed -n 's/^TRACKING_ISSUE=//p' "$POST")"
if [[ "$RC" -eq 0 ]] && [[ "$(wc -l < "$T/posted/args" | tr -d ' ')" -eq 1 ]] \
  && grep -q "^$issue --repo example/repo --body-file " "$T/posted/args" \
  && [[ "$(head -1 "$T/posted/body.md")" == *承認の根拠になりません* ]] \
  && grep -q 'checked-version=2.1.4' "$T/posted/body.md" && grep -q '見た版の範囲: 2.1.3 〜 2.1.4' "$T/posted/body.md"; then
  pass
else
  fail "rc=$RC $(cat "$T/run.err") $(cat "$T/posted/args" 2>/dev/null)"
fi

it "run は棚卸しが失敗したら、前回の印を写した失敗のコメントを付けて 1 で終わる"
run_post "$T/no-such-changelog.md"
if [[ "$RC" -eq 1 ]] && [[ -f "$T/posted/body.md" ]] && grep -q '空の候補として扱いません' "$T/posted/body.md" \
  && grep -q 'checked-version=2.1.2' "$T/posted/body.md"; then
  pass
else
  fail "rc=$RC $(cat "$T/run.err")"
fi

it "run は前回のコメントを読めなければ、棚卸しを回さず、失敗のコメントを付けて 1 で終わる"
printf 'これは JSON ではない' > "$T/broken.json"
rm -f "$T/posted/args" "$T/posted/body.md"
PATH="$T/bin:$PATH" FAKE_COMMENTS="$T/broken.json" FAKE_POSTED="$T/posted" GITHUB_REPOSITORY="example/repo" \
  HARNESS_AUDIT_CHANGELOG="$T/changelog.md" "$POST" run > "$T/run.out" 2> "$T/run.err"
RC=$?
if [[ "$RC" -eq 1 ]] && [[ -f "$T/posted/body.md" ]] && grep -q '前回のコメントを読めず' "$T/posted/body.md" \
  && ! grep -q 'checked-version=' "$T/posted/body.md"; then
  pass
else
  fail "rc=$RC $(cat "$T/run.err")"
fi

it "失敗の理由は、日本語の文字の途中で切らない"
python3 -c 'print("あ" * 1000)' > "$T/longerr.txt"
"$POST" compose 2 "$T/out.md" "$T/longerr.txt" "$T/empty.md" > "$T/body.md"
if iconv -f UTF-8 -t UTF-8 "$T/body.md" >/dev/null 2>&1; then pass; else fail "本文に不正な UTF-8 がある"; fi

# --- ワークフローの配線 ---

# ルート $1 のワークフローが、契機・権限・呼ぶスクリプト・投稿先の宣言を満たすか。
check_workflow() {
  local root="$1" wf="$1/$WF_REL" doc_issue script_issue perms
  [[ -f "$wf" ]] || { echo "ワークフローが無い: $WF_REL"; return 1; }
  # on: の直下に schedule と workflow_dispatch がある
  awk '/^on:/ { f = 1; next } f && /^[^ #]/ { f = 0 } f' "$wf" > "$T/on.txt"
  grep -Eq '^  schedule:' "$T/on.txt" || { echo "on: に schedule が無い"; return 1; }
  grep -Eq '^    - cron: "[0-9]' "$T/on.txt" || { echo "schedule に cron が無い"; return 1; }
  grep -Eq '^  workflow_dispatch:' "$T/on.txt" || { echo "on: に workflow_dispatch が無い"; return 1; }
  # 最上位の permissions が contents: read と issues: write だけで、ジョブの permissions は無い
  perms="$(awk '/^permissions:/ { f = 1; next } f && /^[^ #]/ { f = 0 } f && NF' "$wf" | sed 's/[[:space:]]*#.*//' | sort | tr -d ' ' | tr '\n' ' ')"
  [[ "$perms" == "contents:read issues:write " ]] || { echo "permissions が contents: read と issues: write だけではない: $perms"; return 1; }
  if grep -Eq '^    permissions:' "$wf"; then echo "ジョブに permissions がある"; return 1; fi
  # 呼ぶのは harness-audit-post.sh run だけで、gh で直接書き込まない
  grep -Eq '^ +run: bash scripts/harness-audit-post\.sh run$' "$wf" || { echo "harness-audit-post.sh run を呼んでいない"; return 1; }
  [[ -f "$root/scripts/harness-audit-post.sh" ]] || { echo "scripts/harness-audit-post.sh が実在しない"; return 1; }
  if grep -Eq 'gh (issue|pr|api)' "$wf"; then echo "ワークフローが gh で直接書き込んでいる"; return 1; fi
  # 投稿先（スクリプトの TRACKING_ISSUE）が手順書の追跡 issue と一致する
  script_issue="$(sed -n 's/^TRACKING_ISSUE=\([0-9][0-9]*\)$/\1/p' "$root/scripts/harness-audit-post.sh")"
  doc_issue="$(sed -n 's/^追跡 issue: #\([0-9][0-9]*\)$/\1/p' "$root/$DOC_REL")"
  [[ -n "$script_issue" && "$script_issue" == "$doc_issue" ]] || { echo "投稿先（#$script_issue）が手順書の追跡 issue（#$doc_issue）と一致しない"; return 1; }
}

it "ワークフローが契機・最小の権限・呼ぶスクリプト・投稿先の宣言を満たす"
if out="$(check_workflow "$REPO_ROOT" 2>&1)"; then pass; else fail "$out"; fi

# 実物を写した小さなルートを作って出す。
make_fixture() {
  local d="$T/fix-$1"
  mkdir -p "$d/.github/workflows" "$d/scripts" "$d/docs"
  cp "$REPO_ROOT/$WF_REL" "$d/$WF_REL"
  cp "$POST" "$d/scripts/harness-audit-post.sh"
  cp "$REPO_ROOT/$DOC_REL" "$d/$DOC_REL"
  printf '%s' "$d"
}

# ルート $1 のファイル $2 で、$3 を含む行を $4 に置き換える（$4 が空なら行を消す）。
mutate() {
  local f="$1/$2"
  awk -v from="$3" -v to="$4" 'index($0, from) { if (to != "") print to; next } { print }' "$f" > "$f.new" && cat "$f.new" > "$f" && rm -f "$f.new"
}

expect_fail() {
  if check_workflow "$1" >/dev/null 2>&1; then fail "壊したフィクスチャで落ちなかった"; else pass; fi
}

it "壊していないフィクスチャは通る（下の落ちる検査が空振りでない）"
D="$(make_fixture ok)"
if out="$(check_workflow "$D" 2>&1)"; then pass; else fail "$out"; fi

it "schedule が無いと落ちる"
D="$(make_fixture nosched)"; mutate "$D" "$WF_REL" '  schedule:' ''; mutate "$D" "$WF_REL" '- cron:' ''
expect_fail "$D"

it "workflow_dispatch が無いと落ちる"
D="$(make_fixture nodispatch)"; mutate "$D" "$WF_REL" '  workflow_dispatch:' ''
expect_fail "$D"

it "権限を足すと落ちる"
D="$(make_fixture moreperm)"; mutate "$D" "$WF_REL" '  issues: write' '  issues: write
  pull-requests: write'
expect_fail "$D"

it "contents: write にすると落ちる"
D="$(make_fixture contentswrite)"; mutate "$D" "$WF_REL" '  contents: read' '  contents: write'
expect_fail "$D"

it "別のスクリプトを呼ぶと落ちる"
D="$(make_fixture otherrun)"; mutate "$D" "$WF_REL" 'run: bash scripts/harness-audit-post.sh run' '        run: bash scripts/harness-audit.sh'
expect_fail "$D"

it "投稿先が手順書の追跡 issue と違うと落ちる"
D="$(make_fixture otherissue)"; mutate "$D" scripts/harness-audit-post.sh 'TRACKING_ISSUE=' 'TRACKING_ISSUE=1'
expect_fail "$D"

exit_with_result
