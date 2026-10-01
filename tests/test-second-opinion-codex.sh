#!/usr/bin/env bash
# second-opinion-review.sh の codex エンジンの配線を、本物の CLI 無しで確かめる。
#
# ## なぜ要るのか
#
# --engine codex の配線は、失敗しても緑に見える形で壊れうる。壊れ方は 2 通りある。
#
#   1. 差分がモデルへ届かない。codex は `exec -` で指示文を標準入力から読む。
#      並びを間違えて「プロンプトが先・差分が後」にすると、プロンプト冒頭の
#      「上記は git の差分です」が指す先が無くなり、モデルは差分を見ないまま
#      「差分が空だ」と答えうる。これは LGTM として通る（antigravity の実装で
#      実際に踏んだ形と同種）。
#   2. 判定が回答以外の文字列で行われる。codex の回答は -o のファイルから取る。
#      stdout を読む実装へ戻ると、見出しや進捗が判定へ混ざる。
#
# どちらも本物の CLI を呼ばずに確かめられる。仕込みの codex を PATH の先へ置き、
# 受け取った標準入力と引数を記録させる。
#
# ## 仕込みは「本物がしないこと」をしない
#
# 仕込みの codex は、second-opinion-review.sh の実装コメントに書かれた実測仕様
# （`codex login status` の終了コードで有無を返す／回答は -o へ書く／失敗回は
# -o を作らない）だけを真似る。回答を stdout へは書かせない。書かせると、-o を
# 読まない実装でも通ってしまい、この検査が塞ぎたい壊れ方（2）をそのまま隠す。
#
# この環境には codex CLI が無いため、仕込みで代替する（非対話・ネットワーク不要）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-second-opinion-codex"

REVIEW="$REPO_ROOT/scripts/second-opinion-review.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-second-opinion-codex.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAKE_BIN="$WORK/bin"
RECORD="$WORK/record"
REPO="$WORK/repo"
mkdir -p "$FAKE_BIN" "$RECORD" "$REPO"

# 検査用の git リポジトリ。second-opinion-review.sh は `git diff <range>` を cwd で
# 解くので、このリポジトリの履歴に依存しない使い捨てを作る。
git -C "$REPO" init -q
git -C "$REPO" config user.email "selftest@example.invalid"
git -C "$REPO" config user.name "selftest"
printf 'hello\n' > "$REPO/sample.txt"
git -C "$REPO" add sample.txt
git -C "$REPO" commit -q -m base
# 差分の中に、渡し方を誤ると壊れる文字を入れる（@ 参照・配列展開・メールアドレス）。
printf 'hello\nnoreply@example.com ${ARR[@]}\n' > "$REPO/sample.txt"
git -C "$REPO" add sample.txt

# 仕込みの codex。上記の表のとおりに振る舞う。環境変数で切り替える
# （本物の codex に無い引数を受け取る仕込みにすると、被検査側が渡す引数の形を
# 検査できなくなる）。
cat > "$FAKE_BIN/codex" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1-}" == "login" && "${2-}" == "status" ]]; then
  if [[ "${FAKE_CODEX_LOGGED_IN:-1}" == "1" ]]; then
    echo "Logged in"
    exit 0
  fi
  echo "Not logged in"
  exit 1
fi

# 呼び出し回数を数える（--runs 2 以上の検査で使う）。
calls=1
if [[ -f "$FAKE_CODEX_RECORD/calls" ]]; then
  calls=$(( $(cat "$FAKE_CODEX_RECORD/calls") + 1 ))
fi
printf '%s\n' "$calls" > "$FAKE_CODEX_RECORD/calls"

# 引数をそのまま記録する（1 行 1 引数。空白を含む引数でも壊れない）。
: > "$FAKE_CODEX_RECORD/argv"
for a in "$@"; do
  printf '%s\n' "$a" >> "$FAKE_CODEX_RECORD/argv"
done

# 受け取った標準入力を記録する。
cat > "$FAKE_CODEX_RECORD/stdin"

# 本物は見出しと受け取ったプロンプトの復唱を stderr へ出す。
echo "codex (fake) / model: ${FAKE_CODEX_MODEL_ECHO:-unknown}" >&2

# -o の位置を引数から拾う。
answer=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then
    answer="$a"
  fi
  prev="$a"
done

if [[ "${FAKE_CODEX_WRITE_ANSWER:-1}" == "0" ]]; then
  # 0 で終わりながら回答を書かない経路（被検査側が気づくべき形）。
  exit 0
fi

if [[ "${FAKE_CODEX_WRITE_ANSWER:-1}" == "first" && "$calls" -gt 1 ]]; then
  # 1 回目だけ回答を書く。2 回目以降は 0 で終わりながら書かない
  # （--runs 2 で、前の回の回答が残っていると通ってしまう形）。
  exit 0
fi

if [[ -z "$answer" ]]; then
  echo "fake codex: -o が渡されていません" >&2
  exit 1
fi

printf '%s\n' "${FAKE_CODEX_ANSWER:-VERDICT: LGTM}" > "$answer"

# stdout へは回答を書かない。書くと、-o を読まない実装でもこの検査が通る。
printf '%s\n' "${FAKE_CODEX_STDOUT:-}"
FAKE
chmod +x "$FAKE_BIN/codex"

