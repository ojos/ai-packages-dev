#!/usr/bin/env bash
# second-opinion-review.sh の codex エンジンの配線を、本物の CLI 無しで確かめる。
#
# ## なぜ要るのか
#
# --engine codex は、ツールを使わせず起動する環境も絞るエンジンで、判定は
# JSON スキーマ方式である。どちらも、失敗しても緑に見える形で壊れうる。
#
#   1. 差分が標準入力に載らない、またはツールを使う文面に戻る。ツールは使わせ
#      ないので、差分が届く道は標準入力しかない。
#   1b. 起動する環境が広がる。渡る環境変数・作業場所・引数の旗が、許可リストと
#      無効化の組から外れる。仕込みの codex が実際に受け取った環境・作業場所・
#      引数で確かめる。
#   2. 判定が回答以外の文字列で行われる。codex の回答は -o のファイルから取る。
#      stdout を読む実装へ戻ると、見出しや進捗が判定へ混ざる。
#   3. 判定がモデルの category 以外で決まる。知らない category や形の崩れた
#      JSON を「指摘なし」へ倒すと、レビューしていないものを緑として報告する。
#   4. 差分を読めなかったと答えた回答（`reviewed: false`）が、指摘の種別だけで
#      通過する。`other` の指摘 1 件で「読めませんでした」と報告しただけの回答が
#      LGTM になり、loop-gate.sh が読んでいないものを記録してしまう
#      （game-forge #873）。
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

# 被検査側は codex を env -i で起動するため、テストからの FAKE_CODEX_* は環境では
# 届かない。記録先はこの仕込みの位置から解決し、切り替えは fake.env から読む。
FAKE_CODEX_RECORD="$(cd "$(dirname "$0")/.." && pwd)/record"
if [[ -f "$FAKE_CODEX_RECORD/fake.env" ]]; then
  # shellcheck disable=SC1091
  . "$FAKE_CODEX_RECORD/fake.env"
fi

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

# 受け取った環境・作業場所を記録する（実行環境を絞れていることの検査に使う）。
env | LC_ALL=C sort > "$FAKE_CODEX_RECORD/env"
pwd > "$FAKE_CODEX_RECORD/cwd"
ls -A > "$FAKE_CODEX_RECORD/cwd-list"

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

printf '%s\n' "${FAKE_CODEX_ANSWER:-{\"reviewed\":true,\"findings\":[]\}}" > "$answer"

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
  local rc v
  rm -f "$RECORD/calls"
  # 仕込みの codex への切り替えは、環境ではなくファイルで渡す（env -i で届かない）。
  : > "$RECORD/fake.env"
  for v in $(compgen -e | command grep '^FAKE_CODEX_' || true); do
    printf '%s=%q\n' "$v" "${!v}" >> "$RECORD/fake.env"
  done
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

# ---- 1. 差分は標準入力で渡し、ツールを使わせない文面にする ----

it "指摘なしの回答で exit 0 になる"
rm -f "$RECORD/stdin" "$RECORD/argv"
rc=0
FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[]}' run_review || rc=$?
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
FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[{"category":"bug","file":"a.ts","line":1,"what":"x","why":"y","failure_scenario":"s"}]}' \
  run_review || rc=$?
if [[ "$rc" -eq 1 ]] && grep -qE '^\[second-opinion\] findings reported by ' "$WORK/both" 2>/dev/null; then
  pass
else
  fail "exit=$rc, 完了行: $(cat "$WORK/both")"
fi

it "codex が標準入力を受け取っている"
if [[ -f "$RECORD/stdin" ]]; then pass; else fail "プロンプトの渡し方が壊れています（stdin が記録されていない）"; fi

it "標準入力の先頭に差分そのものを渡している（ツールは使わせないので差分はここでしか届かない）"
if [[ "$(sed -n 1p "$RECORD/stdin" 2>/dev/null)" == 'diff --git'* ]]; then
  pass
else
  fail "標準入力の先頭が差分ではありません: $(sed -n 1,3p "$RECORD/stdin" 2>/dev/null)"
fi

it "プロンプトは差分の後に置き、ツールを使わない文面である"
if grep -q '上記は git の差分です' "$RECORD/stdin" 2>/dev/null \
  && grep -q 'ファイル読み取りやコマンド実行のツールを使わないでください' "$RECORD/stdin" 2>/dev/null; then
  pass
