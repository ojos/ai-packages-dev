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

exit_with_result
