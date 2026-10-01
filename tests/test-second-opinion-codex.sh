#!/usr/bin/env bash
# second-opinion-review.sh の codex エンジンの配線を、本物の CLI 無しで確かめる。
#
# ## なぜ要るのか
#
# --engine codex はツールを解禁した唯一のエンジンで、判定も JSON スキーマ方式に
# 変わっている。どちらも、失敗しても緑に見える形で壊れうる。
#
#   1. 差分を渡してしまう。ツールを解禁した意味は「モデル自身に git diff を
#      叩かせ、差分の外も読ませる」ことにある。差分を標準入力へ流すと、この
#      意味が失われたまま気づけない。
#   2. 判定が回答以外の文字列で行われる。codex の回答は -o のファイルから取る。
#      stdout を読む実装へ戻ると、見出しや進捗が判定へ混ざる。
#   3. 判定がモデルの category 以外で決まる。知らない category や形の崩れた
#      JSON を「指摘なし」へ倒すと、レビューしていないものを緑として報告する。
#
# いずれも本物の CLI を呼ばずに確かめられる。仕込みの codex / gh を PATH の先へ
# 置き、受け取った標準入力と引数を記録させる。
#
# ## 仕込みは「本物がしないこと」をしない
#
# 仕込みの codex は、second-opinion-review.sh の実装コメントに書かれた実測仕様
# （`codex login status` の終了コードで有無を返す／回答は -o へ書く／失敗回は
# -o を作らない）だけを真似る。回答を stdout へは書かせない。書かせると、-o を
# 読まない実装でも通ってしまい、この検査が塞ぎたい壊れ方（2）をそのまま隠す。
#
# この環境には codex CLI / gh が無いため、仕込みで代替する（非対話・ネットワーク不要）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-second-opinion-codex"

# second-opinion-review.sh は load-project-env.sh を通じて **このリポジトリ自身の
# .env を、ホスト env より優先して**読む。host env をここで unset しても .env の
# 値には勝てないため、下の各検査は**実行回数（RUNS）が 1 以外であることを
# 前提にしない**（例: 完了行の検査は正規表現で先頭一致を見るだけで、N/M の値は
# 問わない）。--runs を明示指定する検査だけが、その値を確実に使う。
unset SECOND_OPINION_ENGINE SECOND_OPINION_RUNS SECOND_OPINION_MODEL

REVIEW="$REPO_ROOT/scripts/second-opinion-review.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-second-opinion-codex.XXXXXX")"
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

# 検査用の git リポジトリ。second-opinion-review.sh は `git diff <range>` / `git log`
# を cwd で解くので、このリポジトリの履歴に依存しない使い捨てを作る。
git -C "$REPO" init -q
git -C "$REPO" config user.email "selftest@example.invalid"
git -C "$REPO" config user.name "selftest"
printf 'hello\n' > "$REPO/sample.txt"
git -C "$REPO" add sample.txt
git -C "$REPO" commit -q -m base
printf 'hello\nworld\n' > "$REPO/sample.txt"
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

printf '%s\n' "${FAKE_CODEX_ANSWER:-{\"findings\":[]\}}" > "$answer"

# stdout へは回答を書かない。書くと、-o を読まない実装でもこの検査が通る。
printf '%s\n' "${FAKE_CODEX_STDOUT:-}"
FAKE
chmod +x "$FAKE_BIN/codex"

# 仕込みの gh。issue の文脈（枝の issue 全文）と、参照された issue / PR の文脈
# （issues API 相当）の両方を担う。呼び出しも記録する（引けない番号へ行っていない
# ことを確かめるため）。
cat > "$FAKE_BIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_GH_RECORD:-/dev/null}"
if [[ "${1-}" == "issue" && "${2-}" == "view" ]]; then
  printf '%s\n' "${FAKE_GH_ISSUE_BODY-}"
  exit 0
fi
if [[ "${1-}" == "api" && "${2-}" =~ ^repos/\{owner\}/\{repo\}/issues/([0-9]+)$ ]]; then
  f="${FAKE_GH_DIR-}/${BASH_REMATCH[1]}.json"
  if [[ -n "${FAKE_GH_DIR-}" && -f "$f" ]]; then
    cat "$f"
    exit 0
  fi
  echo "gh: Not Found (HTTP 404)" >&2
  exit 1
fi
exit 1
FAKEGH
chmod +x "$FAKE_BIN/gh"