else
  fail "プロンプトの指示が見当たりません"
fi

it "ツールの使用を促す文面（読み取りのコマンドを使ってよい等）が残っていない"
if grep -q 'を使ってよい' "$RECORD/stdin" 2>/dev/null; then
  fail "ツールを許す文面が残っています"
else
  pass
fi

it "標準入力が報告の規則（category）を含む"
if grep -q 'edge-case' "$RECORD/stdin" 2>/dev/null; then
  pass
else
  fail "報告の規則（category の説明）がありません"
fi

# ---- 2. 引数の形（読み取り専用・スキーマ・回答の口・既定モデル） ----

it "引数に read-only sandbox / color never / --output-schema / -o / 環境を絞る旗（inherit=none・ツールの無効化・web_search の無効化・--ignore-user-config）が含まれる"
argv="$(cat "$RECORD/argv" 2>/dev/null || true)"
missing=""
for needed in exec - --sandbox read-only --color never --output-schema -o \
  --skip-git-repo-check --ignore-user-config \
  shell_environment_policy.inherit=none 'web_search="disabled"' \
  shell_tool browser_use in_app_browser computer_use apps code_mode_host \
  view_image goals image_generation; do
  printf '%s\n' "$argv" | grep -x -- "$needed" >/dev/null || missing="$missing $needed"
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
FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[]}' run_review --model gpt-6-luna || rc=$?
model_value="$(awk '$0 == "--model" { getline; print; exit }' "$RECORD/argv" 2>/dev/null)"
if [[ "$rc" -eq 0 ]]; then
  assert_eq "$model_value" "gpt-6-luna" "--model の指定"
else
  fail "--model を渡した回で exit $rc"
fi

# ---- 2b. 起動する環境が絞られている（渡す環境変数・作業場所） ----
#
# 仕込みの codex が実際に受け取った環境と作業場所で確かめる。.env を読み込む前の
# 値のうち、許可リストの変数だけが渡り、.env にだけある変数は渡らない。
SECRET_ENV="$WORK/secret.env"
cat > "$SECRET_ENV" <<'ENVEOF'
DUMMY_ONLY_IN_ENVFILE=dummy-env-file-value
GH_TOKEN=dummy-gh-token-from-envfile
HTTPS_PROXY=http://envfile-proxy.invalid:3128
ENVEOF
# 作業ツリーの直下にも .env を置く（作業場所がここなら見えてしまう形）。
printf 'DUMMY_ONLY_IN_ENVFILE=dummy-env-file-value\n' > "$REPO/.env"
rm -f "$RECORD/env" "$RECORD/cwd" "$RECORD/cwd-list"
rc=0
PROJECT_ENV_FILE="$SECRET_ENV" \
  HTTPS_PROXY="http://host-proxy.invalid:8080" \
  DUMMY_ONLY_IN_HOST=dummy-host-value \
  FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[]}' run_review || rc=$?

it "環境を絞った回でも exit 0 になる"
if [[ "$rc" -eq 0 ]]; then pass; else fail "exit $rc: $(cat "$WORK/err")"; fi

it ".env にだけある変数（GH_TOKEN・ダミーの秘密）が codex に渡らない"
if command grep -qE '^(GH_TOKEN|DUMMY_ONLY_IN_ENVFILE|DUMMY_ONLY_IN_HOST)=' "$RECORD/env" 2>/dev/null; then
  fail "渡ってはいけない変数が渡っている: $(command grep -oE '^(GH_TOKEN|DUMMY_ONLY_IN_ENVFILE|DUMMY_ONLY_IN_HOST)=' "$RECORD/env" | tr '\n' ' ')"
else
  [[ -s "$RECORD/env" ]] && pass || fail "環境の記録が無い"
fi

it ".env に書いた HTTPS_PROXY は渡らず、読み込む前の値だけが渡る"
assert_eq "$(command grep '^HTTPS_PROXY=' "$RECORD/env" 2>/dev/null)" "HTTPS_PROXY=http://host-proxy.invalid:8080" "HTTPS_PROXY"

