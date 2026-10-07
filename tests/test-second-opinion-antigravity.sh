#!/usr/bin/env bash
# second-opinion-review.sh の antigravity エンジンの配線を、本物の CLI 無しで確かめる。
#
# ## なぜ要るのか
#
# antigravity は構造化出力を `--json-schema` で強制できるが、**ツールは解禁しない**
# （`--mode plan` が実際には書き込みを止めないことを実測で確認済み。
# second-opinion-review.sh のヘッダコメント「ツールの解禁」参照）。したがって
# codex とは判定方式（JSON）は共通でも、差分の渡し方（プロンプトへ埋め込み、
# 分割の対象）は gemini 側に近い。この 2 点を取り違えると、次のように壊れる。
#
#   1. --output-format json を忘れる。agy は `--json-schema` だけでは
#      「--output-format が json/stream-json のときしか使えない」と拒否するため、
#      見た目は失敗するが原因が読み取りにくい。
#   2. 回答の包みを取り違える。agy の構造化出力は `.structured_output` に入る。
#      stdout 全体を JSON として読もうとすると、包みのキー（`status` 等）が
#      混ざって検証に失敗する。
#   3. ツールを解禁してしまう。`--mode plan` 等を渡すと、レビュー対象の作業ツリーを
#      レビュアー自身が書き換えられる可能性が生まれる。
#
# この環境には agy CLI が無いため、仕込みで代替する（非対話・ネットワーク不要）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-second-opinion-antigravity"

unset SECOND_OPINION_ENGINE SECOND_OPINION_RUNS SECOND_OPINION_MODEL

REVIEW="$REPO_ROOT/scripts/second-opinion-review.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-second-opinion-antigravity.XXXXXX")"
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

# 仕込みの agy。本物は構造化出力を包みで返し、回答は `.structured_output` に入る
# （second-opinion-review.sh のコメントに記載の実測仕様）。
cat > "$FAKE_BIN/agy" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

: > "$FAKE_AGY_RECORD/argv"
for a in "$@"; do
  printf '%s\n' "$a" >> "$FAKE_AGY_RECORD/argv"
done

if [[ "${FAKE_AGY_EMPTY:-0}" == "1" ]]; then
  echo "fake agy: tool permission denied, no response" >&2
  exit 0
fi

printf '{"conversation_id":"x","status":"SUCCESS","response":"...","structured_output":%s}\n' \
  "${FAKE_AGY_ANSWER:-{\"reviewed\":true,\"findings\":[]\}}"
FAKE
chmod +x "$FAKE_BIN/agy"

run_review() {
  local rc
  (
    cd "$REPO" || exit 1
    PATH="$FAKE_BIN:$PATH" \
    FAKE_AGY_RECORD="$RECORD" \
      bash "$REVIEW" --engine antigravity "$@" \
        > "$WORK/out" 2> "$WORK/err"
  )
  rc=$?
  cat "$WORK/out" "$WORK/err" > "$WORK/both" 2>/dev/null || true
  return "$rc"
}

# ---- 1. 差分は従来どおりプロンプトへ埋め込む（ツールは使わせない） ----

it "指摘なしの回答で exit 0 になる"
rm -f "$RECORD/argv"
rc=0
FAKE_AGY_ANSWER='{"reviewed":true,"findings":[]}' run_review || rc=$?
if [[ "$rc" -eq 0 ]]; then pass; else fail "exit $rc: $(cat "$WORK/err")"; fi

it "指摘なしの回では loop-gate.sh が記録の契機にする完了行が出る"
# scripts/loop-gate.sh の record_second_opinion の完了行の正規表現
# （`^\[second-opinion\] LGTM \(`）が、antigravity でも維持されていることを確かめる。
if grep -qE '^\[second-opinion\] LGTM \(' "$WORK/both" 2>/dev/null; then
  pass
else
  fail "完了行が出ていない: $(cat "$WORK/both")"
fi

it "落とす指摘（bug）の回では findings reported by で始まる完了行が出る"
rc=0
FAKE_AGY_ANSWER='{"reviewed":true,"findings":[{"category":"bug","file":"a.ts","line":1,"what":"x","why":"y"}]}' \
  run_review || rc=$?
if [[ "$rc" -eq 1 ]] && grep -qE '^\[second-opinion\] findings reported by ' "$WORK/both" 2>/dev/null; then
  pass
else
  fail "exit=$rc, 完了行: $(cat "$WORK/both")"
fi

it "agy の引数に差分が埋め込まれている（引数に逐語で現れる）"
if grep -qF 'world' "$RECORD/argv" 2>/dev/null; then
  pass
else
  fail "差分の本文が引数に見つからない"
fi

it "ツールを解禁する旗（--mode / --dangerously-skip-permissions 等）を渡していない"
if grep -qE '^(--mode|--dangerously-skip-permissions|--sandbox)$' "$RECORD/argv" 2>/dev/null; then
  fail "ツール解禁に使う旗が渡っている: $(cat "$RECORD/argv")"
else
  pass
fi

# ---- 2. 構造化出力の強制（--output-format json --json-schema） ----

it "引数に --output-format json と --json-schema が含まれ、スキーマが実在する"
argv="$(cat "$RECORD/argv" 2>/dev/null || true)"
missing=""
printf '%s\n' "$argv" | grep -x -- "--output-format" >/dev/null || missing="$missing --output-format"
printf '%s\n' "$argv" | grep -x -- "json" >/dev/null || missing="$missing json"
printf '%s\n' "$argv" | grep -x -- "--json-schema" >/dev/null || missing="$missing --json-schema"
schema_arg="$(awk '$0 == "--json-schema" { getline; print; exit }' "$RECORD/argv" 2>/dev/null)"
if [[ -z "$missing" ]] && [[ -n "$schema_arg" && -f "$schema_arg" ]] && jq empty "$schema_arg" >/dev/null 2>&1; then
  pass
