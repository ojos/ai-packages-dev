#!/usr/bin/env bash
# Markdown の表の分断検査（scripts/check-table-breaks.sh）を検証する。
#
# 「描画するまで見えない壊れ方」を機械で見る検査であり、検知層としての性質を検査
# する。陽性（表の途中へ段落を差し込んだ文書で落ちる）だけでは足りない。陰性
# （正しい表だけの文書・フェンス内の `|` 行）を併せて見ないと、「常に落ちるだけの
# 検査」と区別が付かない。
#
# 生成物は git リポジトリとして複製し、対象の Markdown だけを差し替えて検査する
# （scripts/check-table-breaks.sh は git ls-files '*.md' を起点にするため）。
#
# ネットワークには出ない。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-check-table-breaks"

GIT_AS="git -c user.name=T -c user.email=t@example.com"

# 生成物の原本。bootstrap は 1 回だけ回し、以降は複製して使う。
BASE="$(new_workdir)/base"
run_bootstrap "$BASE" >/dev/null 2>&1

it "check-table-breaks.sh が常に生成され、実行可能である"
if [[ -f "$BASE/scripts/check-table-breaks.sh" ]]; then
  assert_mode "$BASE/scripts/check-table-breaks.sh" "755"
else
  fail "生成されていない: $BASE/scripts/check-table-breaks.sh"
fi

# 生成物の複製を git リポジトリとして用意し、そのパスを返す。
# 生成物自体にも .md（README 等）が含まれるため、対象の 1 本だけを別途 add する
# テストでも、走査対象が 0 件になることはない。
new_repo() {
  local out
  out="$(new_workdir)/p"
  cp -R "$BASE" "$out"
  (
    cd "$out" || exit 1
    git init -q
    git symbolic-ref HEAD refs/heads/main
    git add -A
    $GIT_AS commit -q -m c1
  ) >/dev/null 2>&1
  printf '%s' "$out"
}

# repo 内に 1 本の Markdown を追加してコミットする。
add_md() {
  local repo="$1" name="$2" content="$3"
  printf '%s' "$content" > "$repo/$name"
  ( cd "$repo" && git add -f "$name" && $GIT_AS commit -q -m "add-$name" ) >/dev/null 2>&1
}

# 検査を実行し、CHECK_OUT / CHECK_RC へ結果を入れる。
CHECK_OUT=""
CHECK_RC=0
run_check() {
  local repo="$1"
  CHECK_OUT="$(cd "$repo" && bash scripts/check-table-breaks.sh 2>&1)"
  CHECK_RC=$?
}

assert_fail() {
  local what="$1" needle="${2-}"
  if [[ "$CHECK_RC" -eq 0 ]]; then
    fail "$what: 落ちるべきところで通過した: $CHECK_OUT"
    return
  fi
  if ! printf '%s' "$CHECK_OUT" | grep -q 'TABLE_BREAKS_FAIL'; then
    fail "$what: TABLE_BREAKS_FAIL が出ていない: $CHECK_OUT"
    return
  fi
  if [[ -n "$needle" ]] && ! printf '%s' "$CHECK_OUT" | grep -qF "$needle"; then
    fail "$what: 期待した報告 '$needle' が無い: $CHECK_OUT"
    return
  fi
  pass
}

assert_pass() {
  local what="$1"
  if [[ "$CHECK_RC" -ne 0 ]]; then
    fail "$what: 通るべきところで落ちた: $CHECK_OUT"
  elif ! printf '%s' "$CHECK_OUT" | grep -q 'TABLE_BREAKS_PASS'; then
    fail "$what: TABLE_BREAKS_PASS が出ていない: $CHECK_OUT"
  else
    pass
  fi
}

# ── 陰性の基準線 ─────────────────────────────────────────────────────────────
#
# bootstrap の生成物そのものは Markdown を 1 本も含まない（--with-playbook を
# 選ばない既定構成では規範文書を配置しないため）。追跡 Markdown が 0 件では
# 「検査が成立していないことを合格にしない」側の判定が先に立ち、この検査の
# 主題（分断の有無）を確かめられない。プロジェクト自身の README（生成先に
# 実在する典型例）を模した 1 本を足したうえで基準線を取る。

it "正しい表を含む Markdown を 1 本足せば TABLE_BREAKS_PASS（陰性の基準線）"
# これが通らないと、以降の陽性はすべて「常に落ちる検査」でも成立してしまう。
repo="$(new_repo)"
add_md "$repo" "README.md" '# test

| a | b |
|---|---|
| 1 | 2 |
'
run_check "$repo"
assert_pass "分断なし"