it "渡る環境変数は許可リストの範囲に収まる"
extra="$(command grep -oE '^[A-Za-z_][A-Za-z0-9_]*' "$RECORD/env" | command grep -vxE 'HOME|CODEX_HOME|PATH|LANG|LANGUAGE|LC_[A-Z]+|TMPDIR|TERM|HTTPS_PROXY|HTTP_PROXY|ALL_PROXY|NO_PROXY|https_proxy|http_proxy|all_proxy|no_proxy|SSL_CERT_FILE|SSL_CERT_DIR|PWD|SHLVL|OLDPWD|_' || true)"
if [[ -z "$extra" ]]; then pass; else fail "許可リスト外の変数が渡っている: $(echo "$extra" | tr '\n' ' ')"; fi

it "作業場所は一時ディレクトリで、リポジトリではなく、.env が無い"
cwd_value="$(cat "$RECORD/cwd" 2>/dev/null)"
if [[ -n "$cwd_value" && "$cwd_value" != "$(cd "$REPO" && pwd -P)" && "$cwd_value" != "$REPO" ]] \
  && [[ ! -e "$cwd_value/.env" ]] && ! command grep -qx '.env' "$RECORD/cwd-list" 2>/dev/null; then
  pass
else
  fail "作業場所が絞れていない: cwd=$cwd_value list=$(tr '\n' ' ' < "$RECORD/cwd-list" 2>/dev/null)"
fi
rm -f "$REPO/.env"

# ---- 3. 判定は JSON の category から行う（4 点だけが落とす） ----

it "落とさない category（promise-mismatch・other）だけでは通過する"
rc=0
FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[{"category":"promise-mismatch","file":"a.ts","line":1,"what":"x","why":"y","failure_scenario":"s"},{"category":"other","file":"a.ts","line":2,"what":"x","why":"y","failure_scenario":"s"}]}' \
  run_review || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'promise-mismatch' "$WORK/out"; then
  pass
else
  fail "exit=$rc（0 を期待）、または落とさない指摘が出力に出ていない: $(cat "$WORK/out")"
fi

for category in bug vulnerability type-error edge-case; do
  it "category=$category は落とす"
  rc=0
  FAKE_CODEX_ANSWER="{\"reviewed\":true,\"findings\":[{\"category\":\"$category\",\"file\":\"a.ts\",\"line\":1,\"what\":\"x\",\"why\":\"y\",\"failure_scenario\":\"s\"}]}" \
    run_review || rc=$?
  assert_eq "$rc" "1" "exit code"
done

it "筋書きのあるゲート対象の指摘で落ち、出力に筋書きが表示される"
rc=0
FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[{"category":"bug","file":"a.ts","line":1,"what":"x","why":"y","failure_scenario":"空配列を渡すと添字 0 を読んで undefined を返す"}]}' \
  run_review || rc=$?
if [[ "$rc" -eq 1 ]] && grep -qF '失敗の筋書き: 空配列を渡すと添字 0 を読んで undefined を返す' "$WORK/both"; then
  pass
else
  fail "exit=$rc（1 を期待）、または筋書きが出力に出ていない: $(cat "$WORK/both")"
fi

it "ゲート対象で筋書きが空（空白だけを含む）なら、筋書きの欠落と示して失敗する"
for scenario in '' '  '; do
  rc=0
  FAKE_CODEX_ANSWER="{\"reviewed\":true,\"findings\":[{\"category\":\"bug\",\"file\":\"a.ts\",\"line\":1,\"what\":\"x\",\"why\":\"y\",\"failure_scenario\":\"$scenario\"}]}" \
    run_review || rc=$?
  if [[ "$rc" -eq 1 ]] && grep -q '失敗の筋書き（failure_scenario）がありません' "$WORK/err"; then
    pass
  else
    fail "exit=$rc、または形の不一致として扱われていない: $(cat "$WORK/err")"
  fi
done

it "報告だけの種類は、筋書きが空でも失敗にならない"
rc=0
FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[{"category":"promise-mismatch","file":"a.ts","line":1,"what":"x","why":"y","failure_scenario":""},{"category":"other","file":"a.ts","line":2,"what":"x","why":"y","failure_scenario":""}]}' \
  run_review || rc=$?
assert_eq "$rc" "0" "exit code"

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
FAKE_CODEX_ANSWER='{"reviewed":true,"findings":"たくさん"}' run_review || rc=$?
assert_eq "$rc" "1" "exit code"

it "スキーマに無い category（綴り違い）は指摘なしへ倒さず落とす"
rc=0
FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[{"category":"bugs","file":"a.ts","line":1,"what":"x","why":"y","failure_scenario":"s"}]}' \
  run_review || rc=$?
