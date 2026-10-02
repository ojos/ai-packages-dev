#!/usr/bin/env bash
# Markdown の相対リンク実在検査（scripts/check-doc-links.sh）を検証する。
#
# 判定は git ls-files の集合への所属であって、作業ツリーの有無（test -e）ではない。
# 「追跡済みなら通る／追跡されていなければ壊れたリンクと同じ扱いになる」ことを
# 区別して確かめないと、公開された文書でだけ 404 になる壊れ方を見逃す。
#
# 使い捨てのリポジトリを毎回作るのは、判定対象が git の追跡状態そのものだから。
#
# ネットワークには出ない。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-check-doc-links"

GIT_AS="git -c user.name=T -c user.email=t@example.com"

# 生成物の原本。bootstrap は 1 回だけ回し、以降は複製して使う。
BASE="$(new_workdir)/base"
run_bootstrap "$BASE" >/dev/null 2>&1

it "check-doc-links.sh が常に生成され、実行可能である"
if [[ -f "$BASE/scripts/check-doc-links.sh" ]]; then
  assert_mode "$BASE/scripts/check-doc-links.sh" "755"
else
  fail "生成されていない: $BASE/scripts/check-doc-links.sh"
fi

# 生成物の複製を git リポジトリとして用意し、そのパスを返す。
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

# 生成物の docs/ 配下へ 1 ファイル追加し、git add して返す（コミットは呼び出し側）。
add_doc() {
  local repo="$1" rel="$2" content="$3"
  mkdir -p "$(dirname "$repo/$rel")"
  printf '%s' "$content" > "$repo/$rel"
  (cd "$repo" && git add -A) >/dev/null 2>&1
}

commit_repo() {
  local repo="$1" msg="$2"
  (cd "$repo" && $GIT_AS commit -q -m "$msg") >/dev/null 2>&1
}

# 検査を実行し、CHECK_OUT / CHECK_RC へ結果を入れる。環境変数 EXTRA_ENV を
# 渡したい場合は、呼び出し側が先に export しておく（DOC_LINKS_EXCLUDE 用）。
CHECK_OUT=""
CHECK_RC=0
run_check() {
  local repo="$1"
  CHECK_OUT="$(cd "$repo" && bash scripts/check-doc-links.sh 2>&1)"
  CHECK_RC=$?
}

assert_fail() {
  local what="$1" needle="${2-}"
  if [[ "$CHECK_RC" -eq 0 ]]; then
    fail "$what: 落ちるべきところで通過した: $CHECK_OUT"
    return
  fi
  if ! printf '%s' "$CHECK_OUT" | grep -q 'DOC_LINKS_FAIL'; then
    fail "$what: DOC_LINKS_FAIL が出ていない: $CHECK_OUT"
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
  elif ! printf '%s' "$CHECK_OUT" | grep -q 'DOC_LINKS_PASS'; then
    fail "$what: DOC_LINKS_PASS が出ていない: $CHECK_OUT"
  else
    pass
  fi
}

# ── 陰性の基準線 ─────────────────────────────────────────────────────────────

it "生成物そのままでは DOC_LINKS_PASS（陰性の基準線）"
# これが通らないと、以降の陽性はすべて「常に落ちる検査」でも成立してしまう。
repo="$(new_repo)"
run_check "$repo"
assert_pass "生成物そのまま"

# ── 陽性: 壊れたリンク ───────────────────────────────────────────────────────

it "存在しない行き先へのリンクを検知する（陽性、該当ファイルと行き先を出す）"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '[broken](missing.md)
'
commit_repo "$repo" add-broken
run_check "$repo"
assert_fail "壊れたリンク" "missing.md"

# ── 陽性: 追跡されていないファイルへのリンク（test -e では見つかるが git には無い） ──

it "作業ツリーにはあるが追跡されていないファイルへのリンクを検知する（陽性）"
repo="$(new_repo)"
mkdir -p "$repo/docs"
printf '[ignored](ignored.md)\n' > "$repo/docs/a.md"
printf 'x\n' > "$repo/docs/ignored.md"
(cd "$repo" && git add docs/a.md) >/dev/null 2>&1
commit_repo "$repo" add-untracked-target
run_check "$repo"
assert_fail "追跡されていない行き先" "作業ツリーにはあるが追跡されていない"

# ── 陽性: リポジトリの外へ出るリンク ─────────────────────────────────────────

it "リポジトリの外へ出るリンク（.. で外へ出る）を検知する（陽性）"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '[escape](../../outside.md)
'
commit_repo "$repo" add-escape
run_check "$repo"
assert_fail "リポジトリの外" "リポジトリの外を指す相対リンク"

# ── 陽性: ルート絶対のリンク ─────────────────────────────────────────────────

it "ルート絶対のリンク（先頭が /）を検知する（陽性）"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '[root](/docs/a.md)
'
commit_repo "$repo" add-root-absolute
run_check "$repo"
assert_fail "ルート絶対" "ルート絶対の相対リンク"

# ── 陽性: 閉じていないコードフェンス ──────────────────────────────────────────