# ── 陽性: 表の途中へ段落を差し込んだ文書 ─────────────────────────────────────

it "表の途中へ段落を差し込んだ文書を検知する（陽性、非0終了・該当箇所を出す）"
repo="$(new_repo)"
add_md "$repo" "broken.md" '| a | b |
|---|---|
| 1 | 2 |

差し込まれた段落。

| 3 | 4 |
| 5 | 6 |
'
run_check "$repo"
assert_fail "表の分断" "broken.md"

# ── 陰性（対照群）: 正しい表だけを含む文書 ────────────────────────────────────

it "正しい表だけを含む文書は通る（対照群）"
repo="$(new_repo)"
add_md "$repo" "valid.md" '# 見出し

| a | b |
|---|---|
| 1 | 2 |

段落を挟む。

| c | d |
| :-- | --: |
| 3 | 4 |
'
run_check "$repo"
assert_pass "正しい表のみ"

# ── 陰性（対照群）: フェンス（コードブロック）内の `|` 行 ────────────────────

it "フェンス内の \`|\` 行は報告しない（対照群）"
# フェンス内だけの文書だと「正しい表を 1 つも数えられませんでした」という
# 別の fail-closed 判定に当たってしまう（この検査自身の成立条件）。フェンス外の
# 正しい表を 1 つ併記し、フェンス内の判定だけを対照する。
repo="$(new_repo)"
add_md "$repo" "fenced.md" '# 見出し

| a | b |
|---|---|
| 1 | 2 |

本文。

```
| a | b |
| 1 | 2 |
```

続き。
'
run_check "$repo"
assert_pass "フェンス内は対象外"

it "フェンス内で \`|\` 行の直前に空行があっても報告しない（対照群、出力例の貼り直しを想定）"
# 「行頭が `|` である」「直前が空行」という表の先頭条件だけを見ると、フェンス内の
# 出力例の中に空行が 1 つ挟まった瞬間に表の先頭へ見えてしまう
# （scripts/check-table-breaks.sh 冒頭コメントが挙げる実例と同じ形）。フェンス
# 除外が効いていない限り、このフィクスチャは誤検知する。
repo="$(new_repo)"
add_md "$repo" "fenced-blank.md" '# 見出し

| a | b |
|---|---|
| 1 | 2 |

本文。

```
$ report

| 品質 | 時間 |
| q9 | 5,359 ms |
```

続き。
'
run_check "$repo"
assert_pass "フェンス内の空行直後も対象外"

# ── 陽性: 区切り行を持たない `|` 行ブロック ──────────────────────────────────

it "区切り行を持たない \`|\` 行ブロックを報告する"
# 正しい表を併記し、「正しい表を 1 つも数えられませんでした」という別の
# fail-closed 判定ではなく、区切り行なしの検出そのもので落ちることを確かめる。
repo="$(new_repo)"
add_md "$repo" "no-separator.md" '# 見出し

| a | b |
|---|---|
| 1 | 2 |

本文。

| c | d |
| 3 | 4 |

続き。
'
run_check "$repo"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "落ちるべきところで通過した: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -q 'TABLE_BREAKS_FAIL'; then
  fail "TABLE_BREAKS_FAIL が出ていない: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -qF 'no-separator.md'; then
  fail "期待した報告 'no-separator.md' が無い: $CHECK_OUT"
elif printf '%s' "$CHECK_OUT" | grep -q '正しい表を 1 つも数えられませんでした'; then
  fail "fail-closed（正しい表 0 件）で落ちており、区切り行なしの検出を確認できない: $CHECK_OUT"
else
  pass
fi

# ── 検査が成立していないことを合格にしない ────────────────────────────────────

it "git 管理外では落ちる（検査が成立していない）"
out="$(new_workdir)/p"
cp -R "$BASE" "$out"
run_check "$out"
assert_fail "git 管理外" "git の作業ツリーではありません"

it "追跡している Markdown が 1 件も無ければ落ちる"
# 空の出力を「該当なし」と読むと、検査していないのに合格になる。
out="$(new_workdir)/empty"
mkdir -p "$out/scripts"
cp "$BASE/scripts/check-table-breaks.sh" "$out/scripts/check-table-breaks.sh"
chmod +x "$out/scripts/check-table-breaks.sh"
(
  cd "$out" || exit 1
  git init -q
  git symbolic-ref HEAD refs/heads/main
  printf 'no markdown here\n' > "$out/not-markdown.txt"
  git add -A
  $GIT_AS commit -q -m c1
) >/dev/null 2>&1
run_check "$out"
assert_fail "追跡 Markdown 0 件" "追跡している Markdown が 1 件もありません"

exit_with_result