assert_eq "$rc" "1" "exit code"

it "what / why が欠けた回答は落とす"
rc=0
FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[{"category":"bug","file":"a.ts","line":1}]}' run_review || rc=$?
assert_eq "$rc" "1" "exit code"

it "file / line が欠けた回答は、検証（形）が理由で落ちる"
rc=0
FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[{"category":"bug","what":"x","why":"y","failure_scenario":"s"}]}' run_review || rc=$?
if [[ "$rc" -eq 1 ]] && grep -q 'JSON として読めませんでした' "$WORK/err"; then
  pass
else
  fail "exit=$rc、または別の理由で落ちている（検証が効いていません）: $(cat "$WORK/err")"
fi

it "line が数でない回答は、検証（形）が理由で落ちる"
rc=0
FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[{"category":"bug","file":"a.ts","line":"3行目","what":"x","why":"y","failure_scenario":"s"}]}' \
  run_review || rc=$?
if [[ "$rc" -eq 1 ]] && grep -q 'JSON として読めませんでした' "$WORK/err"; then
  pass
else
  fail "exit=$rc、または別の理由で落ちている（検証が効いていません）: $(cat "$WORK/err")"
fi

# ---- 3b. 差分を読めなかった回答は落とし、記録も残させないこと（game-forge #873） ----
#
# `other` の指摘 1 件で「読めませんでした」と報告しただけの回答は、category だけ
# 見ると判定を動かさないため LGTM になり、loop-gate.sh が読んでいないものを記録
# してしまう。reviewed を回答の必須項目にして塞ぐ。

it "reviewed が欠けた回答は落とす（「欠け」を「読めた」に倒さない）"
rc=0
FAKE_CODEX_ANSWER='{"findings":[]}' run_review || rc=$?
assert_eq "$rc" "1" "exit code"

it "reviewed が真偽値でない回答は落とす"
rc=0
FAKE_CODEX_ANSWER='{"reviewed":"true","findings":[]}' run_review || rc=$?
assert_eq "$rc" "1" "exit code"

it "reviewed:false の回答は、指摘の中身によらず落とし、理由と CLI の診断を示す"
# 実際に起きた形をそのまま当てる。codex がサンドボックスの失敗で git diff を
# 叩けず、「レビューを実施できませんでした」を other の指摘 1 件として返した。
rc=0
FAKE_CODEX_ANSWER='{"reviewed":false,"findings":[{"category":"other","file":"","line":0,"what":"レビューを実施できませんでした。","why":"git diff が bwrap: Failed to make / slave: Permission denied で失敗しました。","failure_scenario":""}]}' \
  run_review || rc=$?
if [[ "$rc" -eq 1 ]] \
  && grep -q '差分を読めなかったと答えました' "$WORK/err" \
  && grep -q 'bwrap' "$WORK/err"; then
  pass
else
  fail "exit=$rc、または理由・CLI の診断が出ていない: $(cat "$WORK/err")"
fi

it "reviewed:false の回答では完了の行（LGTM / findings reported）を出さない"
# loop-gate.sh の record_second_opinion はこの行の有無で「判定に到達したか」を見て
# 記録する。出してしまうと、落ちても findings の記録が作られ、確認側が緑になる。
if grep -qE -e '^\[second-opinion\] LGTM \(' -e '^\[second-opinion\] findings reported by ' "$WORK/both" 2>/dev/null; then
  fail "完了の行が出ている: $(cat "$WORK/both")"
else
  pass
fi
cp "$WORK/both" "$WORK/unreviewed-capture"

it "reviewed:false の回答は、筋書きの無いゲート対象の指摘があっても「読めなかった」と示す"
# 筋書きの検査は差分を読めた回答にだけかける。読めなかった回答で筋書きの欠落と
# 示すと、本当の原因（サンドボックス等で差分を読めなかった）が隠れる。
rc=0
FAKE_CODEX_ANSWER='{"reviewed":false,"findings":[{"category":"bug","file":"","line":0,"what":"x","why":"y","failure_scenario":""}]}' \
  run_review || rc=$?
if [[ "$rc" -eq 1 ]] \
  && grep -q '差分を読めなかったと答えました' "$WORK/err" \
  && ! grep -q '失敗の筋書き（failure_scenario）がありません' "$WORK/err"; then
  pass
else
  fail "exit=$rc、または理由が「読めなかった」になっていない: $(cat "$WORK/err")"