it "閉じていないコードフェンスを検知する（陽性、偽の緑にしない）"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '```
[in-open-fence](missing.md)
'
commit_repo "$repo" add-unclosed-fence
run_check "$repo"
assert_fail "閉じていないフェンス" "閉じていないコードフェンス"

# ── 陰性（対照群）: コードフェンス内のリンク表記は拾わない ───────────────────

it "コードフェンス内のリンク表記（3 連バッククォートと ~~~ の両方）は検査しない（対照群）"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '```
[nope](missing-in-bt-fence.md)
```

~~~
[nope](missing-in-tilde-fence.md)
~~~
'
commit_repo "$repo" add-fenced-links
run_check "$repo"
assert_pass "フェンス内のリンクは対象外"

# ── 陰性（対照群）: スキーム付きリンクは相対パスとして扱わない ───────────────

it "スキーム付きリンク（tel: 等）は相対パスとして扱わない（対照群）"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '[call](tel:+810000000000)
[mail](mailto:nobody@example.com)
'
commit_repo "$repo" add-scheme-links
run_check "$repo"
assert_pass "スキーム付きリンクは対象外"

# ── 陰性（対照群）: ディレクトリへのリンクは、祖先として実在すれば通る ───────

it "追跡ファイルの祖先ディレクトリへのリンクは通る（対照群）"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '[dir](../sub/)
'
add_doc "$repo" "sub/README.md" 'x
'
commit_repo "$repo" add-dir-link
run_check "$repo"
assert_pass "祖先ディレクトリへのリンク"

# ── 除外設定（DOC_LINKS_EXCLUDE） ────────────────────────────────────────────

it "DOC_LINKS_EXCLUDE で指定した文書はスキャン対象から外れる"
repo="$(new_repo)"
add_doc "$repo" "vendor/docs/c.md" '[broken](nope.md)
'
commit_repo "$repo" add-vendor-broken
CHECK_OUT="$(cd "$repo" && DOC_LINKS_EXCLUDE="vendor/docs" bash scripts/check-doc-links.sh 2>&1)"
CHECK_RC=$?
assert_pass "除外設定で壊れたリンクをスキャン対象から外す"

it "DOC_LINKS_EXCLUDE が無指定なら、同じ壊れたリンクをふつうに検知する（対照群）"
run_check "$repo"
assert_fail "除外していないときは検知する" "nope.md"

it "DOC_LINKS_EXCLUDE は除外していない文書を素通りさせない（対照群）"
repo="$(new_repo)"
add_doc "$repo" "vendor/docs/c.md" '[broken](nope.md)
'
add_doc "$repo" "docs/a.md" '[also-broken](also-missing.md)
'
commit_repo "$repo" add-two-broken
CHECK_OUT="$(cd "$repo" && DOC_LINKS_EXCLUDE="vendor/docs" bash scripts/check-doc-links.sh 2>&1)"
CHECK_RC=$?
assert_fail "除外対象外の壊れたリンクは検知する" "also-missing.md"

it "DOC_LINKS_EXCLUDE の末尾のスラッシュは畳んで扱う"
repo="$(new_repo)"
add_doc "$repo" "vendor/docs/c.md" '[broken](nope.md)
'
commit_repo "$repo" add-vendor-broken
CHECK_OUT="$(cd "$repo" && DOC_LINKS_EXCLUDE="vendor/docs/" bash scripts/check-doc-links.sh 2>&1)"
CHECK_RC=$?
assert_pass "末尾スラッシュ付きの除外指定"

# ── タイトル付きのリンク ─────────────────────────────────────────────────────

it "タイトル付きのリンク（\"...\" / '...'）はリンク先だけを見る（対照群）"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" "[dq](b.md \"Title\")
[sq](b.md 'Title')
![img](b.md \"alt\")
"
add_doc "$repo" "docs/b.md" 'x
'
commit_repo "$repo" add-titled
run_check "$repo"
assert_pass "タイトル付きのリンク"

it "タイトル付きでも、リンク先が無ければ検知する（陽性）"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '[dq](gone.md "Title")
'
commit_repo "$repo" add-titled-broken
run_check "$repo"
assert_fail "タイトル付きの壊れたリンク" "gone.md"

it "<...> で囲んだリンク先は中身を見る（対照群）"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '[angle](<b.md> "Title")
'
add_doc "$repo" "docs/b.md" 'x
'
commit_repo "$repo" add-angle
run_check "$repo"
assert_pass "<...> で囲んだリンク先"

# ── 検査が成立していないことを合格にしない ────────────────────────────────────

it "git 管理外では落ちる（検査が成立していない）"
out="$(new_workdir)/p"
cp -R "$BASE" "$out"
run_check "$out"
assert_fail "git 管理外" "git の作業ツリーではありません"

it "追跡ファイルが 1 件も無ければ落ちる"
out="$(new_workdir)/p"
cp -R "$BASE" "$out"
( cd "$out" && git init -q ) >/dev/null 2>&1
run_check "$out"
assert_fail "追跡 0 件" "追跡ファイルが 1 件もありません"

exit_with_result
