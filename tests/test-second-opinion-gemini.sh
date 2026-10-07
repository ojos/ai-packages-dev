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

exit_with_result