fi

it "対照: 指摘なしの出力には完了の行（LGTM）が出る（検査が空振りしていないことの前提）"
rc=0
FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[]}' run_review || rc=$?
if [[ "$rc" -eq 0 ]] && grep -qE '^\[second-opinion\] LGTM \(' "$WORK/both" 2>/dev/null; then
  pass
else
  fail "exit=$rc、完了の行が出ていない: $(cat "$WORK/both")"
fi
cp "$WORK/both" "$WORK/lgtm-capture"

# loop-gate.sh がこの出力から記録を作るかどうかは、綴りをここへ書き写さず
# loop-gate.sh 自身の関数（record_second_opinion）で確かめる。書き写すと、
# 片方だけ直ったときにこの検査が空振りする。
#
# second-opinion-record.sh は自分の置き場所（git リポジトリ）へ cd して記録する。
# 本物（開発リポジトリ自身）を呼ぶと、この検査を回した worktree 自身の記録を
# 上書きしてしまうため、使い捨ての $REPO へ写しを置いて呼ぶ。
mkdir -p "$REPO/scripts"
cp "$REPO_ROOT/scripts/loop-gate.sh" "$REPO_ROOT/scripts/second-opinion-record.sh" "$REPO/scripts/"
record_after() {
  (
    cd "$REPO" || exit 1
    rm -rf .git/second-opinion
    # shellcheck source=scripts/loop-gate.sh
    . "$REPO/scripts/loop-gate.sh"
    record_second_opinion "$1" staged "$2" >/dev/null 2>&1
    if [[ -f .git/second-opinion/meta ]]; then echo recorded; else echo none; fi
  )
}

it "対照: LGTM の出力からは loop-gate.sh が記録を作る（記録の経路そのものは壊れていない）"
if [[ "$(record_after "$WORK/lgtm-capture" 0)" == "recorded" ]]; then
  pass
else
  fail "LGTM の出力から記録が作られませんでした（これが空振りすると下の検査も当てにならない）"
fi

it "reviewed:false の出力からは、loop-gate.sh が記録を作らない"
if [[ "$(record_after "$WORK/unreviewed-capture" 1)" == "none" ]]; then
  pass
else
  fail "差分を読めなかった出力から記録が作られました（確認側が緑になります）"
fi

# ---- 4. 判定は -o のファイルから取ること（stdout では判定しない） ----

it "回答は指摘なし・stdout は落とす指摘でも exit 0（stdout で判定していない）"
rc=0
FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[]}' \
FAKE_CODEX_STDOUT='{"reviewed":true,"findings":[{"category":"bug","file":"a.ts","line":1,"what":"x","why":"y","failure_scenario":"s"}]}' \
  run_review || rc=$?
assert_eq "$rc" "0" "exit code"

it "回答は落とす指摘・stdout は指摘なしだと exit 1（-o を見落としていない）"
rc=0
FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[{"category":"bug","file":"a.ts","line":1,"what":"x","why":"y","failure_scenario":"s"}]}' \
FAKE_CODEX_STDOUT='{"reviewed":true,"findings":[]}' \
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
FAKE_CODEX_WRITE_ANSWER=first FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[]}' run_review --runs 2 || rc=$?
assert_eq "$rc" "1" "exit code"

# ---- 8. issue の文脈（枝の名前から番号を取り、scope / acceptance を載せる） ----

it "枝の名前の issue 番号から本文（acceptance 含む）を引いてプロンプトへ載せる"
git -C "$REPO" checkout -q -b feat/9999-selftest-context
rm -f "$RECORD/stdin"
rc=0
: > "$RECORD/fake.env"  # 直接呼ぶ回は既定の応答（run_review の切り替えを持ち越さない）
(
  cd "$REPO"
  PATH="$FAKE_BIN:$PATH" \
  FAKE_CODEX_RECORD="$RECORD" \
  FAKE_GH_RECORD="$RECORD/gh-calls" \
  FAKE_GH_ISSUE_BODY='# issue #9999 仕込みの票
scope.in:
  - 仕込みの目印 SELFTEST-ISSUE-MARKER' \
  FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[]}' \
    bash "$REVIEW" --engine codex > "$WORK/out" 2> "$WORK/err"
) || rc=$?
if [[ "$rc" -eq 0 ]] && grep -q 'SELFTEST-ISSUE-MARKER' "$RECORD/stdin" 2>/dev/null; then
  pass
