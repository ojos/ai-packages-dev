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

# repo 内に 1 本の Markdown を CRLF 改行で追加してコミットする。
#
# sed の置換文字列（RHS）内で \r を CR と解釈させるのは GNU sed の拡張で、
# BSD sed ではリテラルの文字 r になる（scripts/check-table-breaks.sh 自身が
# GNU 拡張に依存しない方針を掲げているのに、それを検証するテスト側だけが
# 依存すると本末転倒）。awk の printf は POSIX の範囲でエスケープを解釈するため
# 移植性の懸念が無い。
add_md_crlf() {
  local repo="$1" name="$2" content="$3"
  printf '%s' "$content" | awk '{ printf "%s\r\n", $0 }' > "$repo/$name"
  ( cd "$repo" && git add -f "$name" && $GIT_AS commit -q -m "add-$name" ) >/dev/null 2>&1
}

# 検査を実行し、CHECK_OUT / CHECK_RC へ結果を入れる。
CHECK_OUT=""
CHECK_RC=0
run_check() {
  local repo="$1"
  shift
  CHECK_OUT="$(cd "$repo" && env "$@" bash scripts/check-table-breaks.sh 2>&1)"
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

# ── 陽性: 段落の直後に空行を挟まず取り残された行 ─────────────────────────────
#
# 表の途中へ段落を差し込むと、多くの場合そのあとに空行を挟まず表の残骸が続く
# （段落自体が改行だけで終わるため）。直前が空行のときしか表の先頭候補にしない
# 判定だと、この形を見落とす（2 段目ゲートの第二意見が実際に指摘した形）。

it "段落の直後に空行を挟まず取り残された行を報告する（空行を挟む形より見落としやすい）"
repo="$(new_repo)"
# 単一引用符内のバッククォートはリテラル表示のためで、展開させない。
# shellcheck disable=SC2016
add_md "$repo" "no-blank-before.md" '| a | b |
|---|---|
| 1 | 2 |

`planner` は当初サブエージェントとして定義していましたが、親担当へ移しました。
ではありません。
| reviewer | 第二意見は別ベンダーのモデルで取ります |

続きの本文。
'
run_check "$repo"
assert_fail "空行なしで取り残された行" "no-blank-before.md"

# ── CRLF 改行の文書 ───────────────────────────────────────────────────────────
#
# scripts/check-control-chars.sh は CR を CRLF という改行の流儀の一部として許容
# している。表の分断検査が CRLF を未処理のまま扱うと、空行・区切り行・閉じフェンスの
# 判定がすべて揃わなくなり、CRLF の文書だけ誤検知する（2 段目ゲートの第二意見が
# 実際に指摘した形）。

it "CRLF 改行の正しい表は誤検知しない（対照群）"
repo="$(new_repo)"
add_md_crlf "$repo" "crlf-valid.md" '# 見出し

| a | b |
|---|---|
| 1 | 2 |
'
run_check "$repo"
assert_pass "CRLF の正しい表"

it "CRLF 改行でも表の分断を検知する（陽性）"
repo="$(new_repo)"
add_md_crlf "$repo" "crlf-broken.md" '| a | b |
|---|---|
| 1 | 2 |

差し込まれた段落。

| 3 | 4 |
| 5 | 6 |
'
run_check "$repo"
assert_fail "CRLF の分断" "crlf-broken.md"

# ── 検査が成立していないことを合格にしない ────────────────────────────────────

it "git 管理外では落ちる（検査が成立していない）"
out="$(new_workdir)/p"
cp -R "$BASE" "$out"
run_check "$out"
assert_fail "git 管理外" "git の作業ツリーではありません"

it "追跡している Markdown が 1 件も無くても合格として扱う（配布直後のプロジェクトを想定）"
# bootstrap の既定構成（--with-playbook なし）は Markdown を 1 本も生成しない。
# 「表が無い」ことと「表が崩れていない」ことは両立するため、これを不合格にしない
# （表の途中へ段落が差し込まれた文書を検知する検査自体は上の陽性テストが担保する）。
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
assert_pass "追跡 Markdown 0 件"

it "git ls-files が失敗すると落ちる（プロセス置換越しでも検査が成立していないことを合格にしない）"
# git ls-files -z '*.md' '*.markdown' だけを横取りする git スタブを PATH の先頭へ置く
# （2 段目ゲートの第二意見が指摘した形: プロセス置換 `done < <(git ls-files ...)` は
# bash がコマンドの終了コードを呼び出し元へ伝播しないため、一時ファイル経由に
# 直した後でもここで退行しないことを固定する）。
repo="$(new_repo)"
fake_git_dir="$(new_workdir)/fakebin"
mkdir -p "$fake_git_dir"
real_git="$(command -v git)"
cat > "$fake_git_dir/git" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "ls-files" && "\${2:-}" == "-z" ]]; then
  echo "stub: ls-files が失敗しました（permission denied を模す）" >&2
  exit 128
fi
exec "$real_git" "\$@"
STUB
chmod +x "$fake_git_dir/git"
run_check "$repo" "PATH=$fake_git_dir:$PATH"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "落ちるべきところで通過した: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -q 'TABLE_BREAKS_FAIL'; then
  fail "TABLE_BREAKS_FAIL が出ていない: $CHECK_OUT"
elif ! printf '%s' "$CHECK_OUT" | grep -qF 'git ls-files に失敗しました'; then
  fail "既存の fatal 文言が無い: $CHECK_OUT"
else
  pass
fi

exit_with_result
