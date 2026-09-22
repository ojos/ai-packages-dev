#!/usr/bin/env bash
# 第二意見レビュー（規範パッケージの templates/second-opinion-review.sh）の判定を検証する。
#
# 背景:
#   このレビューは非決定的で、同じ差分でも実行のたびに結果が変わる。実際に同一
#   コミットへ 4 回実行して LGTM 2 回・指摘あり 2 回になった。1 回だけ実行して
#   LGTM を通過とみなす運用は見落としを通す。GEMINI_REVIEW_RUNS で回数を増やし、
#   過半数の run が指摘したときだけ落とす。
#
#   ここでは gemini CLI を PATH 上の stub へ差し替え、判定ロジックだけを決定的に
#   検証する。ネットワークにも API キーにも依存しない。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-second-opinion-review"

REVIEW="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/.ai-playbook/templates/second-opinion-review.sh"

LOADER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/load-project-env.sh"

# レビュー対象の差分を持つ一時リポジトリを作る。scripts/ の 1 階層上がルート。
mk_review_repo() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  cp "$REVIEW" "$dir/scripts/second-opinion-review.sh"
  (
    cd "$dir" && git init -q \
      && printf 'base\n' > a.txt && git add a.txt \
      && git -c user.name=T -c user.email=t@example.com commit -q -m c1 \
      && printf 'changed\n' > a.txt && git add a.txt
  ) >/dev/null 2>&1
}

# 指定した並びを 1 回ずつ返す stub を作る。
# 呼び出し回数はカウンタファイルで持ち、run ごとに異なる結果を返せるようにする。
#
#   L = LGTM のみ            D = 装飾された LGTM のみ（**LGTM**）
#   F = 指摘のみ             M = ファイル別講評（LGTM 行と致命バグが混在）
#   W = stderr へ警告 + LGTM  T = 指摘の末尾へ **LGTM** を添える
#   N = 前置き + VERDICT: LGTM        P = 前置き + 装飾された判定トークン + 空行
#   X = 前置き + 素の LGTM（判定トークン無し）
#   G = 指摘 + VERDICT: FINDINGS      Z = 否定形の判定トークン
#
# M / T は「通過を示す一意な出力」ではないが LGTM 行を含む形で、モデルが自然に
# 取る出力。行の存在で判定すると重大な指摘ごと通過する。
mk_gemini_stub() {
  mk_cli_stub "$1" gemini "$2"
}

# エンジンごとに CLI の名前が違うだけで、記録も応答も同じ形でよい。stub を 2 本
# 書き分けると、片方だけ古くなって「片側のエンジンでしか検証していない」状態が
# 見えなくなる。
mk_cli_stub() {
  local bindir="$1" cmd="$2" seq="$3"
  mkdir -p "$bindir"
  cat > "$bindir/$cmd" <<STUB
#!/usr/bin/env bash
# 受け取った引数と stdin を記録する。判定ロジックに加えて、差分をどう渡している
# かを検証できるようにする（差分本文が CLI の引数や stdin に載っていると、CLI が
# 本文中の @ をファイル参照として展開してしまう）。
printf '%s\n' "\$@" > "$bindir/.argv"
cat > "$bindir/.stdin" 2>/dev/null || true
# @<パス> で参照されているファイルがあれば、渡された中身をそのまま控える。
for __a in "\$@"; do
  case "\$__a" in
    @*)
      __f="\$(printf '%s' "\${__a#@}" | head -1)"
      [[ -f "\$__f" ]] && cp "\$__f" "$bindir/.injected"
      printf '%s' "\$__f" > "$bindir/.injected_path"
      ;;
  esac
done
n=\$(cat "$bindir/.count" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "$bindir/.count"
seq="$seq"
c="\${seq:\$((n - 1)):1}"
case "\$c" in
  L) echo "LGTM" ;;
  D) echo '**LGTM**' ;;
  W) echo "Warning: 256-color support not detected." >&2
     echo "Ripgrep is not available. Falling back to GrepTool." >&2
     echo "LGTM" ;;
  M) printf '%s\n' "### verify.sh" "LGTM" "" "### acceptance.sh" \
       "1. 致命バグ \$n: 配列展開が壊れている" ;;
  T) printf '%s\n' "1. 致命バグ \$n: 境界条件を見落としている" "**LGTM**" ;;
  N) printf '%s\n' \
       "I will run the \\\`run-tests.sh\\\` script filtering for the changed test to verify that it passes." \
       "VERDICT: LGTM" ;;
  P) printf '%s\n' \
       "テストの動作確認のため、テストスクリプトを実行し、期待どおりパスするか確認します。" \
       "**VERDICT: LGTM**" "" ;;
  X) printf '%s\n' \
       "I will execute the test runner to ensure that the test suite passes with these changes." \
       "LGTM" ;;
  G) printf '%s\n' "1. 致命バグ \$n: 配列展開が壊れている" "VERDICT: FINDINGS" ;;
  Z) printf '%s\n' "VERDICT: not LGTM" ;;
  *) echo "### 指摘 \$n: 何かがおかしい" ;;
esac
exit 0
STUB
  chmod +x "$bindir/$cmd"
  rm -f "$bindir/.count" "$bindir/.argv" "$bindir/.stdin" "$bindir/.injected" "$bindir/.injected_path"
}

# ── #303: バイト単位のチャンク分割 ────────────────────────────────────────────
#
# antigravity は差分を 1 つの -p 引数へ直接載せるため、Linux の MAX_ARG_STRLEN
# （1 引数あたりの固定上限。カーネル定数: PAGE_SIZE * 32）を超えられない。この
# 節のフィクスチャは、実装がスクリプト自身と同じ式で求めた上限を使って合成した
# 差分で、分割・失敗・バイト計測の実際の挙動を検証する。
#
# MAX_ARG_STRLEN は終端 NUL を含めて評価される（カーネル fs/exec.c の
# strnlen_user(str, MAX_ARG_STRLEN)）ため、実際に渡せるのはその 1 バイト少ない
# （実測: 131,070 / 131,071 バイトは通り、131,072 バイトから E2BIG）。
# 実装（second-opinion-review.sh）の max_arg_bytes と同じ式で -1 する。
#
# 上の mk_cli_stub は最新の呼び出ししか記録を残さないため（.argv を毎回上書き）、
# 複数チャンクをまたいだ検証には使えない。ここでは呼び出しごとに argv を
# 連番ファイル（.argv.<n>）へ残す専用の stub を使う。
MAX_ARG_BYTES=$(( $(getconf PAGE_SIZE 2>/dev/null || getconf PAGESIZE 2>/dev/null || echo 4096) * 32 - 1 ))

