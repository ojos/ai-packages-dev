#!/usr/bin/env bash
# second-opinion-review.sh の gemini エンジンの配線を、本物の CLI 無しで確かめる。
#
# ## なぜ要るのか
#
# gemini だけが「出力の最後の行の判定トークン」方式を保つ（構造化出力を強制する
# 旗が無いため）。issue / PR の文脈を注入する機能を足したことで、この従来方式が
# 壊れていないこと（差分がまだ @ 参照で渡ること、判定トークンの解析がまだ効くこと）
# を確かめる。この環境には gemini CLI が無いため、仕込みで代替する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-second-opinion-gemini"

unset SECOND_OPINION_ENGINE SECOND_OPINION_RUNS SECOND_OPINION_MODEL

REVIEW="$REPO_ROOT/scripts/second-opinion-review.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-second-opinion-gemini.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# 実行元リポジトリ（またはこの worktree のメインの作業コピー）の .env に
# SECOND_OPINION_* / GEMINI_API_KEY が書かれていると、load-project-env.sh が
# ホスト env より優先してそれを読み、この検査の前提（既定値・鍵の有無）を黙って
# 書き換える。空の .env を明示して固定し、検査を環境から独立させる。
export PROJECT_ENV_FILE="$WORK/empty.env"
: > "$PROJECT_ENV_FILE"

FAKE_BIN="$WORK/bin"
RECORD="$WORK/record"
REPO="$WORK/repo"
mkdir -p "$FAKE_BIN" "$RECORD" "$REPO"

git -C "$REPO" init -q
git -C "$REPO" config user.email "selftest@example.invalid"
git -C "$REPO" config user.name "selftest"
printf 'hello\n' > "$REPO/sample.txt"
git -C "$REPO" add sample.txt
git -C "$REPO" commit -q -m base
printf 'hello\nworld\n' > "$REPO/sample.txt"
git -C "$REPO" add sample.txt

cat > "$FAKE_BIN/gemini" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
: > "$FAKE_GEMINI_RECORD/argv"
for a in "$@"; do
  printf '%s\n' "$a" >> "$FAKE_GEMINI_RECORD/argv"
done
printf '%s\n' "${FAKE_GEMINI_ANSWER:-VERDICT: LGTM}"
FAKE
chmod +x "$FAKE_BIN/gemini"

run_review() {
  local rc
  (
    cd "$REPO" || exit 1
    PATH="$FAKE_BIN:$PATH" \
    GEMINI_API_KEY="dummy-for-selftest" \
    FAKE_GEMINI_RECORD="$RECORD" \
      bash "$REVIEW" --engine gemini "$@" \
        > "$WORK/out" 2> "$WORK/err"
  )
  rc=$?
  cat "$WORK/out" "$WORK/err" > "$WORK/both" 2>/dev/null || true
  return "$rc"
}

it "VERDICT: LGTM の回答で exit 0 になる"
rm -f "$RECORD/argv"
rc=0
FAKE_GEMINI_ANSWER='VERDICT: LGTM' run_review || rc=$?
if [[ "$rc" -eq 0 ]]; then pass; else fail "exit $rc: $(cat "$WORK/err")"; fi

it "LGTM の回では loop-gate.sh が記録の契機にする完了行が出る"
if grep -qE '^\[second-opinion\] LGTM \(' "$WORK/both" 2>/dev/null; then
  pass
else
  fail "完了行が出ていない: $(cat "$WORK/both")"
fi

it "VERDICT: FINDINGS の回では findings reported by で始まる完了行が出る"
rc=0
FAKE_GEMINI_ANSWER='VERDICT: FINDINGS' run_review || rc=$?
if [[ "$rc" -eq 1 ]] && grep -qE '^\[second-opinion\] findings reported by ' "$WORK/both" 2>/dev/null; then
  pass
else
  fail "exit=$rc, 完了行: $(cat "$WORK/both")"
fi

it "引数は @<パス> 参照で、差分を直接引数へ埋め込んでいない"
argv="$(cat "$RECORD/argv" 2>/dev/null || true)"
if printf '%s\n' "$argv" | grep '^@' >/dev/null; then
  pass
else
  fail "@ 参照が見つからない: $argv"
fi

it "プロンプトに判定トークンの指示（VERDICT: LGTM）が残っている（JSON スキーマ方式へ変わっていない）"
if printf '%s\n' "$argv" | grep 'VERDICT: LGTM' >/dev/null; then
  pass
else
  fail "判定トークンの指示が無い"
fi

it "プロンプトが反証の立場と失敗の筋書きを求めている"
if printf '%s\n' "$argv" | grep -F '反証しにいく' >/dev/null \
  && printf '%s\n' "$argv" | grep -F '失敗の筋書き' >/dev/null \
  && printf '%s\n' "$argv" | grep -F '具体的に書けない懸念は、指摘に数えないでください' >/dev/null; then
  pass