run_review() {
  # 被検査側を、仕込みを先に見る PATH で走らせる。標準出力と標準エラーを分けて取る。
  rm -f "$RECORD/calls"
  (
    cd "$REPO" || exit 1
    PATH="$FAKE_BIN:$PATH" \
    FAKE_CODEX_RECORD="$RECORD" \
      bash "$REVIEW" --engine codex "$@" \
        > "$WORK/out" 2> "$WORK/err"
  )
}

# ---- 1. 差分が加工されずに、プロンプトより前へ届くこと ----

it "LGTM の回答で exit 0 になる"
rm -f "$RECORD/stdin" "$RECORD/argv"
rc=0
FAKE_CODEX_ANSWER='VERDICT: LGTM' run_review || rc=$?
if [[ "$rc" -eq 0 ]]; then pass; else fail "exit $rc: $(cat "$WORK/err")"; fi

it "codex が標準入力を受け取っている"
if [[ -f "$RECORD/stdin" ]]; then pass; else fail "差分の渡し方が壊れています（stdin が記録されていない）"; fi

it "標準入力の先頭が差分である（プロンプトが先に来ていない）"
if head -n 1 "$RECORD/stdin" 2>/dev/null | grep -q '^diff --git'; then
  pass
else
  fail "先頭が差分でない: $(head -n 1 "$RECORD/stdin" 2>/dev/null)"
fi

it "差分の本文が逐語で届く（@ や配列展開が化けない）"
if grep -q 'noreply@example.com \${ARR\[@\]}' "$RECORD/stdin" 2>/dev/null; then
  pass
else
  fail "差分本文が加工されている"
fi

it "プロンプト本文（判定トークンの指示）が標準入力に含まれる"
if grep -q 'VERDICT: LGTM' "$RECORD/stdin" 2>/dev/null; then
  pass
else
  fail "プロンプト本文が含まれていない"
fi

it "並びは差分が先・プロンプトが後である"
diff_line="$(grep -n '^diff --git' "$RECORD/stdin" 2>/dev/null | head -n 1 | cut -d: -f1)"
prompt_line="$(grep -n '上記は git の差分です' "$RECORD/stdin" 2>/dev/null | head -n 1 | cut -d: -f1)"
if [[ -n "$diff_line" && -n "$prompt_line" && "$diff_line" -lt "$prompt_line" ]]; then
  pass
else
  fail "並びが逆、または抽出できない（差分 ${diff_line:-無し} 行目 / プロンプト ${prompt_line:-無し} 行目）"
fi

# ---- 2. 引数の形（読み取り専用・色なし・回答の口・既定モデル） ----

it "引数に read-only sandbox / color never / -o が含まれる"
argv="$(cat "$RECORD/argv" 2>/dev/null || true)"
missing=""
for needed in exec - --sandbox read-only --color never -o; do
  printf '%s\n' "$argv" | grep -qx -- "$needed" || missing="$missing $needed"
done
if [[ -z "$missing" ]]; then pass; else fail "引数に無いトークン:$missing"; fi

it "既定モデルは gpt-6-sol である"
model_value="$(awk '$0 == "--model" { getline; print; exit }' "$RECORD/argv" 2>/dev/null)"
assert_eq "$model_value" "gpt-6-sol" "既定モデル"

it "--model を渡すとそちらが使われる"
rm -f "$RECORD/argv"
rc=0
FAKE_CODEX_ANSWER='VERDICT: LGTM' run_review --model gpt-6-luna || rc=$?
model_value="$(awk '$0 == "--model" { getline; print; exit }' "$RECORD/argv" 2>/dev/null)"
if [[ "$rc" -eq 0 ]]; then
  assert_eq "$model_value" "gpt-6-luna" "--model の指定"
else
  fail "--model を渡した回で exit $rc"
fi

# ---- 3. 判定は -o のファイルから取ること（stdout では判定しない） ----

it "回答は LGTM・stdout は FINDINGS でも exit 0（stdout で判定していない）"
rc=0
FAKE_CODEX_ANSWER='VERDICT: LGTM' FAKE_CODEX_STDOUT='VERDICT: FINDINGS' run_review || rc=$?
assert_eq "$rc" "0" "exit code"

it "回答は FINDINGS・stdout は LGTM だと exit 1（-o を見落としていない）"
rc=0
FAKE_CODEX_ANSWER='VERDICT: FINDINGS' FAKE_CODEX_STDOUT='VERDICT: LGTM' run_review || rc=$?
assert_eq "$rc" "1" "exit code"

# ---- 4. 未ログインは exec の前に止まること ----

it "未ログインは実行前に止まり、理由が出る"
rc=0
FAKE_CODEX_LOGGED_IN=0 run_review || rc=$?
if [[ "$rc" -eq 0 ]]; then
  fail "未ログインでも通過した"
elif grep -q 'ログインしていません' "$WORK/err"; then
  pass
else
  fail "理由が出ていない: $(cat "$WORK/err")"
fi

# ---- 5. 0 で終わりながら回答を書かない回は、失敗として扱うこと ----

it "回答が無いまま 0 で終わる回は失敗にする"
rc=0
FAKE_CODEX_WRITE_ANSWER=0 run_review || rc=$?
assert_eq "$rc" "1" "exit code"

# ---- 6. --runs 2 で、前の回の回答が使い回されないこと ----

it "--runs 2 で 2 回目が回答を書かなければ、前の回の回答を読まずに失敗する"
rc=0
FAKE_CODEX_WRITE_ANSWER=first FAKE_CODEX_ANSWER='VERDICT: LGTM' run_review --runs 2 || rc=$?
assert_eq "$rc" "1" "exit code"

exit_with_result