mk_agy_history_stub() {
  local bindir="$1" verdict="${2:-LGTM}"
  mkdir -p "$bindir"
  cat > "$bindir/agy" <<STUB
#!/usr/bin/env bash
n=\$(cat "$bindir/.count" 2>/dev/null || echo 0)
n=\$((n + 1))
echo "\$n" > "$bindir/.count"
printf '%s\n' "\$@" > "$bindir/.argv.\$n"
echo "$verdict"
exit 0
STUB
  chmod +x "$bindir/agy"
  rm -f "$bindir/.count" "$bindir"/.argv.*
}

# git diff の出力そのものを差し替える stub。実在の git では作れない入力
# （1 ファイルの diff がハンクを 1 つも持たないのに単体で上限を超える、等）を、
# second-opinion-review.sh 自体には手を入れずに再現するために使う。
# git diff 以外の呼び出しはすべて本物の git へ渡す（リポジトリの初期化・
# ステージ操作は mk_review_repo 相当の下ごしらえを本物の git で行うため）。
mk_git_diff_stub() {
  local bindir="$1" diff_file="$2" real_git
  real_git="$(command -v git)"
  mkdir -p "$bindir"
  cat > "$bindir/git" <<STUBGIT
#!/usr/bin/env bash
if [[ "\$1" == "diff" ]]; then
  cat "$diff_file"
  exit 0
fi
exec "$real_git" "\$@"
STUBGIT
  chmod +x "$bindir/git"
}

# 幅 100 バイト（改行込み 101 バイト）の ASCII 行を、およそ target_bytes バイト
# になるまで積む。固定のバイト数を書き下ろすと環境（PAGE_SIZE）が変わったときに
# 意図がずれるため、MAX_ARG_BYTES からの相対値で呼び出す。
append_ascii_padding() {
  local file="$1" target_bytes="$2" unit n i
  unit="0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
  n=$(( target_bytes / 100 ))
  [[ "$n" -lt 1 ]] && n=1
  i=0
  while [[ "$i" -lt "$n" ]]; do
    printf '%s\n' "$unit" >> "$file"
    i=$((i + 1))
  done
}

# antigravity へ渡る 1 チャンク分の引数（.argv.<n>）から、実際に -p へ渡された
# 「差分本文 + プロンプト」を取り出し、差分本文だけを返す。
#
# プロンプト文字列の先頭部分（"上記は git の差分です"）を境界にする。読みやすさを
# 優先した固定アンカーであり、プロンプトの文面を変えたときはここも追随させる
# 必要がある（本ファイルは second-opinion-review.sh と対で保守する）。
#
# 境界の直前の改行 1 個は "$chunk_text\n$PROMPT" の区切り文字であり、差分本文には
# 含めない。区切り文字の手前までが、分割器が生成したチャンクの中身そのもの。
extract_chunk_diff() {
  local argv_file="$1" content marker
  content="$(cat "$argv_file")"
  content="${content#-p$'\n'}"
  marker=$'\n上記は git の差分です'
  printf '%s' "${content%%"$marker"*}"
}

# second-opinion-review.sh 自身の PROMPT が何バイトかを、実装のヒアドキュメントを
# 読み込んで求める。値をこのファイルへ複製すると、プロンプトの文面を変えたときに
# 乖離したまま気づけない。
#
# 実装は `read -r -d '' PROMPT <<'EOF' ... EOF`（IFS を空にしていない）でヒアドキュメント
# 本文を読む。IFS が既定のままだと、read は単一変数への読み込みで前後の IFS
# 空白（改行を含む）を落とす。ここも `read` そのものへ通すことで、その削ぎ落としを
# 複製せず実装と同じ結果を得る（awk/sed で真似ると挙動がずれる余地がある）。
script_prompt_bytes() {
  local review_file="$1" body_file prompt
  body_file="$(new_workdir)/prompt-body.txt"
  sed -n "/^read -r -d '' PROMPT <<'EOF' || true\$/,/^EOF\$/p" "$review_file" \
    | sed '1d;$d' > "$body_file"
  read -r -d '' prompt < "$body_file" || true
  LC_ALL=C printf '%s' "$prompt" | wc -c
}

# @ を含む差分をステージする。メールアドレス・シェルの配列展開・パターンの 3 形。
# いずれも CLI がファイル参照として展開しうる形で、実際のコードに日常的に現れる。
stage_at_diff() {
  local dir="$1"
  (
    cd "$dir" \
      && printf '%s\n' \
           'ALLOWED=("${ARR[@]}" "noreply@github.com")' \
           '[[ "$n" == *@* ]] && return 0' > at.sh \
      && git add at.sh
  ) >/dev/null 2>&1
}

run_review() {
  local dir="$1" bindir="$2"
  shift 2
  ( cd "$dir" && PATH="$bindir:$PATH" GEMINI_API_KEY=dummy bash scripts/second-opinion-review.sh "$@" 2>&1 )
}

# ── 既定（1 回）は従来と同じ挙動 ──────────────────────────────────────────────
it "既定は 1 回実行。LGTM なら exit 0"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "L"
out="$(run_review "$d" "$b")"; rc=$?
if [[ "$rc" -eq 0 ]]; then assert_contains "$out" "LGTM" "既定 1 回の出力"; else fail "LGTM なのに exit $rc: $out"; fi

it "既定は 1 回実行。指摘ありなら exit 1"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "F"
out="$(run_review "$d" "$b")"; rc=$?
if [[ "$rc" -eq 1 ]]; then assert_contains "$out" "findings reported" "既定 1 回の出力"; else fail "指摘ありなのに exit $rc: $out"; fi

it "既定では gemini を 1 回しか呼ばない"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "LL"
run_review "$d" "$b" >/dev/null
assert_eq "$(cat "$b/.count")" "1" "既定の呼び出し回数"

# ── 通過判定は出力全体の一意性で見る ──────────────────────────────────────────
#
# 規範（review-workflow.md）が第二意見へ求めているのは「通過を示す一意な出力」で
# あって「一意な出力を含むこと」ではない。LGTM 行の存在で判定すると、重大な指摘が
# 同時に出ていても通過する。ローカル事前ゲートは push 前の最後の機械判定なので、
# ここで偽の緑を出すと指摘がそのまま通る。

it "ファイル別の講評に LGTM 行が混ざる出力を通過させない"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "M"
out="$(run_review "$d" "$b")"; rc=$?
if [[ "$rc" -eq 1 ]]; then
  assert_contains "$out" "致命バグ" "混在出力の内容"
else
  fail "致命バグを含む出力を通した (exit $rc): $out"
fi