else
  fail "反証の立場、失敗の筋書きの要求、または書けない懸念を参考として残す指示が依頼文に無い"
fi

it "枝の名前から issue 番号を取れない場合は、文脈なしで続行する（レビュー自体は落とさない）"
# gh を PATH から外すのは codex のテストと同じ理由で割に合わないため、gh 不在相当
# （常に失敗する仕込み）で代替する。
failing_gh_bin="$WORK/failing-gh"
mkdir -p "$failing_gh_bin"
cat > "$failing_gh_bin/gh" <<'FAILGH'
#!/usr/bin/env bash
exit 1
FAILGH
chmod +x "$failing_gh_bin/gh"
rc=0
(
  cd "$REPO"
  PATH="$failing_gh_bin:$FAKE_BIN:$PATH" \
  GEMINI_API_KEY="dummy-for-selftest" \
  FAKE_GEMINI_RECORD="$RECORD" \
  FAKE_GEMINI_ANSWER='VERDICT: LGTM' \
    bash "$REVIEW" --engine gemini > "$WORK/out" 2> "$WORK/err"
) || rc=$?
assert_eq "$rc" "0" "exit code"

it "issue 番号を含む枝で gh が失敗しても、文脈なしで続行する（レビュー自体は落とさない）"
# 上の検査は番号の無い枝なので gh が呼ばれない。こちらは番号付きの枝で回し、
# 仕込んだ失敗する gh が実際に呼ばれたうえで続行することを確かめる。
git -C "$REPO" checkout -q -b feat/77-gh-fails
printf 'gh fails\n' > "$REPO/gh-fails.txt"
git -C "$REPO" add gh-fails.txt
rc=0
(
  cd "$REPO"
  PATH="$failing_gh_bin:$FAKE_BIN:$PATH" \
  GEMINI_API_KEY="dummy-for-selftest" \
  FAKE_GEMINI_RECORD="$RECORD" \
  FAKE_GEMINI_ANSWER='VERDICT: LGTM' \
    bash "$REVIEW" --engine gemini > "$WORK/out" 2> "$WORK/err"
) || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'issue #77 を引けませんでした（文脈なしでレビューします）' "$WORK/err"; then
  pass
else
  fail "gh 失敗時の続行を確かめられない: exit=$rc, err: $(cat "$WORK/err")"
fi
git -C "$REPO" checkout -q -

# 枝の名前の形ごとに、issue 番号を取って文脈つきでレビューする（#593）。
# フックと同じ規則なので、123-x / issue-123 / gh-123_x も読む。番号の無い名前は読まない。
ok_gh_bin="$WORK/ok-gh"
mkdir -p "$ok_gh_bin"
cat > "$ok_gh_bin/gh" <<'OKGH'
#!/usr/bin/env bash
printf '# issue stub\n'
OKGH
chmod +x "$ok_gh_bin/gh"

review_on_branch() { # 枝名
  local b="$1" rc=0
  # 枝を作れなければ、前の枝のままレビューして誤った結果になるので、ここで失敗にする。
  git -C "$REPO" checkout -q -b "$b" || return 99
  printf '%s\n' "$b" > "$REPO/branch-form.txt"
  git -C "$REPO" add branch-form.txt
  (
    cd "$REPO"
    PATH="$ok_gh_bin:$FAKE_BIN:$PATH" \
    GEMINI_API_KEY="dummy-for-selftest" \
    FAKE_GEMINI_RECORD="$RECORD" \
    FAKE_GEMINI_ANSWER='VERDICT: LGTM' \
      bash "$REVIEW" --engine gemini > "$WORK/out" 2> "$WORK/err"
  ) || rc=$?
  git -C "$REPO" reset -q
  rm -f "$REPO/branch-form.txt"
  git -C "$REPO" checkout -q -
  git -C "$REPO" branch -q -D "$b"
  return "$rc"
}

for form in "123-x" "issue-123" "gh-123_x" "feat/123-x"; do
  it "枝 '$form' から issue #123 を取り、文脈つきでレビューする"
  rc=0
  review_on_branch "$form" || rc=$?
  if [[ "$rc" -eq 0 ]] && grep -q 'issue #123 の scope と acceptance を文脈に載せます' "$WORK/out"; then
    pass
  else
    fail "exit=$rc, out: $(cat "$WORK/out"), err: $(cat "$WORK/err")"
  fi
done

