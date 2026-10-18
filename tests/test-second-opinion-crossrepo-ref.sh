#!/usr/bin/env bash
# second-opinion-review.sh が参照の文脈に添える「別のリポジトリの番号の取り違え」への
# 断りを、配布の正本（.ai-playbook/templates/）と写し（scripts/）の両方で確かめる（#660）。
#
# 本物の CLI も GitHub も使わない。コミットメッセージに素の #53 を書き、仕込みの gh が
# その番号を引けることにして、仕込みの gemini へ渡った PROMPT を確かめる。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-second-opinion-crossrepo-ref"

unset SECOND_OPINION_ENGINE SECOND_OPINION_RUNS SECOND_OPINION_MODEL \
      GEMINI_REVIEW_MODEL GEMINI_REVIEW_RUNS

# 被検査スクリプトの resolve_referenced_context が jq で author_association を読む。
# 無いと参照がすべて「引けない」扱いになり、原因の分からない失敗になるので先に止める。
if ! command -v jq >/dev/null 2>&1; then
  it "前提: jq がある"
  fail "jq がありません（被検査スクリプトが参照の文脈を読むのに使う）"
  exit_with_result
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-so-crossrepo.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# このリポジトリ自身の .env に値があると前提が書き換わるため、空の .env に固定する。
export PROJECT_ENV_FILE="$WORK/empty.env"
: > "$PROJECT_ENV_FILE"

FAKE_BIN="$WORK/bin"
REPO="$WORK/repo"
mkdir -p "$FAKE_BIN" "$REPO"

git -C "$REPO" init -q
git -C "$REPO" config user.email "selftest@example.invalid"
git -C "$REPO" config user.name "selftest"
printf 'hello\n' > "$REPO/sample.txt"
git -C "$REPO" add sample.txt
git -C "$REPO" commit -q -m base
printf 'hello\nworld\n' > "$REPO/sample.txt"
git -C "$REPO" commit -q -am "feat: 別のリポジトリ contract-review PR #53 の対応" -m "本文"

# 仕込みの gh: どの番号も、書き込み権を持つ人の PR として返す。
cat > "$FAKE_BIN/gh" <<'FAKE'
#!/usr/bin/env bash
printf '%s' '{"title":"unrelated-title","state":"open","author_association":"OWNER","pull_request":{"merged_at":null},"body":""}'
FAKE
# 仕込みの gemini: 引数（-p のプロンプトを含む）を記録して失敗する。
cat > "$FAKE_BIN/gemini" <<'FAKE'
#!/usr/bin/env bash
rec="$(cd "$(dirname "$0")/.." && pwd)/argv"
: > "$rec"
for a in "$@"; do printf '%s\n' "$a" >> "$rec"; done
cat > /dev/null
exit 1
FAKE
chmod +x "$FAKE_BIN/gh" "$FAKE_BIN/gemini"

# 断りの文面（改行を除いた PROMPT に対して固定文字列で探す）。
NOTE1="本文で別のリポジトリを指した番号が、このリポジトリの同じ番号の別物として"
NOTE2="報告は省かず、別のリポジトリの番号か、番号の書き誤りのどちらかであることを添えてください"

# 使い方: check_script <表示名> <被検査スクリプト>
check_script() {
  local label="$1" script="$2" prompt
  rm -f "$WORK/argv"
  (
    cd "$REPO" || exit 1
    PATH="$FAKE_BIN:$PATH" GEMINI_API_KEY=dummy \
      bash "$script" --engine gemini --range HEAD~1..HEAD > "$WORK/out" 2> "$WORK/err"
  ) || true
  prompt="$(tr -d '\n' < "$WORK/argv" 2>/dev/null || true)"

  it "$label: 参照の文脈が PROMPT に載る"
  if grep -qF "unrelated-title" <<< "$prompt"; then pass "引いた参照が PROMPT にある"; else fail "参照の文脈が PROMPT に無い: $(head -c 300 "$WORK/err")"; fi

  it "$label: 別のリポジトリの番号の取り違えへの断りが PROMPT にある"
  if grep -qF "$NOTE1" <<< "$prompt" && grep -qF "$NOTE2" <<< "$prompt"; then pass "断りがある"; else fail "断りが PROMPT に無い"; fi
}

check_script "配布の正本" "$REPO_ROOT/.ai-playbook/templates/second-opinion-review.sh"
check_script "このリポジトリの写し" "$REPO_ROOT/scripts/second-opinion-review.sh"

exit_with_result