else
  fail "引数に無いトークン:$missing / スキーマ: ${schema_arg:-（無し）}"
fi

# ---- 3. 判定は回答の包みの .structured_output から取ること ----

it "落とさない category（promise-mismatch）だけでは通過する"
rc=0
FAKE_AGY_ANSWER='{"reviewed":true,"findings":[{"category":"promise-mismatch","file":"a.ts","line":1,"what":"x","why":"y"}]}' \
  run_review || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'promise-mismatch' "$WORK/out"; then
  pass
else
  fail "exit=$rc（0 を期待）、または出力に出ていない"
fi

for category in bug vulnerability type-error edge-case; do
  it "category=$category は落とす"
  rc=0
  FAKE_AGY_ANSWER="{\"reviewed\":true,\"findings\":[{\"category\":\"$category\",\"file\":\"a.ts\",\"line\":1,\"what\":\"x\",\"why\":\"y\"}]}" \
    run_review || rc=$?
  assert_eq "$rc" "1" "exit code"
done

it "包みの外（status 等）を JSON として読もうとしない。.structured_output だけを見る"
# status が SUCCESS であることは判定に関係しない。もし包み全体を検証に回していると、
# status フィールドの存在で additionalProperties: false のスキーマ検証に失敗し、
# 「読めなかった」側へ落ちる（findings が無いのに exit 1 になる）はずである。
rc=0
FAKE_AGY_ANSWER='{"reviewed":true,"findings":[]}' run_review || rc=$?
assert_eq "$rc" "0" "exit code"

it "JSON として読めない回答（ツール拒否で応答なし）は落とす"
rc=0
FAKE_AGY_EMPTY=1 run_review || rc=$?
assert_eq "$rc" "1" "exit code"

# ---- 3b. 差分を読めなかった回答は落とし、記録も残させないこと（game-forge #873） ----
#
# `other` の指摘 1 件で「読めませんでした」と報告しただけの回答は、category だけ
# 見ると判定を動かさないため LGTM になり、loop-gate.sh が読んでいないものを記録
# してしまう。reviewed を回答の必須項目にして塞ぐ（codex と同じ判定ロジックを
# 共有しているため、ここでは配線がエンジンをまたいで効くことだけを確かめる）。

it "reviewed が欠けた回答は落とす（「欠け」を「読めた」に倒さない）"
rc=0
FAKE_AGY_ANSWER='{"findings":[]}' run_review || rc=$?
assert_eq "$rc" "1" "exit code"

it "reviewed が真偽値でない回答は落とす"
rc=0
FAKE_AGY_ANSWER='{"reviewed":"true","findings":[]}' run_review || rc=$?
assert_eq "$rc" "1" "exit code"

it "reviewed:false の回答は、指摘の中身によらず落とし、理由を示す"
rc=0
FAKE_AGY_ANSWER='{"reviewed":false,"findings":[{"category":"other","file":"","line":0,"what":"レビューを実施できませんでした。","why":"ツールの実行が拒否されました。"}]}' \
  run_review || rc=$?
if [[ "$rc" -eq 1 ]] && grep -q '差分を読めなかったと答えました' "$WORK/err"; then
  pass
else
  fail "exit=$rc、または理由が出ていない: $(cat "$WORK/err")"
fi

it "reviewed:false の回答では完了の行（LGTM / findings reported）を出さない"
# loop-gate.sh の record_second_opinion はこの行の有無で「判定に到達したか」を見て
# 記録する。出してしまうと、落ちても findings の記録が作られ、確認側が緑になる。
if grep -qE -e '^\[second-opinion\] LGTM \(' -e '^\[second-opinion\] findings reported by ' "$WORK/both" 2>/dev/null; then
  fail "完了の行が出ている: $(cat "$WORK/both")"
else
  pass
fi

# ---- 4. 分割は従来どおり agy だけに残る（挙動は変えない） ----

it "巨大な差分でも分割して全チャンクをレビューする（上限超過を拒否しない）"
# それぞれは単一引数の上限（約 131072 バイト）に収まるが、2 ファイル合計では
# 超える大きさを作る。1 ハンクだけで上限を超える形（分割できない単位）とは別の
# 経路（ファイル単位でチャンクへ詰め、複数チャンクへ分ける）を確かめる。
# yes | head のような早期終了パイプは使わない（pipefail 下で生産側が SIGPIPE で
# 死ぬと判定が反転する。scripts/check-shell-portability.sh の PIPEFAIL_SIGPIPE）。
# 単一プロセスの awk で生成する。
awk 'BEGIN { for (i = 0; i < 80000; i++) printf "x"; printf "\n" }' > "$REPO/big1.txt"
awk 'BEGIN { for (i = 0; i < 80000; i++) printf "y"; printf "\n" }' > "$REPO/big2.txt"
git -C "$REPO" add big1.txt big2.txt
rm -f "$RECORD/argv"
rc=0
FAKE_AGY_ANSWER='{"reviewed":true,"findings":[]}' run_review || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'second-opinion.*chunk 1/2' "$WORK/out" && grep -q 'chunk 2/2' "$WORK/out"; then
  pass
else
  fail "分割経路が壊れている: exit=$rc, out: $(cat "$WORK/out"), err: $(head -c 800 "$WORK/err")"
fi
git -C "$REPO" rm -q --cached big1.txt big2.txt
rm -f "$REPO/big1.txt" "$REPO/big2.txt"

exit_with_result