run_review() {
  # 被検査側を、仕込みを先に見る PATH で走らせる。標準出力と標準エラーを分けて取る。
  # 加えて、両方を結合した記録（$WORK/both）も残す。loop-gate.sh の
  # record_second_opinion は `second-opinion-review.sh 2>&1 | tee` で両方を
  # 1 つの捕捉ファイルへ混ぜて読むため（完了行の一部は stderr へ出る）、
  # stdout だけを見るテストでは記録の契機を正しく確かめられない。
  #
  # 関数の戻り値は被検査側の終了コードにする。末尾に別のコマンド（cat）を
  # 置くと、関数の戻り値がそちらに差し替わり、呼び出し側が rc を取り違える。
  local rc
  rm -f "$RECORD/calls"
  (
    cd "$REPO" || exit 1
    PATH="$FAKE_BIN:$PATH" \
    FAKE_CODEX_RECORD="$RECORD" \
    FAKE_GH_RECORD="$RECORD/gh-calls" \
      bash "$REVIEW" --engine codex "$@" \
        > "$WORK/out" 2> "$WORK/err"
  )
  rc=$?
  cat "$WORK/out" "$WORK/err" > "$WORK/both" 2>/dev/null || true
  return "$rc"
}

# ---- 1. 差分は渡さない（ツールの解禁）。プロンプトが取得コマンドを示す ----

it "指摘なしの回答で exit 0 になる"
rm -f "$RECORD/stdin" "$RECORD/argv"
rc=0
FAKE_CODEX_ANSWER='{"findings":[]}' run_review || rc=$?
if [[ "$rc" -eq 0 ]]; then pass; else fail "exit $rc: $(cat "$WORK/err")"; fi

it "指摘なしの回では loop-gate.sh が記録の契機にする完了行が出る"
# scripts/loop-gate.sh の record_second_opinion は、出力の中に次の 3 つの
# いずれかが行頭で現れたときだけ「判定に到達した」として記録する
# （`^\[second-opinion\] LGTM \(` / `findings reported by ` /
# `[0-9]+/[0-9]+ chunks reported findings`）。codex は常に単一チャンクなので、
# ここでは 1 つ目の形を確かめる。綴りを変えると、codex 経路だけ記録されなくなる。
if grep -qE '^\[second-opinion\] LGTM \(' "$WORK/both" 2>/dev/null; then
  pass
else
  fail "完了行が出ていない: $(cat "$WORK/both")"
fi

it "落とす指摘（bug）の回では findings reported by で始まる完了行が出る"
rc=0
FAKE_CODEX_ANSWER='{"findings":[{"category":"bug","file":"a.ts","line":1,"what":"x","why":"y"}]}' \
  run_review || rc=$?
if [[ "$rc" -eq 1 ]] && grep -qE '^\[second-opinion\] findings reported by ' "$WORK/both" 2>/dev/null; then
  pass
else
  fail "exit=$rc, 完了行: $(cat "$WORK/both")"
fi

it "codex が標準入力を受け取っている"
if [[ -f "$RECORD/stdin" ]]; then pass; else fail "プロンプトの渡し方が壊れています（stdin が記録されていない）"; fi

it "標準入力に差分そのものを渡していない"
# 渡してしまうと、ツールを解禁した意味が薄れ、差分の大きさが引数や標準入力の
# 上限に当たる形へ逆戻りする。
if grep -q '^diff --git' "$RECORD/stdin" 2>/dev/null; then
  fail "標準入力に差分が載っています（ツールを解禁したモデル自身に取らせるはずです）"
else
  pass
fi

it "標準入力が差分の取得コマンド（git diff）を指示している"
if grep -q 'git diff' "$RECORD/stdin" 2>/dev/null; then
  pass
else
  fail "差分の取得コマンドの指示がありません: $(cat "$RECORD/stdin" 2>/dev/null)"
fi

it "標準入力が報告の規則（category）を含む"
if grep -q 'edge-case' "$RECORD/stdin" 2>/dev/null; then
  pass
else
  fail "報告の規則（category の説明）がありません"
fi

# ---- 2. 引数の形（読み取り専用・スキーマ・回答の口・既定モデル） ----

it "引数に read-only sandbox / color never / --output-schema / -o が含まれる"
argv="$(cat "$RECORD/argv" 2>/dev/null || true)"
missing=""
for needed in exec - --sandbox read-only --color never --output-schema -o; do
  printf '%s\n' "$argv" | grep -qx -- "$needed" || missing="$missing $needed"
done
if [[ -z "$missing" ]]; then pass; else fail "引数に無いトークン:$missing"; fi

it "--output-schema の指す先が実在するスキーマファイルである"
schema_arg="$(awk '$0 == "--output-schema" { getline; print; exit }' "$RECORD/argv" 2>/dev/null)"
if [[ -n "$schema_arg" && -f "$schema_arg" ]] && jq empty "$schema_arg" >/dev/null 2>&1; then
  pass