else
  fail "exit=$rc、またはプロンプトに issue の本文が無い: $(cat "$WORK/err")"
fi
git -C "$REPO" checkout -q -

# ---- 9. 参照された issue / PR の文脈（差分の追加行・コミットメッセージの #N） ----

it "参照された issue の acceptance と、PR の状態をプロンプトへ載せる（上限・書き込み権の判定も守る）"
gh_dir="$WORK/gh"
mkdir -p "$gh_dir"
owner_url='https://api.github.com/repos/owner1/repo1'
cat > "$gh_dir/11.json" <<EOF
{"repository_url":"$owner_url","user":{"login":"owner1"},"author_association":"OWNER","state":"open","state_reason":null,"title":"コミットで名指しした票",
 "body":"## intake\n\n\`\`\`yaml\ngoal: g\nacceptance:\n  - REF-ACCEPTANCE-MARKER\npriority: 中\n\`\`\`\nREF-OUTSIDE-ACCEPTANCE-MARKER"}
EOF
cat > "$gh_dir/12.json" <<EOF
{"repository_url":"$owner_url","user":{"login":"member1"},"author_association":"MEMBER","state":"closed","title":"追加行の PR",
 "pull_request":{"merged_at":"2026-09-29T00:00:00Z"},"body":"acceptance:\n  - PRBODY-MARKER"}
EOF
cat > "$gh_dir/13.json" <<EOF
{"repository_url":"$owner_url","user":{"login":"owner1"},"author_association":"OWNER","state":"open","title":"REF-REMOVED-MARKER","body":""}
EOF
cat > "$gh_dir/14.json" <<EOF
{"repository_url":"$owner_url","user":{"login":"stranger"},"author_association":"NONE","state":"open","title":"REF-STRANGER-MARKER","body":"acceptance:\n  - REF-STRANGER-MARKER"}
EOF
cat > "$gh_dir/22.json" <<EOF
{"repository_url":"$owner_url","user":{"login":"owner1"},"author_association":"OWNER","state":"open","title":"REF-OVER-LIMIT-MARKER","body":""}
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
: > "$RECORD/fake.env"  # 直接呼ぶ回は既定の応答（run_review の切り替えを持ち越さない）
(
  cd "$REPO"
  PATH="$FAKE_BIN:$PATH" \
  FAKE_CODEX_RECORD="$RECORD" \
  FAKE_GH_RECORD="$RECORD/gh-calls" \
  FAKE_GH_DIR="$gh_dir" \
  FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[]}' \
    bash "$REVIEW" --engine codex --range 'HEAD~1..HEAD' > "$WORK/out" 2> "$WORK/err"
) || rc=$?

detail=""
[[ "$rc" -eq 0 ]] || detail="exit=$rc "
[[ -f "$RECORD/stdin" ]] || detail="${detail}codex が呼ばれていない "
if [[ -z "$detail" ]]; then
  grep -q 'REF-ACCEPTANCE-MARKER' "$RECORD/stdin" || detail="${detail}参照 issue の acceptance が無い "
  # 組織所有のリポジトリでは、作成者の login は持ち主（組織名）と一致しない。
  # author_association（MEMBER）で判定していれば載る。
  grep -q '#12（PR・merged）追加行の PR' "$RECORD/stdin" || detail="${detail}組織のメンバーが書いた PR が載っていない "
  grep -q 'REF-OUTSIDE-ACCEPTANCE-MARKER' "$RECORD/stdin" && detail="${detail}acceptance の外まで載っている "
  grep -q 'PRBODY-MARKER' "$RECORD/stdin" && detail="${detail}PR の本文が載っている "
  grep -q 'REF-REMOVED-MARKER' "$RECORD/stdin" && detail="${detail}削除行のみの参照が載っている "
  grep -q 'REF-STRANGER-MARKER' "$RECORD/stdin" && detail="${detail}書き込み権の無い人の参照が載っている "
  grep -q 'REF-OVER-LIMIT-MARKER' "$RECORD/stdin" && detail="${detail}上限超過の参照が載っている "
fi
if [[ -f "$RECORD/gh-calls" ]]; then
  grep -q 'issues/13$' "$RECORD/gh-calls" && detail="${detail}削除行のみの#13を引きに行っている "
  grep -q 'issues/22$' "$RECORD/gh-calls" && detail="${detail}上限超過の#22を引きに行っている "