it "番号の無い枝では番号を取れず、読める形を示して文脈なしで続行する"
rc=0
review_on_branch "no-number-here" || rc=$?
if [[ "$rc" -eq 0 ]] \
  && grep -q '枝の名前から issue 番号を取れませんでした' "$WORK/err" \
  && grep -q 'issue-123' "$WORK/err" \
  && ! grep -q 'を文脈に載せます' "$WORK/out"; then
  pass
else
  fail "exit=$rc, out: $(cat "$WORK/out"), err: $(cat "$WORK/err")"
fi

# ── --base <rev>: 索引と <rev> の差を対象にする（#563） ──────────────────────
#
# 差分の外を読めないエンジンへ、修正分だけの小さな差分を渡すと、前提を誤って落ちる。
# PR 全体（起点から索引まで）を渡せるように、--base を持つ。コミット済みの分と
# ステージ済みの分の両方が入ることを、エンジンへ渡った差分の中身で確かめる。
BASE_REPO="$WORK/base-repo"
mkdir -p "$BASE_REPO" "$WORK/bin2"
git -C "$BASE_REPO" init -q
git -C "$BASE_REPO" config user.email "selftest@example.invalid"
git -C "$BASE_REPO" config user.name "selftest"
printf 'a\n' > "$BASE_REPO/a.txt"
git -C "$BASE_REPO" add a.txt
git -C "$BASE_REPO" commit -q -m a
BASE_REV="$(git -C "$BASE_REPO" rev-parse HEAD)"
printf 'committed\n' > "$BASE_REPO/committed.txt"
git -C "$BASE_REPO" add committed.txt
git -C "$BASE_REPO" commit -q -m b
printf 'staged\n' > "$BASE_REPO/staged.txt"
git -C "$BASE_REPO" add staged.txt

# @<パス> で渡る差分の中身を保存する gemini。
cat > "$WORK/bin2/gemini" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
for a in "$@"; do
  case "$a" in
    @*)
      # 引数は「@<パス>」の後ろにプロンプトが続く。先頭の行がパス。
      p="${a#@}"; p="${p%%$'\n'*}"
      cat "$p" > "$FAKE_GEMINI_RECORD/diff"
      ;;
  esac
done
echo 'VERDICT: LGTM'
FAKE
chmod +x "$WORK/bin2/gemini"

run_base_review() {
  (
    cd "$BASE_REPO" || exit 1
    PATH="$WORK/bin2:$PATH" GEMINI_API_KEY="dummy-for-selftest" FAKE_GEMINI_RECORD="$RECORD" \
      bash "$REVIEW" --engine gemini "$@" > "$WORK/out" 2> "$WORK/err"
  )
}

it "--base <rev> は、コミット済みの変更とステージ済みの変更の両方を対象にする"
rm -f "$RECORD/diff"
rc=0
run_base_review --base "$BASE_REV" || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'committed.txt' "$RECORD/diff" && grep -q 'staged.txt' "$RECORD/diff"; then
  pass
else
  fail "両方が差分に入っていない (rc=$rc): $(cat "$RECORD/diff" 2>/dev/null)"
fi

it "--base <rev> は、<rev> より前の変更を対象にしない"
if grep -q '^+++ b/a.txt' "$RECORD/diff"; then fail "起点より前の a.txt が入っている"; else pass; fi

it "--base を使わない既定は、従来どおりステージ済み差分だけを対象にする"
rm -f "$RECORD/diff"
rc=0
run_base_review || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'staged.txt' "$RECORD/diff" && ! grep -q 'committed.txt' "$RECORD/diff"; then
  pass
else
  fail "既定の対象が変わっている (rc=$rc): $(cat "$RECORD/diff" 2>/dev/null)"
fi

it "--base の対象は出力の scope に現れる"
run_base_review --base "$BASE_REV" || true
if grep -q "base:$BASE_REV+staged" "$WORK/out"; then pass; else fail "scope が出ていない: $(cat "$WORK/out")"; fi

it "--base と --range は併用できない"
rc=0
run_base_review --base "$BASE_REV" --range "$BASE_REV..HEAD" || rc=$?
if [[ "$rc" -ne 0 ]] && grep -q '併用できません' "$WORK/err"; then pass; else fail "併用が通った (rc=$rc): $(cat "$WORK/err")"; fi

it "--base に値が無ければ使い方を示して落ちる"
rc=0
run_base_review --base || rc=$?
if [[ "$rc" -ne 0 ]] && grep -q -- '--base には値が必要です' "$WORK/err"; then pass; else fail "(rc=$rc): $(cat "$WORK/err")"; fi

it "--base <rev> と索引の差が無ければ「対象なし」で 0 になる"
rc=0
git -C "$BASE_REPO" reset -q --hard HEAD
run_base_review --base HEAD || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'no diff to review' "$WORK/out"; then pass; else fail "(rc=$rc): $(cat "$WORK/out")"; fi

exit_with_result
