#!/usr/bin/env bash
# 制御文字混入検査（scripts/check-control-chars.sh）を検証する。
#
# 「描画・展開するまで見えない壊れ方」を機械で見る検査であり、検知層としての性質を
# 検査する。陽性（NUL を仕込んだファイルで落ちる）だけでは足りない。陰性（TAB / LF /
# CR しか含まないファイルで通る）を併せて見ないと、「常に落ちるだけの検査」と区別が
# 付かない。
#
# 使い捨てのリポジトリを毎回作るのは、判定対象が git の追跡状態そのものだから。
#
# ネットワークには出ない。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-check-control-chars"

GIT_AS="git -c user.name=T -c user.email=t@example.com"

# 生成物の原本。bootstrap は 1 回だけ回し、以降は複製して使う。
BASE="$(new_workdir)/base"
run_bootstrap "$BASE" >/dev/null 2>&1

it "check-control-chars.sh が常に生成され、実行可能である"
if [[ -f "$BASE/scripts/check-control-chars.sh" ]]; then
  assert_mode "$BASE/scripts/check-control-chars.sh" "755"
else
  fail "生成されていない: $BASE/scripts/check-control-chars.sh"
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

# 検査を実行し、CHECK_OUT / CHECK_RC へ結果を入れる。
CHECK_OUT=""
CHECK_RC=0
run_check() {
  local repo="$1"
  CHECK_OUT="$(cd "$repo" && bash scripts/check-control-chars.sh 2>&1)"
  CHECK_RC=$?
}

assert_fail() {
  local what="$1" needle="${2-}"
  if [[ "$CHECK_RC" -eq 0 ]]; then
    fail "$what: 落ちるべきところで通過した: $CHECK_OUT"
    return
  fi
  if ! printf '%s' "$CHECK_OUT" | grep -q 'CONTROL_CHARS_FAIL'; then
    fail "$what: CONTROL_CHARS_FAIL が出ていない: $CHECK_OUT"
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
  elif ! printf '%s' "$CHECK_OUT" | grep -q 'CONTROL_CHARS_PASS'; then
    fail "$what: CONTROL_CHARS_PASS が出ていない: $CHECK_OUT"
  else
    pass
  fi
}

# ── 陰性の基準線 ─────────────────────────────────────────────────────────────

it "生成物そのままでは CONTROL_CHARS_PASS（陰性の基準線）"
# これが通らないと、以降の陽性はすべて「常に落ちる検査」でも成立してしまう。
repo="$(new_repo)"
run_check "$repo"
assert_pass "制御文字なし"

# ── 陽性: NUL バイトの混入 ───────────────────────────────────────────────────

it "NUL バイトを仕込んだ追跡ファイルを検知する（陽性、非0終了・該当ファイル名を出す）"
repo="$(new_repo)"
printf 'a\000b\n' > "$repo/nul-fixture.txt"
( cd "$repo" && git add -f nul-fixture.txt && $GIT_AS commit -q -m add-nul ) >/dev/null 2>&1
run_check "$repo"
assert_fail "NUL 混入" "nul-fixture.txt"

it "検知の報告が cat -v で可視化されている（生のバイトのまま出さない）"
repo="$(new_repo)"
printf 'a\000b\n' > "$repo/nul-fixture.txt"
( cd "$repo" && git add -f nul-fixture.txt && $GIT_AS commit -q -m add-nul ) >/dev/null 2>&1
run_check "$repo"
assert_contains "$CHECK_OUT" '^@' "cat -v 表記（NUL）"

# ── 陰性（対照群）: TAB / LF / CR しか含まないファイル ───────────────────────

it "TAB / LF / CR しか含まないファイルは通る（対照群）"
repo="$(new_repo)"
printf 'a\tb\r\nc\n' > "$repo/tab-lf-cr.txt"
( cd "$repo" && git add -f tab-lf-cr.txt && $GIT_AS commit -q -m add-tab ) >/dev/null 2>&1
run_check "$repo"
assert_pass "TAB / LF / CR のみ"

# ── 検査が成立していないことを合格にしない ────────────────────────────────────

it "git 管理外では落ちる（検査が成立していない）"
out="$(new_workdir)/p"
cp -R "$BASE" "$out"
run_check "$out"
assert_fail "git 管理外" "git の作業ツリーではありません"

it "追跡ファイルが 1 件も無ければ落ちる"
# 空の出力を「該当なし」と読むと、検査していないのに合格になる。
out="$(new_workdir)/p"
cp -R "$BASE" "$out"
( cd "$out" && git init -q ) >/dev/null 2>&1
run_check "$out"
assert_fail "追跡 0 件" "追跡ファイルが 1 件もありません"

exit_with_result