fi

if [[ -z "$detail" ]]; then pass; else fail "$detail"; fi

it "上限超過・書き込み権の無い作成者・引けなかった旨が出力に出る"
if grep -q '上限 10 本を超えたため載せません: #22' "$WORK/out" \
  && grep -q '作成者がリポジトリへの書き込み権を持たないため載せません: #14' "$WORK/out" \
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

# **issue 番号を含む枝で回す。** 番号が無い枝では gh がそもそも呼ばれず、仕込んだ
# 失敗する gh が実行されないまま通ってしまう（検査が空振りする）。
git -C "$REPO" checkout -q -b feat/77-gh-fails
rm -f "$RECORD/stdin"
printf 'hello\nworld\nagain\n' > "$REPO/sample.txt"
git -C "$REPO" add sample.txt
rc=0
: > "$RECORD/fake.env"  # 直接呼ぶ回は既定の応答（run_review の切り替えを持ち越さない）
(
  cd "$REPO"
  PATH="$failing_gh_bin:$FAKE_BIN:$PATH" \
  FAKE_CODEX_RECORD="$RECORD" \
  FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[]}' \
    bash "$REVIEW" --engine codex > "$WORK/out" 2> "$WORK/err"
) || rc=$?
if [[ "$rc" -eq 0 ]] && [[ -f "$RECORD/stdin" ]] \
  && grep -q 'issue #77 を引けませんでした（文脈なしでレビューします）' "$WORK/err"; then
  pass
else
  fail "gh 失敗時の続行を確かめられない: exit=$rc, err: $(cat "$WORK/err")"
fi
git -C "$REPO" checkout -q -

# ---- 10. パッケージが配置したファイルの追加行は参照の抽出から外す（ORIGIN の hash:。owned: は外さない） ----

git -C "$REPO" checkout -q -b origin-selftest
printf 'x\n' > "$REPO/pkg.txt"
printf 'x\n' > "$REPO/plain.txt"
printf 'x\n' > "$REPO/both.txt"
printf 'x\n' > "$REPO/eq=path.txt"
printf 'x\n' > "$REPO/日本語.txt"
git -C "$REPO" add pkg.txt plain.txt both.txt eq=path.txt 日本語.txt
git -C "$REPO" commit -q -m "base of origin"
printf 'a #31\n' > "$REPO/pkg.txt"
printf 'a #32\n' > "$REPO/plain.txt"
printf 'a #33\n' > "$REPO/both.txt"
printf 'a #34\n' > "$REPO/eq=path.txt"
printf 'a #35\n' > "$REPO/日本語.txt"
git -C "$REPO" add pkg.txt plain.txt both.txt eq=path.txt 日本語.txt
git -C "$REPO" commit -q -m "ORIGIN の検査用の変更（#38）"

# 範囲のレビューを回し、引いた番号（gh-calls）を残す。出力は $WORK/out / $WORK/err。
run_origin_review() {
  rm -f "$RECORD/stdin" "$RECORD/gh-calls"
  : > "$RECORD/fake.env"
  (
    cd "$REPO" || exit 1
    PATH="$FAKE_BIN:$PATH" \
    FAKE_CODEX_RECORD="$RECORD" \
    FAKE_GH_RECORD="$RECORD/gh-calls" \
    FAKE_GH_DIR="$WORK/gh-none" \
    FAKE_CODEX_ANSWER='{"reviewed":true,"findings":[]}' \
      bash "$REVIEW" --engine codex --range 'HEAD~1..HEAD' > "$WORK/out" 2> "$WORK/err"
  )
  local rc=$?
  touch "$RECORD/gh-calls"
  return "$rc"
}
# 番号を引きに行ったか（issues/N の呼び出しがあれば 0）
called() { grep -q "issues/$1\$" "$RECORD/gh-calls"; }

mkdir -p "$REPO/.devcontainer" "$WORK/gh-none"
cat > "$REPO/.devcontainer/ORIGIN" <<'ORIGIN'
version=1
hash:pkg.txt=aaaa
hash:both.txt=bbbb
owned:both.txt=1
hash:eq=path.txt=cccc
hash:日本語.txt=dddd
hash:unrelated.txt=eeee
ORIGIN