else
  fail "--output-schema の指す先が無い、または JSON として読めない: ${schema_arg:-（無し）}"
fi

it "既定モデルは gpt-6-sol である"
model_value="$(awk '$0 == "--model" { getline; print; exit }' "$RECORD/argv" 2>/dev/null)"
assert_eq "$model_value" "gpt-6-sol" "既定モデル"

it "--model を渡すとそちらが使われる"
rm -f "$RECORD/argv"
rc=0
FAKE_CODEX_ANSWER='{"findings":[]}' run_review --model gpt-6-luna || rc=$?
model_value="$(awk '$0 == "--model" { getline; print; exit }' "$RECORD/argv" 2>/dev/null)"
if [[ "$rc" -eq 0 ]]; then
  assert_eq "$model_value" "gpt-6-luna" "--model の指定"
else
  fail "--model を渡した回で exit $rc"
fi

# ---- 3. 判定は JSON の category から行う（4 点だけが落とす） ----

it "落とさない category（promise-mismatch・other）だけでは通過する"
rc=0
FAKE_CODEX_ANSWER='{"findings":[{"category":"promise-mismatch","file":"a.ts","line":1,"what":"x","why":"y"},{"category":"other","file":"a.ts","line":2,"what":"x","why":"y"}]}' \
  run_review || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'promise-mismatch' "$WORK/out"; then
  pass
else
  fail "exit=$rc（0 を期待）、または落とさない指摘が出力に出ていない: $(cat "$WORK/out")"
fi

for category in bug vulnerability type-error edge-case; do
  it "category=$category は落とす"
  rc=0
  FAKE_CODEX_ANSWER="{\"findings\":[{\"category\":\"$category\",\"file\":\"a.ts\",\"line\":1,\"what\":\"x\",\"why\":\"y\"}]}" \
    run_review || rc=$?
  assert_eq "$rc" "1" "exit code"
done

it "JSON として読めない回答は落とす"
rc=0
FAKE_CODEX_ANSWER='これは JSON ではありません' run_review || rc=$?
if [[ "$rc" -eq 1 ]] && grep -q 'JSON として読めませんでした' "$WORK/err"; then
  pass
else
  fail "exit=$rc、または理由が出ていない: $(cat "$WORK/err")"
fi

it "findings が配列でない回答は落とす"
rc=0
FAKE_CODEX_ANSWER='{"findings":"たくさん"}' run_review || rc=$?
assert_eq "$rc" "1" "exit code"

it "スキーマに無い category（綴り違い）は指摘なしへ倒さず落とす"
rc=0
FAKE_CODEX_ANSWER='{"findings":[{"category":"bugs","file":"a.ts","line":1,"what":"x","why":"y"}]}' \
  run_review || rc=$?
assert_eq "$rc" "1" "exit code"

it "what / why が欠けた回答は落とす"
rc=0
FAKE_CODEX_ANSWER='{"findings":[{"category":"bug","file":"a.ts","line":1}]}' run_review || rc=$?
assert_eq "$rc" "1" "exit code"

it "file / line が欠けた回答は、検証（形）が理由で落ちる"
rc=0
FAKE_CODEX_ANSWER='{"findings":[{"category":"bug","what":"x","why":"y"}]}' run_review || rc=$?
if [[ "$rc" -eq 1 ]] && grep -q 'JSON として読めませんでした' "$WORK/err"; then
  pass
else
  fail "exit=$rc、または別の理由で落ちている（検証が効いていません）: $(cat "$WORK/err")"
fi

it "line が数でない回答は、検証（形）が理由で落ちる"
rc=0
FAKE_CODEX_ANSWER='{"findings":[{"category":"bug","file":"a.ts","line":"3行目","what":"x","why":"y"}]}' \
  run_review || rc=$?
if [[ "$rc" -eq 1 ]] && grep -q 'JSON として読めませんでした' "$WORK/err"; then
  pass
else
  fail "exit=$rc、または別の理由で落ちている（検証が効いていません）: $(cat "$WORK/err")"
fi

# ---- 4. 判定は -o のファイルから取ること（stdout では判定しない） ----

it "回答は指摘なし・stdout は落とす指摘でも exit 0（stdout で判定していない）"
rc=0
FAKE_CODEX_ANSWER='{"findings":[]}' \
FAKE_CODEX_STDOUT='{"findings":[{"category":"bug","file":"a.ts","line":1,"what":"x","why":"y"}]}' \
  run_review || rc=$?