it "指摘の末尾へ **LGTM** を添えた出力を通過させない"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "T"
out="$(run_review "$d" "$b")"; rc=$?
if [[ "$rc" -eq 1 ]]; then
  assert_contains "$out" "致命バグ" "混在出力の内容"
else
  fail "致命バグを含む出力を通した (exit $rc): $out"
fi

it "装飾された LGTM のみは通過する"
# 判定を厳しくした結果 **LGTM** や LGTM. まで落とすと、ゲートが常に赤くなって
# 無視されるようになる。装飾の除去は残す。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "D"
out="$(run_review "$d" "$b")"; rc=$?
if [[ "$rc" -eq 0 ]]; then
  assert_contains "$out" "run 1/1: LGTM" "装飾された LGTM の判定"
else
  fail "装飾された LGTM を落とした (exit $rc): $out"
fi

# ── 前置き（作業ナレーション）で偽の赤を出さない ──────────────────────────────
#
# モデルは回答の前に「これから何をするか」を述べることがある。出力全体の一意性で
# 判定していた頃は、これが出た瞬間に「指摘あり」へ化けた。実測では 3 run すべてが
# この形で落ち、指摘は 1 件も無かった。ナレーションは同じ差分なら毎回同じように
# 出るため、run 数を増やしても消えない。偽の赤が定常化するとゲートが読まれなくなる。
#
# 判定は「出力の最後の行に置かれた判定トークン」で行う。前置きの有無で判定が
# 変わらず、かつ指摘と併記された LGTM では通過しない形にする。

it "前置きが付いていても判定トークンがあれば通過する"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "N"
out="$(run_review "$d" "$b")"; rc=$?
if [[ "$rc" -eq 0 ]]; then
  assert_contains "$out" "run 1/1: LGTM" "前置き付き判定トークンの判定"
else
  fail "前置きだけで落とした (exit $rc): $out"
fi

it "判定トークンが装飾されていても、後ろに空行が続いても通過する"
# 判定を厳しくした結果 **VERDICT: LGTM** まで落とすと、ゲートが常に赤くなって
# 無視されるようになる。装飾の除去と末尾空行の切り落としは残す。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "P"
out="$(run_review "$d" "$b")"; rc=$?
if [[ "$rc" -eq 0 ]]; then
  assert_contains "$out" "run 1/1: LGTM" "装飾された判定トークンの判定"
else
  fail "装飾された判定トークンを落とした (exit $rc): $out"
fi

it "3 run すべてが前置きを出しても通過する"
# #267 の実測がこの形。回数を増やす対策は、ぶれが run ごとに独立して現れる場合に
# しか効かない。毎回同じように崩れる出力は多数決では救えない。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "NPN"
out="$(run_review "$d" "$b" --runs 3)"; rc=$?
if [[ "$rc" -eq 0 ]]; then
  assert_contains "$out" "0/3 runs reported findings" "3 run の集計"
else
  fail "前置きだけで 3 run とも落とした (exit $rc): $out"
fi

it "判定トークンの無い出力は通さず、理由を示す"
# 指示に従わなかった出力を通すと、判定していないものを緑として報告することになる。
# 一方、指摘本文だけを出して赤にすると、なぜ落ちたのかが読み取れない。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "X"
out="$(run_review "$d" "$b")"; rc=$?
if [[ "$rc" -eq 1 ]]; then
  assert_contains "$out" "判定トークンが見つかりません" "判定トークン欠落時の診断"
else
  fail "判定トークンの無い出力を通した (exit $rc): $out"
fi

it "判定トークンが FINDINGS の出力は落とす"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "G"
out="$(run_review "$d" "$b")"; rc=$?
if [[ "$rc" -eq 1 ]]; then
  assert_contains "$out" "致命バグ" "FINDINGS の出力内容"
else
  fail "FINDINGS を通した (exit $rc): $out"
fi

it "否定形の判定トークンを通過させない"
# 部分一致へ緩めると `VERDICT: not LGTM` の類まで通過する。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "Z"
out="$(run_review "$d" "$b")"; rc=$?
if [[ "$rc" -eq 1 ]]; then pass; else fail "否定形を通した (exit $rc): $out"; fi

it "CLI が stderr へ出す警告を判定へ混ぜない"
# 警告を出力へ混ぜると、LGTM 一意の回答が「LGTM 以外も含む」に化けて、
# ゲートが常に赤くなる。判定はモデルの回答（stdout）だけで行う。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "W"
out="$(run_review "$d" "$b")"; rc=$?
if [[ "$rc" -eq 0 ]]; then
  assert_contains "$out" "run 1/1: LGTM" "警告付き LGTM の判定"
else
  fail "警告を判定へ混ぜて落とした (exit $rc): $out"
fi

# ── 差分は CLI の解釈対象へ載せない ───────────────────────────────────────────
#
# 差分本文を stdin や -p へ混ぜると、gemini CLI が本文中の @ をファイル参照として
# 展開し、モデルには壊れたテキストが渡る。実測では `noreply@github.com` が
# `noreply @github.com` に、`*@*` の `@*` がリポジトリ内の実在パスに化けた。モデルは
# 壊れた側を読み、実在しない誤りを致命バグとして報告する。同じ差分なら同じ化け方を
# するため、多数決でも落とせない。一時ファイルへ書いて @<パス> で参照させる。

it "差分本文を CLI の引数にも標準入力にも載せない"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "L"
stage_at_diff "$d"
run_review "$d" "$b" >/dev/null
argv="$(cat "$b/.argv" 2>/dev/null || true)"
stdin_seen="$(cat "$b/.stdin" 2>/dev/null || true)"
bad=0
case "$argv" in *'noreply@github.com'*) echo "  差分本文が引数に載っている"; bad=1 ;; esac
case "$stdin_seen" in *'noreply@github.com'*) echo "  差分本文が標準入力に載っている"; bad=1 ;; esac
if [[ "$bad" -eq 0 ]]; then pass; else fail "差分が CLI の解釈対象になっている"; fi

it "差分はファイル参照で渡し、中身は加工せず素通しする"
# 参照させるファイルの中身が差分と 1 文字でも違うと、モデルは違う差分をレビューする。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "L"
stage_at_diff "$d"
run_review "$d" "$b" >/dev/null
if [[ -f "$b/.injected" ]]; then
  expected="$( cd "$d" && git diff --cached )"
  assert_eq "$(cat "$b/.injected")" "$expected" "参照させた差分の中身"
else
  fail "@<パス> によるファイル参照が引数に無い"
fi