it "ORIGIN の hash: のファイルの追加行は拾わず、記録の無いファイル・owned: のファイルは拾う"
rc=0; run_origin_review || rc=$?
detail=""
[[ "$rc" -eq 0 ]] || detail="exit=$rc "
called 31 && detail="${detail}hash: のファイルの #31 を引いている "
called 34 && detail="${detail}= を含む hash: のファイルの #34 を引いている "
called 32 || detail="${detail}記録の無いファイルの #32 を引いていない "
called 33 || detail="${detail}hash: と owned: のファイルの #33 を引いていない "
called 35 || detail="${detail}引用符付きの見出しのファイルの #35 を引いていない（外さずに拾うはず） "
called 38 || detail="${detail}コミットメッセージの #38 を引いていない "
if [[ -z "$detail" ]]; then pass; else fail "$detail"; fi

it "外したファイルがあるときは件数の行が出る"
if grep -q 'パッケージが配置したファイル 2 件の追加行は、参照の抽出から外しました' "$WORK/out"; then
  pass
else
  fail "件数の行が無い、または件数が違う。out: $(cat "$WORK/out")"
fi

it "ORIGIN が無いときは、すべての追加行とコミットメッセージから拾い、件数の行は出ない"
mv "$REPO/.devcontainer/ORIGIN" "$WORK/ORIGIN.saved"
rc=0; run_origin_review || rc=$?
detail=""
[[ "$rc" -eq 0 ]] || detail="exit=$rc "
for n in 31 32 33 34 35 38; do
  called "$n" || detail="${detail}#$n を引いていない "
done
grep -q 'の追加行は、参照の抽出から外しました' "$WORK/out" && detail="${detail}件数の行が出ている "
if [[ -z "$detail" ]]; then pass; else fail "$detail"; fi

it "ORIGIN があっても差分に該当ファイルが無ければ、件数の行は出ず、コミットメッセージの #N は拾う"
printf 'version=1\nhash:unrelated.txt=eeee\n' > "$REPO/.devcontainer/ORIGIN"
rc=0; run_origin_review || rc=$?
detail=""
[[ "$rc" -eq 0 ]] || detail="exit=$rc "
called 31 || detail="${detail}#31 を引いていない "
called 38 || detail="${detail}#38 を引いていない "
grep -q 'の追加行は、参照の抽出から外しました' "$WORK/out" && detail="${detail}件数の行が出ている "
if [[ -z "$detail" ]]; then pass; else fail "$detail"; fi
printf 'version=1\nhash:del.txt=ffff\nhash:pkg.txt=aaaa\n' > "$REPO/.devcontainer/ORIGIN"
printf 'one\ntwo\n' > "$REPO/del.txt"
git -C "$REPO" add del.txt
git -C "$REPO" commit -q -m "base of del"
printf 'one\n' > "$REPO/del.txt"
git -C "$REPO" add del.txt
git -C "$REPO" commit -q -m "削除だけの変更"

it "hash: のファイルの削除だけの差分では、件数の行が出ない"
rc=0; run_origin_review || rc=$?
detail=""
[[ "$rc" -eq 0 ]] || detail="exit=$rc "
grep -q 'の追加行は、参照の抽出から外しました' "$WORK/out" && detail="${detail}件数の行が出ている: $(cat "$WORK/out") "
if [[ -z "$detail" ]]; then pass; else fail "$detail"; fi

it "追加行のあるファイルと削除だけのファイルが混ざると、件数は追加行のあるファイルの数だけになる"
printf 'a #36\n' > "$REPO/pkg.txt"
printf 'one\ntwo\n' > "$REPO/del.txt"
git -C "$REPO" add del.txt pkg.txt
git -C "$REPO" commit -q -m "base of mixed"
printf 'one\n' > "$REPO/del.txt"
printf 'b #37\n' > "$REPO/pkg.txt"
git -C "$REPO" add del.txt pkg.txt
git -C "$REPO" commit -q -m "追加と削除の混在"
rc=0; run_origin_review || rc=$?
detail=""
[[ "$rc" -eq 0 ]] || detail="exit=$rc "
grep -q 'パッケージが配置したファイル 1 件の追加行は、参照の抽出から外しました' "$WORK/out" || detail="${detail}件数が 1 件でない: $(cat "$WORK/out") "
if [[ -z "$detail" ]]; then pass; else fail "$detail"; fi
rm -rf "$REPO/.devcontainer"
git -C "$REPO" checkout -q -

exit_with_result
