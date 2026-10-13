#!/usr/bin/env bash
# second-opinion-review.sh のモデル名の解決（旧名 GEMINI_REVIEW_MODEL の扱い）を、
# 本物の CLI 無しで確かめる（#544）。
#
# 旧名は gemini 用のモデル名である。エンジンを見ずにフォールバックすると、
# codex / antigravity へ gemini 用のモデル名が渡り、第二意見が実行できなくなる。
# 仕込みの CLI が受け取ったモデル名を記録し、エンジンごとに渡った値を確かめる。
# 回答の判定は問わない（仕込みは失敗してよい）。見るのは引数だけ。
#
# codex は env -i で起動されるため、記録先は仕込みの位置から解決する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-second-opinion-model-fallback"

unset SECOND_OPINION_ENGINE SECOND_OPINION_RUNS SECOND_OPINION_MODEL \
      GEMINI_REVIEW_MODEL GEMINI_REVIEW_RUNS

REVIEW="$REPO_ROOT/scripts/second-opinion-review.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-so-model-fallback.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# このリポジトリ自身の .env に値があると前提が書き換わるため、空の .env に固定する。
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

# 仕込みの CLI。引数を 1 行 1 引数で記録して失敗する。記録先は仕込みの位置から解決する。
for cli in codex gemini agy; do
  cat > "$FAKE_BIN/$cli" <<'FAKE'
#!/usr/bin/env bash
rec="$(cd "$(dirname "$0")/.." && pwd)/record"
name="$(basename "$0")"
if [[ "$name" == "codex" && "${1-}" == "login" ]]; then exit 0; fi
: > "$rec/argv-$name"
for a in "$@"; do printf '%s\n' "$a" >> "$rec/argv-$name"; done
cat > /dev/null
exit 1
FAKE
  chmod +x "$FAKE_BIN/$cli"
done

# 使い方: run_engine <記録を読む CLI 名> <被検査側へ渡す引数...>
# 渡ったモデル名（--model / -m の次の引数。無ければ空）を標準出力へ出す。
run_engine() {
  local cli="$1"; shift
  rm -f "$RECORD"/argv-*
  (
    cd "$REPO" || exit 1
    PATH="$FAKE_BIN:$PATH" GEMINI_API_KEY=dummy \
      bash "$REVIEW" "$@" > "$WORK/out" 2> "$WORK/err"
  ) || true
  awk 'prev=="--model" || prev=="-m" {print; exit} {prev=$0}' "$RECORD/argv-$cli" 2>/dev/null || true
}

it "codex: 旧名だけがあるとき、旧名の値は渡らず既定の gpt-6-sol が渡る（--engine）"
got="$(GEMINI_REVIEW_MODEL=legacy-gemini-model run_engine codex --engine codex)"
assert_eq "$got" "gpt-6-sol" "codex に渡ったモデル"

it "codex: 旧名だけがあるとき、SECOND_OPINION_ENGINE でも旧名の値は渡らない"
got="$(SECOND_OPINION_ENGINE=codex GEMINI_REVIEW_MODEL=legacy-gemini-model run_engine codex)"
assert_eq "$got" "gpt-6-sol" "codex に渡ったモデル"

it "antigravity: 旧名だけがあるとき、旧名の値は渡らずモデルの指定が無い"
got="$(GEMINI_REVIEW_MODEL=legacy-gemini-model run_engine agy --engine antigravity)"
if [[ -f "$RECORD/argv-agy" ]]; then
  assert_eq "$got" "" "agy に渡ったモデル"
else
  fail "agy が呼ばれていない: $(cat "$WORK/err")"
fi

it "gemini: 旧名のモデル名が渡る"
got="$(GEMINI_REVIEW_MODEL=legacy-gemini-model run_engine gemini --engine gemini)"
assert_eq "$got" "legacy-gemini-model" "gemini に渡ったモデル"

it "gemini: 既定のエンジン（指定なし）でも旧名のモデル名が渡る"
got="$(GEMINI_REVIEW_MODEL=legacy-gemini-model run_engine gemini)"
assert_eq "$got" "legacy-gemini-model" "gemini に渡ったモデル"

it "SECOND_OPINION_MODEL があれば、旧名より優先される（gemini）"
got="$(SECOND_OPINION_MODEL=new-model GEMINI_REVIEW_MODEL=legacy-gemini-model run_engine gemini --engine gemini)"
assert_eq "$got" "new-model" "gemini に渡ったモデル"

it "SECOND_OPINION_MODEL があれば、エンジンに依らずそれが渡る（codex）"
got="$(SECOND_OPINION_MODEL=new-model GEMINI_REVIEW_MODEL=legacy-gemini-model run_engine codex --engine codex)"
assert_eq "$got" "new-model" "codex に渡ったモデル"

it "SECOND_OPINION_MODEL があれば、エンジンに依らずそれが渡る（antigravity）"
got="$(SECOND_OPINION_MODEL=new-model GEMINI_REVIEW_MODEL=legacy-gemini-model run_engine agy --engine antigravity)"
assert_eq "$got" "new-model" "agy に渡ったモデル"

it "--model は環境変数に勝つ（codex）"
got="$(SECOND_OPINION_MODEL=new-model GEMINI_REVIEW_MODEL=legacy-gemini-model run_engine codex --engine codex --model cli-model)"
assert_eq "$got" "cli-model" "codex に渡ったモデル"

exit_with_result
