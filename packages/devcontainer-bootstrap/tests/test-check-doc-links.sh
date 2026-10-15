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
  if ! printf '%s' "$CHECK_OUT" | grep 'DOC_LINKS_FAIL' >/dev/null; then
    fail "$what: DOC_LINKS_FAIL が出ていない: $CHECK_OUT"
    return
  fi
  if [[ -n "$needle" ]] && ! printf '%s' "$CHECK_OUT" | grep -F "$needle" >/dev/null; then
    fail "$what: 期待した報告 '$needle' が無い: $CHECK_OUT"
    return
  fi
  pass
}

assert_pass() {
  local what="$1"
  if [[ "$CHECK_RC" -ne 0 ]]; then
    fail "$what: 通るべきところで落ちた: $CHECK_OUT"
  elif ! printf '%s' "$CHECK_OUT" | grep 'DOC_LINKS_PASS' >/dev/null; then
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

# ── 陰性: 長いフェンスの中の短いフェンスでは閉じない（#439） ─────────────────
# 閉じるのは、開きと同じ文字で開き以上の長さを持ち、後ろに空白しか無い行だけ
# （CommonMark）。種類だけで見ると、4 連の中の ``` や ```sh で早く閉じ、続く
# リンクを検査し、最後の 4 連を「閉じていない」と報告していた。

it "4 連のフェンスの中の 3 連（info string あり・なし）では閉じない"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '````markdown
```sh
[nope](missing-after-inner-open.md)
```
[nope](missing-after-inner-close.md)
````
'
commit_repo "$repo" add-nested-fences
run_check "$repo"
assert_pass "長いフェンスの中のリンクは対象外"

it "閉じフェンスに info string が付いた行では閉じない"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '```
```sh
[nope](missing-after-info-close.md)
```
'
commit_repo "$repo" add-info-close
run_check "$repo"
assert_pass "info string 付きの行は閉じフェンスではない"

# ── 陽性（対照群）: 正しく閉じた後のリンクは検査する ────────────────────────

it "長いフェンスを同じ長さ以上で閉じた後のリンクは検査する（陽性、偽の緑にしない）"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '````
```
`````
[broken](missing-after-long-close.md)
'
commit_repo "$repo" add-long-close
run_check "$repo"
assert_fail "閉じた後の壊れたリンク" "missing-after-long-close.md"

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

# ── 括弧を含むリンク先 ───────────────────────────────────────────────────────

it "対になった括弧を含む実在のリンク先は通る"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '[paren](foo(bar).md) と [title](foo(bar).md "T (x)")
'
add_doc "$repo" "docs/foo(bar).md" 'x
'
commit_repo "$repo" add-paren-ok
run_check "$repo"
assert_pass "括弧を含む実在のリンク"

it "対になった括弧を含む実在しないリンク先は、括弧ごと報告して落ちる"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '[paren](gone(bar).md)
'
commit_repo "$repo" add-paren-broken
run_check "$repo"
assert_fail "括弧を含む壊れたリンク" "docs/gone(bar).md"

it "タイトルや <...> の中の対になっていない括弧は数えない（リンクを検査から漏らさない）"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" "[dq](gone.md \"T (\") と [sq](gone2.md 'T (') と [angle](<gone3(.md>)
"
commit_repo "$repo" add-unbalanced-title
run_check "$repo"
assert_fail "タイトル中の ( で漏れない（二重引用符）" "docs/gone.md"
assert_fail "タイトル中の ( で漏れない（一重引用符）" "docs/gone2.md"
assert_fail "<...> 中の ( で漏れない" "docs/gone3(.md"

it "エスケープした引用符や、対応の取れない括弧でもリンクを検査から漏らさない"
# 対応する ) が見つからないときは、従来どおり最初の ) で切る（変更前より漏らさない）。
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '[esc](gone.md "T \" (") と [open](gone4(.md)
'
commit_repo "$repo" add-escaped-title
run_check "$repo"
assert_fail "エスケープした引用符の後の ( で漏れない" "docs/gone.md"
assert_fail "対応の取れない ( は従来どおり最初の ) で切る" "docs/gone4(.md"

it "閉じていない括弧の後ろに続くリンクも検査する"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '[a](foo(bar) [b](gone5.md) ) と [c](#frag(x) [d](gone6.md) )
'
commit_repo "$repo" add-unclosed-then-link
run_check "$repo"
assert_fail "閉じていない ( の後ろのリンク" "docs/gone5.md"
assert_fail "閉じていない ( の後ろのリンク（フラグメント）" "docs/gone6.md"

# ── 作業ツリーで消した（未ステージの）追跡済み Markdown ─────────────────────

it "追跡済みの Markdown を消しても（未ステージ）通過し、集計に実体なしの件数が出る"
repo="$(new_repo)"
add_doc "$repo" "docs/keep.md" '[ok](other.md)
'
add_doc "$repo" "docs/other.md" 'x
'
add_doc "$repo" "docs/del.md" '[gone](nowhere.md)
'
commit_repo "$repo" add-docs-for-delete
rm "$repo/docs/del.md"
run_check "$repo"
if [[ "$CHECK_RC" -eq 0 ]] && printf '%s' "$CHECK_OUT" | grep 'DOC_LINKS_PASS' >/dev/null; then
  pass
else
  fail "消した Markdown で止まった: $CHECK_OUT"
fi
if printf '%s' "$CHECK_OUT" | grep -F '実体なし 1 件' >/dev/null; then
  pass
else
  fail "集計の行に実体なし 1 件が無い: $CHECK_OUT"
fi

it "消した文書へのリンクは壊れたリンクとして落ちる"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '[b](b.md)
'
add_doc "$repo" "docs/b.md" 'x
'
commit_repo "$repo" add-a-b
rm "$repo/docs/b.md"
run_check "$repo"
assert_fail "消した文書へのリンク" "docs/b.md"

it "消した追跡ファイルへのリンクの診断は、綴りの誤りではなく消したことを示す"
assert_fail "消した文書への診断の文言" "作業ツリーで消した追跡ファイル"

it "skip-worktree で実体の無い追跡ファイルへのリンクは通過する"
repo="$(new_repo)"
add_doc "$repo" "docs/a.md" '[b](b.md)
'
add_doc "$repo" "docs/b.md" 'x
'
commit_repo "$repo" add-a-b-skip
( cd "$repo" && git update-index --skip-worktree docs/b.md && rm docs/b.md ) >/dev/null 2>&1
run_check "$repo"
if [[ "$CHECK_RC" -eq 0 ]] && printf '%s' "$CHECK_OUT" | grep 'DOC_LINKS_PASS' >/dev/null; then
  pass
else
  fail "skip-worktree のファイルを消したものとして扱った: $CHECK_OUT"
fi

it "作業ツリーに置いていない追跡 md の走査を飛ばしたことを、件数で報告する"
if printf '%s' "$CHECK_OUT" | grep '作業ツリーに置いていない 1 件' >/dev/null; then
  pass
else
  fail "飛ばした件数が集計に出ていない: $CHECK_OUT"
fi

it "改行を含む名前のファイルを消しても、実在する別のパスを消したものと取り違えない"
# 消したファイルの名前の各行（docs/e / docs/foo.md / z.md）が、実在する docs/foo.md に
# 一致しないこと。取り違えると docs/foo.md の走査が飛ばされ、壊れたリンクを見逃す。
repo="$(new_repo)"
add_doc "$repo" "docs/foo.md" '[x](missing.md)
'
add_doc "$repo" $'docs/e\ndocs/foo.md\nz.md' 'y
'
commit_repo "$repo" add-newline-name
( cd "$repo" && rm -- $'docs/e\ndocs/foo.md\nz.md' ) >/dev/null 2>&1
run_check "$repo"
if [[ "$CHECK_RC" -ne 0 ]] && printf '%s' "$CHECK_OUT" | grep 'DOC_LINKS_FAIL' >/dev/null \
   && printf '%s' "$CHECK_OUT" | grep 'missing.md' >/dev/null; then
  pass
else
  fail "docs/foo.md の壊れたリンクを見逃した（消したものと取り違えた）: $CHECK_OUT"
fi

it "壊れたシンボリックリンクの追跡 Markdown は従来どおり落ちる"
repo="$(new_repo)"
mkdir -p "$repo/docs"
ln -s no-such-target.md "$repo/docs/link.md"
( cd "$repo" && git add -A && $GIT_AS commit -q -m add-broken-symlink ) >/dev/null 2>&1
run_check "$repo"
assert_fail "壊れたシンボリックリンク"

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