it "一時ディレクトリを workspace へ加えている"
# 加えないと CLI は参照先を読めず、応答を返さないまま止まる（実測）。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "L"
stage_at_diff "$d"
run_review "$d" "$b" >/dev/null
argv="$(cat "$b/.argv" 2>/dev/null || true)"
inc_dir="$(printf '%s\n' "$argv" | grep -A1 -- '--include-directories' | tail -1)"
ref_path="$(cat "$b/.injected_path" 2>/dev/null || true)"
if [[ -n "$inc_dir" && -n "$ref_path" && "$ref_path" == "$inc_dir"/* ]]; then
  pass
else
  fail "参照先 '$ref_path' が --include-directories '$inc_dir' の配下にない"
fi

it "レビュー後に差分の一時ファイルを残さない"
# 差分がプロセス終了後も一時領域に残ると、機密を含む差分がそのまま溜まる。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "L"
stage_at_diff "$d"
run_review "$d" "$b" >/dev/null
ref_path="$(cat "$b/.injected_path" 2>/dev/null || true)"
if [[ -n "$ref_path" && ! -e "$ref_path" && ! -d "$(dirname "$ref_path")" ]]; then
  pass
else
  fail "一時ファイルが残っている: $ref_path"
fi

# ── 多数決 ────────────────────────────────────────────────────────────────────
it "N=3 で指摘が 1 回だけなら通過する（閾値 2）"
# 誤検出 1 回でゲートが止まると、毎回反証が必要になりゲート自体が無視される。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "LFL"
out="$(run_review "$d" "$b" --runs 3)"; rc=$?
if [[ "$rc" -eq 0 ]]; then assert_contains "$out" "1/3 runs reported findings" "多数決の内訳"; else fail "1/3 で落ちた (exit $rc): $out"; fi

it "N=3 で指摘が 2 回なら落ちる（閾値 2）"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "FLF"
out="$(run_review "$d" "$b" --runs 3)"; rc=$?
if [[ "$rc" -eq 1 ]]; then assert_contains "$out" "findings reported by 2/3 runs" "多数決の内訳"; else fail "2/3 で通した (exit $rc): $out"; fi

it "N=2 は 2 回とも指摘したときだけ落ちる（閾値 2）"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "FL"
run_review "$d" "$b" --runs 2 >/dev/null; rc=$?
if [[ "$rc" -ne 0 ]]; then fail "1/2 で落ちた (exit $rc)"; else
  d2="$(new_workdir)/r2"; b2="$(new_workdir)/bin2"
  mk_review_repo "$d2"; mk_gemini_stub "$b2" "FF"
  run_review "$d2" "$b2" --runs 2 >/dev/null; rc2=$?
  if [[ "$rc2" -eq 1 ]]; then pass; else fail "2/2 で通した (exit $rc2)"; fi
fi

it "過半数に届かない指摘も出力に残る"
# 集約結果だけを出すと、確認すべき指摘が消える。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "LFL"
out="$(run_review "$d" "$b" --runs 3)"
if printf '%s' "$out" | grep -q '指摘 2' && printf '%s' "$out" | grep -q 'run 2/3: findings'; then
  pass
else
  fail "少数意見が出力から消えている: $out"
fi

it "GEMINI_REVIEW_RUNS 環境変数でも回数を指定できる"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "LLL"
( cd "$d" && PATH="$b:$PATH" GEMINI_API_KEY=dummy GEMINI_REVIEW_RUNS=3 bash scripts/second-opinion-review.sh ) >/dev/null 2>&1
assert_eq "$(cat "$b/.count")" "3" "環境変数での呼び出し回数"

# ── 不正な回数は fail-closed ──────────────────────────────────────────────────
it "runs が 0 / 負数 / 非数値なら実行前に停止する"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "LLL"
bad=0
for v in 0 -1 abc 1.5; do
  err="$( ( cd "$d" && PATH="$b:$PATH" GEMINI_API_KEY=dummy bash scripts/second-opinion-review.sh --runs "$v" ) 2>&1 >/dev/null )"
  rc=$?
  [[ "$rc" -eq 1 ]] || { echo "  runs=$v で停止しなかった (exit $rc)"; bad=1; }
  # 「--runs を知らないので unknown option で落ちた」を通過扱いにしない。
  # 理由まで見ないと、オプション未実装のまま検査が緑になる。
  printf '%s' "$err" | grep -q 'runs は 1 以上の整数' \
    || { echo "  runs=$v が runs の検査で落ちていない: $err"; bad=1; }
done
# 黙って既定へ落とすと、増やしたつもりのゲートが効いていない状態になる。
# 一度も gemini を呼んでいないことも確認する。
[[ -f "$b/.count" ]] && { echo "  不正値なのに gemini を呼んだ"; bad=1; }
if [[ "$bad" -eq 0 ]]; then pass; else fail "不正な runs が fail-closed になっていない"; fi

it "ゼロパディングされた回数を 8 進数として解釈しない"
# bash の算術評価は先頭 0 を 8 進数として扱う。基数を固定しないと、
# 08 / 09 は比較自体がエラーになって検証をすり抜け、010 は 8 と解釈されて
# 「10 回のつもりが 8 回」になる。どちらもゲートが静かに効かなくなる。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "LLLLLLLLLL"
out="$(run_review "$d" "$b" --runs 010)"; rc=$?
n="$(cat "$b/.count" 2>/dev/null || echo 0)"
if [[ "$rc" -eq 0 && "$n" -eq 10 ]]; then
  # 08 は「8 進数として無効」でエラーにならず、10 進の 8 として通ること
  d2="$(new_workdir)/r2"; b2="$(new_workdir)/bin2"
  mk_review_repo "$d2"; mk_gemini_stub "$b2" "LLLLLLLL"
  err="$(run_review "$d2" "$b2" --runs 08 2>&1 >/dev/null)"; rc2=$?
  n2="$(cat "$b2/.count" 2>/dev/null || echo 0)"
  if [[ "$rc2" -eq 0 && "$n2" -eq 8 ]] && ! printf '%s' "$err" | grep -q 'value too great for base'; then
    pass
  else
    fail "runs=08 が壊れている (exit $rc2 / 呼び出し $n2 回): $err"
  fi
else
  fail "runs=010 が 10 回として扱われていない (exit $rc / 呼び出し $n 回): $out"
fi

it "プロジェクト .env の GEMINI_REVIEW_RUNS が効く"
# .env の読み込みが既定値の解決より後にあると、設定したつもりで効かない。
# 検証もすり抜けるため、不正な値がそのまま走ることになる。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "LLL"
cp "$LOADER" "$d/scripts/load-project-env.sh"
printf 'GEMINI_API_KEY=from-env\nGEMINI_REVIEW_RUNS=3\n' > "$d/.env"
out="$( cd "$d" && PATH="$b:$PATH" bash scripts/second-opinion-review.sh 2>&1 )"; rc=$?
n="$(cat "$b/.count" 2>/dev/null || echo 0)"
if [[ "$rc" -eq 0 && "$n" -eq 3 ]]; then
  assert_contains "$out" "runs=3" ".env からの解決"
else
  fail ".env の GEMINI_REVIEW_RUNS が効いていない (exit $rc / 呼び出し $n 回): $out"
fi

it "CLI 引数は .env より優先される"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "LLL"
cp "$LOADER" "$d/scripts/load-project-env.sh"
printf 'GEMINI_API_KEY=from-env\nGEMINI_REVIEW_RUNS=3\n' > "$d/.env"
( cd "$d" && PATH="$b:$PATH" bash scripts/second-opinion-review.sh --runs 1 ) >/dev/null 2>&1
assert_eq "$(cat "$b/.count" 2>/dev/null || echo 0)" "1" "CLI 引数の優先"

it "値を伴わないオプションは unbound variable ではなく使い方を出して停止する"
# set -u 下で $2 を直接読むと、何が足りないかを言わずに落ちる。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "L"
bad=0
for opt in --runs --range --model --engine; do
  err="$( ( cd "$d" && PATH="$b:$PATH" GEMINI_API_KEY=dummy bash scripts/second-opinion-review.sh "$opt" ) 2>&1 >/dev/null )"
  rc=$?
  [[ "$rc" -eq 1 ]] || { echo "  $opt で exit 1 にならない (exit $rc)"; bad=1; }
  printf '%s' "$err" | grep -q 'には値が必要です' \
    || { echo "  $opt が値不足として扱われていない: $err"; bad=1; }
  printf '%s' "$err" | grep -q 'unbound variable' \
    && { echo "  $opt で unbound variable が出ている: $err"; bad=1; }
done
if [[ "$bad" -eq 0 ]]; then pass; else fail "値なしオプションの扱いが不十分"; fi

# ── エンジンの選択 ────────────────────────────────────────────────────────────
#
# 認証手段の違う 2 つの CLI から選べる。判定ロジックは 1 か所に集約してあり、
# エンジンごとに複製していない（複製すると判定の修正が片側にしか効かなくなる）。
# ここで確かめるのは「どちらのエンジンでも同じ判定へ入ること」と、「エンジンの
# 取り違え・不在が CLI を呼ぶ前に、取り違えだと分かる形で止まること」。
#
# PATH は stub と最小限のシステムパスだけにする。実行者の環境に本物の gemini /
# agy が入っていると、「CLI が無いとき」の検証が本物を拾って成立しない。
MIN_PATH="/usr/bin:/bin"

it "既定のエンジンは gemini（gemini 不在なら gemini の導入案内で停止する）"
# 既定が入れ替わっていないことを、CLI を実行せずに判別する。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mkdir -p "$b"
err="$( ( cd "$d" && PATH="$b:$MIN_PATH" GEMINI_API_KEY=dummy bash scripts/second-opinion-review.sh ) 2>&1 >/dev/null )"
rc=$?
if [[ "$rc" -eq 1 ]]; then
  assert_contains "$err" "gemini CLI not found" "既定エンジンの不在メッセージ"
else
  fail "gemini 不在で停止しなかった (exit $rc): $err"
fi

it "--engine antigravity で agy 不在なら agy の導入案内で停止する"
# gemini 側のメッセージに化けると、入れるべき CLI を取り違える。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "L"
err="$( ( cd "$d" && PATH="$b:$MIN_PATH" bash scripts/second-opinion-review.sh --engine antigravity ) 2>&1 >/dev/null )"
rc=$?
bad=0
[[ "$rc" -eq 1 ]] || { echo "  exit 1 にならない (exit $rc)"; bad=1; }
printf '%s' "$err" | grep -q 'agy' || { echo "  agy の案内が出ていない: $err"; bad=1; }
printf '%s' "$err" | grep -q 'gemini CLI not found' && { echo "  gemini 側のメッセージに化けている: $err"; bad=1; }
[[ -f "$b/.count" ]] && { echo "  agy 不在なのに gemini を呼んだ"; bad=1; }
if [[ "$bad" -eq 0 ]]; then pass; else fail "agy 不在の扱いが誤っている"; fi

it "未知のエンジンは CLI を呼ぶ前に停止する"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "L"
err="$( ( cd "$d" && PATH="$b:$MIN_PATH" GEMINI_API_KEY=dummy bash scripts/second-opinion-review.sh --engine gemni ) 2>&1 >/dev/null )"
rc=$?
bad=0
[[ "$rc" -eq 1 ]] || { echo "  exit 1 にならない (exit $rc)"; bad=1; }
printf '%s' "$err" | grep -q 'unknown engine' || { echo "  綴り間違いだと分かる形で落ちていない: $err"; bad=1; }
[[ -f "$b/.count" ]] && { echo "  未知のエンジンなのに CLI を呼んだ"; bad=1; }
if [[ "$bad" -eq 0 ]]; then pass; else fail "未知のエンジンが fail-closed になっていない"; fi

it "--engine antigravity は agy を呼び、判定は共通ロジックを通る"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_cli_stub "$b" agy "N"
out="$( cd "$d" && PATH="$b:$MIN_PATH" bash scripts/second-opinion-review.sh --engine antigravity 2>&1 )"; rc=$?
bad=0
[[ "$rc" -eq 0 ]] || { echo "  判定トークン付きなのに落ちた (exit $rc): $out"; bad=1; }
[[ "$(cat "$b/.count" 2>/dev/null || echo 0)" == "1" ]] || { echo "  agy を 1 回呼んでいない"; bad=1; }
printf '%s' "$out" | grep -q 'engine=antigravity' || { echo "  どのエンジンで実行したかが出ていない: $out"; bad=1; }
if [[ "$bad" -eq 0 ]]; then pass; else fail "antigravity 経路が成立していない"; fi

it "--engine antigravity は API キーを要求しない"
# agy は OAuth のみで API キーに対応しない。gemini 側の前提検査を流用すると、
# 鍵を持たない利用者がこのエンジンを選べなくなる。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_cli_stub "$b" agy "L"
out="$( cd "$d" && PATH="$b:$MIN_PATH" bash scripts/second-opinion-review.sh --engine antigravity 2>&1 )"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass; else fail "API キー無しで落ちた (exit $rc): $out"; fi

it "antigravity では差分をプロンプトへ直接載せる"
# agy は @<パス> をファイル参照として展開せず、print モードで stdin も読まない
# （実測）。gemini 側の「一時ファイル + @ 参照」を流用すると、モデルは差分を
# 見ないまま「差分が空だ」と答える。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_cli_stub "$b" agy "L"
stage_at_diff "$d"
( cd "$d" && PATH="$b:$MIN_PATH" bash scripts/second-opinion-review.sh --engine antigravity ) >/dev/null 2>&1
argv="$(cat "$b/.argv" 2>/dev/null || true)"
bad=0
case "$argv" in *'noreply@github.com'*) ;; *) echo "  差分本文が引数に載っていない"; bad=1 ;; esac
case "$argv" in *'@'*'/review.diff'*) echo "  agy へ @<パス> 参照を渡している"; bad=1 ;; esac
if [[ "$bad" -eq 0 ]]; then pass; else fail "antigravity への差分の渡し方が誤っている: $argv"; fi

it "SECOND_OPINION_ENGINE 環境変数でもエンジンを切り替えられる"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_cli_stub "$b" agy "L"
out="$( cd "$d" && PATH="$b:$MIN_PATH" SECOND_OPINION_ENGINE=antigravity bash scripts/second-opinion-review.sh 2>&1 )"; rc=$?
if [[ "$rc" -eq 0 ]]; then
  assert_contains "$out" "engine=antigravity" "環境変数でのエンジン指定"
else
  fail "環境変数でエンジンを切り替えられない (exit $rc): $out"
fi

# ── 環境変数の新旧 ────────────────────────────────────────────────────────────

it "SECOND_OPINION_RUNS で回数を指定できる"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "LLL"
( cd "$d" && PATH="$b:$PATH" GEMINI_API_KEY=dummy SECOND_OPINION_RUNS=3 bash scripts/second-opinion-review.sh ) >/dev/null 2>&1
assert_eq "$(cat "$b/.count")" "3" "新名での呼び出し回数"

it "新名が設定されていれば旧名より優先される"
# 両方が残った .env で、どちらが効くかが読めないと移行の判断ができない。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "LLL"
( cd "$d" && PATH="$b:$PATH" GEMINI_API_KEY=dummy GEMINI_REVIEW_RUNS=3 SECOND_OPINION_RUNS=2 bash scripts/second-opinion-review.sh ) >/dev/null 2>&1
assert_eq "$(cat "$b/.count")" "2" "新名優先の呼び出し回数"

# ── #303: バイト単位のチャンク分割 ────────────────────────────────────────────
#
# antigravity は差分を 1 つの -p 引数へ直接載せるため、Linux の MAX_ARG_STRLEN
# （1 引数あたりの固定上限）を超えられない。ここでは実装が実際に踏む分割・
# 失敗・バイト計測の経路を、MAX_ARG_BYTES を基準に合成した入力で検証する。

it "対照群: 上限以下の差分は antigravity でも分割が起きず、ログ表示が従来どおりである"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_agy_history_stub "$b" "LGTM"
out="$( cd "$d" && PATH="$b:/usr/bin:/bin" bash scripts/second-opinion-review.sh --engine antigravity --runs 1 2>&1 )"; rc=$?
bad=0
[[ "$rc" -eq 0 ]] || { echo "  exit $rc: $out"; bad=1; }
[[ "$(cat "$b/.count" 2>/dev/null || echo 0)" == "1" ]] || { echo "  呼び出し回数が 1 でない"; bad=1; }
case "$out" in *"chunk "*) echo "  分割が起きていないのに chunk 表記が出ている: $out"; bad=1 ;; esac
printf '%s' "$out" | grep -q 'run 1/1: LGTM' || { echo "  従来の判定表記が無い: $out"; bad=1; }
if [[ "$bad" -eq 0 ]]; then pass; else fail "対照群の表示が分割導入前と変わっている"; fi

it "境界: ちょうど budget に達するチャンクでも、実際に渡す引数は MAX_ARG_BYTES 以下に収まる"
# MAX_ARG_STRLEN は終端 NUL を含めて評価される（カーネル fs/exec.c の
# strnlen_user(str, MAX_ARG_STRLEN)）。ページサイズ * 32 をそのまま「渡せる
# 最大」として使うと、diff がちょうど budget に達したとき、実際に渡す引数
# （diff + 改行 1 + プロンプト）の合計がページサイズ * 32 ちょうどになり、
# 1 バイト超過して E2BIG になる（実測: 131,070 / 131,071 は通り、131,072 から
# Argument list too long）。ここでは diff の大きさを budget ちょうどに直接
# 組み立て、境界そのものを踏んだうえで安全側に収まることを確かめる。
#
# git 経由だと 1 行あたりの "+" 接頭辞やハンク見出しの桁数でバイト数が読み
# にくくなるため、mk_git_diff_stub で crafted diff を厳密なバイト数に合わせる。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; g="$(new_workdir)/gitstub"
mk_review_repo "$d"
prompt_bytes="$(script_prompt_bytes "$REVIEW")"
chunk_budget=$(( MAX_ARG_BYTES - prompt_bytes - 1 ))

header=$'diff --git a/boundary.txt b/boundary.txt\nindex 0000000..1111111 100644\n--- a/boundary.txt\n+++ b/boundary.txt\n@@ -0,0 +1,1 @@\n+'
header_bytes="$(LC_ALL=C printf '%s' "$header" | wc -c)"
# second-opinion-review.sh は `diff_text="$(git diff ...)"` で読む。コマンド
# 置換は末尾改行をすべて落とすため、ここで作る crafted diff は「本文の末尾に
# 改行 1 個」を余分に持たせる（そうしないと $() で 1 バイト短くなり、
# budget ちょうどを踏めない）。
fill_bytes=$(( chunk_budget - header_bytes ))
crafted="$(new_workdir)/boundary.diff"
printf '%s' "$header" > "$crafted"
head -c "$fill_bytes" /dev/zero | tr '\0' 'X' >> "$crafted"
printf '\n' >> "$crafted"

bad=0
# script が実際に読む形（コマンド置換で末尾改行を落とした後）のバイト数で確かめる。
effective_diff_bytes="$(LC_ALL=C printf '%s' "$(cat "$crafted")" | wc -c)"
if [[ "$effective_diff_bytes" -ne "$chunk_budget" ]]; then
  echo "  フィクスチャが budget ちょうどに合っていない（effective_diff_bytes=$effective_diff_bytes chunk_budget=$chunk_budget）"
  bad=1
fi

mk_git_diff_stub "$g" "$crafted"
mk_agy_history_stub "$b" "LGTM"
out="$( cd "$d" && PATH="$g:$b:/usr/bin:/bin" bash scripts/second-opinion-review.sh --engine antigravity --runs 1 2>&1 )"; rc=$?
[[ "$rc" -eq 0 ]] || { echo "  exit $rc: $out"; bad=1; }
chunk_count="$(cat "$b/.count" 2>/dev/null || echo 0)"
if [[ "$chunk_count" -ne 1 ]]; then
  echo "  budget ちょうどのはずが分割された（chunk_count=$chunk_count）。境界のフィクスチャが崩れている"
  bad=1
fi
if [[ "$chunk_count" -eq 1 ]]; then
  combined_bytes=$(( $(wc -c < "$b/.argv.1") - 4 ))
  if [[ "$combined_bytes" -ne "$MAX_ARG_BYTES" ]]; then
    echo "  境界に達していない（combined_bytes=$combined_bytes, 期待値=$MAX_ARG_BYTES）"
    bad=1
  fi
  if [[ "$combined_bytes" -gt "$MAX_ARG_BYTES" ]]; then
    echo "  実際に渡す引数が上限を超えている: $combined_bytes > $MAX_ARG_BYTES"
    bad=1
  fi
fi
if [[ "$bad" -eq 0 ]]; then pass; else fail "境界のバイト数計算が壊れている"; fi

it "上限を大きく超える合成差分: 各チャンクが上限以下に収まり、連結すると元の差分と一致する"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"
# どのファイルも単体では上限に収まる大きさに抑える。ファイル単位の詰め合わせ
# だけで分割される（ハンク単位へは落ちない）ことを保証するため。
n_files=10
per_file_bytes=$(( MAX_ARG_BYTES * 3 / 10 ))
i=1
while [[ "$i" -le "$n_files" ]]; do
  : > "$d/f$i.txt"
  append_ascii_padding "$d/f$i.txt" "$per_file_bytes"
  i=$((i + 1))
done
( cd "$d" && git add f*.txt )
expected="$(cd "$d" && git diff --cached)"
mk_agy_history_stub "$b" "LGTM"
out="$( cd "$d" && PATH="$b:/usr/bin:/bin" bash scripts/second-opinion-review.sh --engine antigravity --runs 1 2>&1 )"; rc=$?
bad=0
[[ "$rc" -eq 0 ]] || { echo "  exit $rc: $out"; bad=1; }
chunk_count="$(cat "$b/.count" 2>/dev/null || echo 0)"
[[ "$chunk_count" -gt 1 ]] || { echo "  分割が起きていない（chunk_count=$chunk_count）"; bad=1; }
recon_file="$(new_workdir)/recon.diff"
: > "$recon_file"
i=1
while [[ "$i" -le "$chunk_count" ]]; do
  # argv ファイルは "-p\n<本文>\n" の形。本文の実バイト数は、記録ファイルの
  # バイト数から "-p\n"（3 バイト）と printf が末尾へ足す改行（1 バイト）を
  # 引いたもの。これが実際に CLI へ渡る 1 引数のバイト数そのもの。
  argv_bytes="$(wc -c < "$b/.argv.$i")"
  combined_bytes=$((argv_bytes - 4))
  if [[ "$combined_bytes" -gt "$MAX_ARG_BYTES" ]]; then
    echo "  chunk $i の引数が上限を超えている: $combined_bytes > $MAX_ARG_BYTES"
    bad=1
  fi
  # ファイルへ追記する。コマンド置換 $(...) で文字列連結すると、チャンクごとの
  # 末尾改行がそのたびに落ちてチャンク境界が消える（実測）。
  extract_chunk_diff "$b/.argv.$i" >> "$recon_file"
  i=$((i + 1))
done
reconstructed="$(cat "$recon_file")"
if [[ "$reconstructed" != "$expected" ]]; then
  echo "  全チャンクを連結しても元の差分と一致しない（欠落または重複がある）"
  bad=1
fi
if [[ "$bad" -eq 0 ]]; then pass; else fail "合成差分のチャンク分割が壊れている"; fi

it "1 ファイルの差分だけで上限を超える入力は、ハンク単位へ落ち、各チャンクがファイルヘッダを持つ"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"
# 変更点を離れた場所へ散らし、それぞれが独立したハンクになるようにする。
# 1 ハンクは単体で上限に収まる大きさに抑え、ハンク数×サイズで合計だけが
# 上限を超えるようにする（「1 ハンクで上限超過」の別ケースと区別するため）。
blocks=30
lines_per_block=20
hunk_pad_bytes=$(( MAX_ARG_BYTES / 20 ))
: > "$d/big.txt"
b_i=1
while [[ "$b_i" -le "$blocks" ]]; do
  l_i=1
  while [[ "$l_i" -le "$lines_per_block" ]]; do
    printf 'block %s line %s context text\n' "$b_i" "$l_i" >> "$d/big.txt"
    l_i=$((l_i + 1))
  done
  b_i=$((b_i + 1))
done
( cd "$d" && git add big.txt && git -c user.name=T -c user.email=t@example.com commit -q -m "base big.txt" )
pad="$(head -c "$hunk_pad_bytes" /dev/zero | tr '\0' 'X')"
b_i=1
while [[ "$b_i" -le "$blocks" ]]; do
  target_line=$(( (b_i - 1) * lines_per_block + lines_per_block / 2 ))
  # sed -i は GNU と BSD で引数の扱いが割れる（BSD は直後をバックアップ拡張子と
  # 解釈する）。テンポラリへ書いて差し替える。
  awk -v n="$target_line" -v pad="$pad" 'NR == n { print $0 " MODIFIED " pad; next } { print }' \
    "$d/big.txt" > "$d/big.txt.new"
  mv "$d/big.txt.new" "$d/big.txt"
  b_i=$((b_i + 1))
done
( cd "$d" && git add big.txt )
mk_agy_history_stub "$b" "LGTM"
out="$( cd "$d" && PATH="$b:/usr/bin:/bin" bash scripts/second-opinion-review.sh --engine antigravity --runs 1 2>&1 )"; rc=$?
bad=0
[[ "$rc" -eq 0 ]] || { echo "  exit $rc: $out"; bad=1; }
chunk_count="$(cat "$b/.count" 2>/dev/null || echo 0)"
[[ "$chunk_count" -gt 1 ]] || { echo "  ハンク単位への分割が起きていない（chunk_count=$chunk_count）"; bad=1; }
i=1
while [[ "$i" -le "$chunk_count" ]]; do
  header_count="$(extract_chunk_diff "$b/.argv.$i" | grep -c '^diff --git ')"
  if [[ "$header_count" -ne 1 ]]; then
    echo "  chunk $i のファイルヘッダ数が想定と違う: $header_count"
    bad=1
  fi
  i=$((i + 1))
done
if [[ "$bad" -eq 0 ]]; then pass; else fail "ハンク単位分割でファイルヘッダの付け直しが壊れている"; fi

it "1 ハンクで上限を超える差分は分割できず、該当ファイル名を添えて失敗する"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"
: > "$d/huge.txt"
append_ascii_padding "$d/huge.txt" $(( MAX_ARG_BYTES * 2 ))
( cd "$d" && git add huge.txt )
mk_agy_history_stub "$b" "LGTM"
err="$( cd "$d" && PATH="$b:/usr/bin:/bin" bash scripts/second-opinion-review.sh --engine antigravity --runs 1 2>&1 >/dev/null )"; rc=$?
bad=0
[[ "$rc" -ne 0 ]] || { echo "  exit 0 になっている（黙って通している）"; bad=1; }
printf '%s' "$err" | grep -q 'huge.txt' || { echo "  該当ファイル名が stderr に出ていない: $err"; bad=1; }
[[ -f "$b/.count" ]] && { echo "  分割に失敗したのに CLI を呼んでいる"; bad=1; }
if [[ "$bad" -eq 0 ]]; then pass; else fail "1 ハンク超過の失敗処理が誤っている"; fi

it "ハンクを持たない差分（二値・モード変更のみ）が単体で上限を超えると失敗する"
# 実在の git は二値ファイルの差分を「Binary files ... differ」の 1 行に圧縮し、
# 実サイズによらず小さい。上限超過を実測で再現できないため、git diff の出力を
# 丸ごと差し替える stub で「ハンクを 1 つも持たないのに単体で上限を超える差分」
# を合成する。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"; g="$(new_workdir)/gitstub"
mk_review_repo "$d"
crafted="$(new_workdir)/crafted.diff"
{
  echo "diff --git a/blob.bin b/blob.bin"
  echo "index 0000000..1111111 100644"
  echo "Binary files a/blob.bin and b/blob.bin differ"
} > "$crafted"
append_ascii_padding "$crafted" $(( MAX_ARG_BYTES * 2 ))
mk_git_diff_stub "$g" "$crafted"
mk_agy_history_stub "$b" "LGTM"
err="$( cd "$d" && PATH="$g:$b:/usr/bin:/bin" bash scripts/second-opinion-review.sh --engine antigravity --runs 1 2>&1 >/dev/null )"; rc=$?
bad=0
[[ "$rc" -ne 0 ]] || { echo "  exit 0 になっている（黙って通している）"; bad=1; }
printf '%s' "$err" | grep -q 'blob.bin' || { echo "  該当ファイル名が stderr に出ていない: $err"; bad=1; }
[[ -f "$b/.count" ]] && { echo "  分割に失敗したのに CLI を呼んでいる"; bad=1; }
if [[ "$bad" -eq 0 ]]; then pass; else fail "ハンクなし超過の失敗処理が誤っている"; fi

it "日本語を含む差分は文字数ではなくバイト数を基準に分割される"
# 1 文字 3 バイトの日本語だけで差分を構成すると、文字数はバイト数のおよそ 1/3 に
# なる。文字数（${#var} や多バイト対応の wc -m）で測れば上限に収まって見える
# 大きさに、バイト数では上限を超えるように仕込む。呼び出し側の locale を
# 明示的に UTF-8（C.utf8）にしてもなお、バイト数で正しく分割されることを見る。
# grep へ -q を渡さない。-q は最初のマッチでパイプを閉じ、まだ書き込み中の
# producer が SIGPIPE で死ぬ。このファイルは set -o pipefail なので、その回は
# 条件が偽になり、**C.utf8 があるのに検査が黙って skip される**（#285 と同型）。
# 実測ではこの環境の locale -a は 26 バイトでパイプバッファに収まりきるため
# 発火しないが、producer が外部コマンドで出力量が環境依存であるここだけは、
# 偶然に頼らない。同ファイルの他の grep -q は producer が printf で、
# 出力量をこのテスト自身が握っているため区別する。
if locale -a 2>/dev/null | grep -i '^C\.utf8$\|^C\.UTF-8$' >/dev/null; then
  d="$(new_workdir)/r"; b="$(new_workdir)/bin"
  mk_review_repo "$d"
  n_files=4
  per_file_bytes=$(( MAX_ARG_BYTES * 5 / 10 ))
  line='これは日本語のみで構成した検証用の行です。'
  line_bytes="$(LC_ALL=C printf '%s' "$line" | wc -c)"
  lines_needed=$(( per_file_bytes / line_bytes ))
  i=1
  while [[ "$i" -le "$n_files" ]]; do
    : > "$d/j$i.txt"
    yes "$line" 2>/dev/null | head -n "$lines_needed" >> "$d/j$i.txt"  # bsd-ok: yes は無限に出力するので SIGPIPE で終わるのが正常。終了コードは読んでいない
    i=$((i + 1))
  done
  ( cd "$d" && git add j*.txt )
  total_bytes="$(cd "$d" && git diff --cached | wc -c)"
  total_chars="$(cd "$d" && LC_ALL=C.utf8 git diff --cached | LC_ALL=C.utf8 wc -m)"
  bad=0
  if [[ "$total_chars" -ge "$MAX_ARG_BYTES" || "$total_bytes" -le "$MAX_ARG_BYTES" ]]; then
    echo "  フィクスチャが前提を満たしていない（文字数 $total_chars / バイト数 $total_bytes / 上限 $MAX_ARG_BYTES）"
    bad=1
  fi
  mk_agy_history_stub "$b" "LGTM"
  out="$( cd "$d" && env LC_ALL=C.utf8 LANG=C.utf8 PATH="$b:/usr/bin:/bin" bash scripts/second-opinion-review.sh --engine antigravity --runs 1 2>&1 )"; rc=$?
  [[ "$rc" -eq 0 ]] || { echo "  exit $rc: $out"; bad=1; }
  chunk_count="$(cat "$b/.count" 2>/dev/null || echo 0)"
  if [[ "$chunk_count" -le 1 ]]; then
    echo "  文字数基準なら 1 チャンクで収まるはずの差分が分割されていない（バイト基準になっていない疑い）"
    bad=1
  fi
  i=1
  while [[ "$i" -le "$chunk_count" ]]; do
    combined_bytes=$(( $(wc -c < "$b/.argv.$i") - 4 ))
    if [[ "$combined_bytes" -gt "$MAX_ARG_BYTES" ]]; then
      echo "  chunk $i の引数が上限を超えている: $combined_bytes > $MAX_ARG_BYTES"
      bad=1
    fi
    i=$((i + 1))
  done
  if [[ "$bad" -eq 0 ]]; then pass; else fail "日本語差分のバイト基準分割が壊れている"; fi
else
  # C.utf8 を生成していない環境では多バイト前提のフィクスチャが成立しない。
  # 検査そのものを消すのではなく、成立しなかった旨を残して通す。
  echo "  skip: C.utf8 locale が無いため文字数との対比を検証できません"
  pass
fi

exit_with_result