assert_eq "$rc" "0" "exit code"

it "回答は落とす指摘・stdout は指摘なしだと exit 1（-o を見落としていない）"
rc=0
FAKE_CODEX_ANSWER='{"findings":[{"category":"bug","file":"a.ts","line":1,"what":"x","why":"y"}]}' \
FAKE_CODEX_STDOUT='{"findings":[]}' \
  run_review || rc=$?
assert_eq "$rc" "1" "exit code"

# ---- 5. 未ログインは exec の前に止まること ----

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

# ---- 6. 0 で終わりながら回答を書かない回は、失敗として扱うこと ----

it "回答が無いまま 0 で終わる回は失敗にする"
rc=0
FAKE_CODEX_WRITE_ANSWER=0 run_review || rc=$?
assert_eq "$rc" "1" "exit code"

# ---- 7. --runs 2 で、前の回の回答が使い回されないこと ----

it "--runs 2 で 2 回目が回答を書かなければ、前の回の回答を読まずに失敗する"
rc=0
FAKE_CODEX_WRITE_ANSWER=first FAKE_CODEX_ANSWER='{"findings":[]}' run_review --runs 2 || rc=$?
assert_eq "$rc" "1" "exit code"

# ---- 8. issue の文脈（枝の名前から番号を取り、scope / acceptance を載せる） ----

it "枝の名前の issue 番号から本文（acceptance 含む）を引いてプロンプトへ載せる"
git -C "$REPO" checkout -q -b feat/9999-selftest-context
rm -f "$RECORD/stdin"
rc=0
(
  cd "$REPO"
  PATH="$FAKE_BIN:$PATH" \
  FAKE_CODEX_RECORD="$RECORD" \
  FAKE_GH_RECORD="$RECORD/gh-calls" \
  FAKE_GH_ISSUE_BODY='# issue #9999 仕込みの票
scope.in:
  - 仕込みの目印 SELFTEST-ISSUE-MARKER' \
  FAKE_CODEX_ANSWER='{"findings":[]}' \
    bash "$REVIEW" --engine codex > "$WORK/out" 2> "$WORK/err"
) || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'SELFTEST-ISSUE-MARKER' "$RECORD/stdin" 2>/dev/null; then
  pass
else
  fail "exit=$rc、またはプロンプトに issue の本文が無い: $(cat "$WORK/err")"
fi
git -C "$REPO" checkout -q -

# ---- 9. 参照された issue / PR の文脈（差分の追加行・コミットメッセージの #N） ----

it "参照された issue の acceptance と、PR の状態をプロンプトへ載せる（上限・持ち主判定も守る）"
gh_dir="$WORK/gh"
mkdir -p "$gh_dir"
owner_url='https://api.github.com/repos/owner1/repo1'
cat > "$gh_dir/11.json" <<EOF
{"repository_url":"$owner_url","user":{"login":"owner1"},"state":"open","state_reason":null,"title":"コミットで名指しした票",
 "body":"## intake\n\n\`\`\`yaml\ngoal: g\nacceptance:\n  - REF-ACCEPTANCE-MARKER\npriority: 中\n\`\`\`\nREF-OUTSIDE-ACCEPTANCE-MARKER"}
EOF
cat > "$gh_dir/12.json" <<EOF
{"repository_url":"$owner_url","user":{"login":"owner1"},"state":"closed","title":"追加行の PR",
 "pull_request":{"merged_at":"2026-09-29T00:00:00Z"},"body":"acceptance:\n  - PRBODY-MARKER"}
EOF
cat > "$gh_dir/13.json" <<EOF
{"repository_url":"$owner_url","user":{"login":"owner1"},"state":"open","title":"REF-REMOVED-MARKER","body":""}
EOF
cat > "$gh_dir/14.json" <<EOF
{"repository_url":"$owner_url","user":{"login":"stranger"},"state":"open","title":"REF-STRANGER-MARKER","body":"acceptance:\n  - REF-STRANGER-MARKER"}
EOF
cat > "$gh_dir/22.json" <<EOF
{"repository_url":"$owner_url","user":{"login":"owner1"},"state":"open","title":"REF-OVER-LIMIT-MARKER","body":""}
EOF
# #15〜#21 は JSON を置かない（引けない番号。止めずに続けることを見る）。

git -C "$REPO" checkout -q -b refs-selftest
printf 'old ref #13\n' > "$REPO/refs.txt"
git -C "$REPO" add refs.txt
git -C "$REPO" commit -q -m "base of refs"
# 追加行の順: #12 #14 #15 … #22。コミットメッセージの #11 が先頭に来るので、候補は
# 11 本で上限 10 を 1 本超え、最後の #22 が落ちる。#13 は削除行にしか無い。
{
  printf 'new ref #12 and #14\n'
  for i in 15 16 17 18 19 20 21 22; do printf 'ref #%s\n' "$i"; done
} > "$REPO/refs.txt"
git -C "$REPO" add refs.txt
git -C "$REPO" commit -q -m "refs を差し替える（#11）"

rm -f "$RECORD/stdin" "$RECORD/gh-calls"
rc=0
(
  cd "$REPO"
  PATH="$FAKE_BIN:$PATH" \
  FAKE_CODEX_RECORD="$RECORD" \
  FAKE_GH_RECORD="$RECORD/gh-calls" \
  FAKE_GH_DIR="$gh_dir" \
  FAKE_CODEX_ANSWER='{"findings":[]}' \
    bash "$REVIEW" --engine codex --range 'HEAD~1..HEAD' > "$WORK/out" 2> "$WORK/err"
) || rc=$?

detail=""
[[ "$rc" -eq 0 ]] || detail="exit=$rc "
[[ -f "$RECORD/stdin" ]] || detail="${detail}codex が呼ばれていない "
if [[ -z "$detail" ]]; then
  grep -q 'REF-ACCEPTANCE-MARKER' "$RECORD/stdin" || detail="${detail}参照 issue の acceptance が無い "
  grep -q 'REF-OUTSIDE-ACCEPTANCE-MARKER' "$RECORD/stdin" && detail="${detail}acceptance の外まで載っている "
  grep -q 'PRBODY-MARKER' "$RECORD/stdin" && detail="${detail}PR の本文が載っている "
  grep -q 'REF-REMOVED-MARKER' "$RECORD/stdin" && detail="${detail}削除行のみの参照が載っている "
  grep -q 'REF-STRANGER-MARKER' "$RECORD/stdin" && detail="${detail}持ち主以外の参照が載っている "
  grep -q 'REF-OVER-LIMIT-MARKER' "$RECORD/stdin" && detail="${detail}上限超過の参照が載っている "
fi
if [[ -f "$RECORD/gh-calls" ]]; then
  grep -q 'issues/13$' "$RECORD/gh-calls" && detail="${detail}削除行のみの#13を引きに行っている "
  grep -q 'issues/22$' "$RECORD/gh-calls" && detail="${detail}上限超過の#22を引きに行っている "
fi

if [[ -z "$detail" ]]; then pass; else fail "$detail"; fi

it "上限超過・持ち主以外・引けなかった旨が出力に出る"
if grep -q '上限 10 本を超えたため載せません: #22' "$WORK/out" \
  && grep -q '作成者がリポジトリの持ち主でないため載せません: #14' "$WORK/out" \
  && grep -q '引けなかったため載せません: #15' "$WORK/err"; then
  pass
else
  fail "診断行が揃っていない。out: $(cat "$WORK/out") / err: $(cat "$WORK/err")"
fi
git -C "$REPO" checkout -q -

it "gh が使えない（失敗する）場合でも文脈なしで続行する（レビュー自体は落とさない）"
# 「command -v gh がそもそも失敗する」までは作らない（システムの gh を PATH から
# 隔離するには coreutils 一式を再現する必要があり、割に合わない）。「gh はあるが
# 呼び出しが失敗する」（認証切れ・ネットワーク不通等）という、本番でも起きる形で
# 代替する。差し替えは要求 7（「gh が使えない、または読めないときは、文脈なしで
# 続行する」）が求めるとおり偽物で行う。
failing_gh_bin="$WORK/failing-gh"
mkdir -p "$failing_gh_bin"
cat > "$failing_gh_bin/gh" <<'FAILGH'
#!/usr/bin/env bash
exit 1
FAILGH
chmod +x "$failing_gh_bin/gh"

rm -f "$RECORD/stdin"
printf 'hello\nworld\nagain\n' > "$REPO/sample.txt"
git -C "$REPO" add sample.txt
rc=0
(
  cd "$REPO"
  PATH="$failing_gh_bin:$FAKE_BIN:$PATH" \
  FAKE_CODEX_RECORD="$RECORD" \
  FAKE_CODEX_ANSWER='{"findings":[]}' \
    bash "$REVIEW" --engine codex > "$WORK/out" 2> "$WORK/err"
) || rc=$?
if [[ "$rc" -eq 0 ]] && [[ -f "$RECORD/stdin" ]]; then
  pass
else
  fail "gh 失敗時にレビューそのものが止まった: exit=$rc, err: $(cat "$WORK/err")"
fi

exit_with_result
