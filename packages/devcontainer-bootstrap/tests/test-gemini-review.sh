#!/usr/bin/env bash
# 第二意見レビュー（規範パッケージの templates/gemini-review.sh）の判定を検証する。
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

echo "test-gemini-review"

REVIEW="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/.ai-playbook/templates/gemini-review.sh"

LOADER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/load-project-env.sh"

# レビュー対象の差分を持つ一時リポジトリを作る。scripts/ の 1 階層上がルート。
mk_review_repo() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  cp "$REVIEW" "$dir/scripts/gemini-review.sh"
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
#
# M / T は「通過を示す一意な出力」ではないが LGTM 行を含む形で、モデルが自然に
# 取る出力。行の存在で判定すると重大な指摘ごと通過する。
mk_gemini_stub() {
  local bindir="$1" seq="$2"
  mkdir -p "$bindir"
  cat > "$bindir/gemini" <<STUB
#!/usr/bin/env bash
# 引数と stdin は読み捨てる。判定ロジックだけを検証する stub。
cat >/dev/null 2>&1 || true
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
  *) echo "### 指摘 \$n: 何かがおかしい" ;;
esac
exit 0
STUB
  chmod +x "$bindir/gemini"
  rm -f "$bindir/.count"
}

run_review() {
  local dir="$1" bindir="$2"
  shift 2
  ( cd "$dir" && PATH="$bindir:$PATH" GEMINI_API_KEY=dummy bash scripts/gemini-review.sh "$@" 2>&1 )
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
( cd "$d" && PATH="$b:$PATH" GEMINI_API_KEY=dummy GEMINI_REVIEW_RUNS=3 bash scripts/gemini-review.sh ) >/dev/null 2>&1
assert_eq "$(cat "$b/.count")" "3" "環境変数での呼び出し回数"

# ── 不正な回数は fail-closed ──────────────────────────────────────────────────
it "runs が 0 / 負数 / 非数値なら実行前に停止する"
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "LLL"
bad=0
for v in 0 -1 abc 1.5; do
  err="$( ( cd "$d" && PATH="$b:$PATH" GEMINI_API_KEY=dummy bash scripts/gemini-review.sh --runs "$v" ) 2>&1 >/dev/null )"
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
out="$( cd "$d" && PATH="$b:$PATH" bash scripts/gemini-review.sh 2>&1 )"; rc=$?
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
( cd "$d" && PATH="$b:$PATH" bash scripts/gemini-review.sh --runs 1 ) >/dev/null 2>&1
assert_eq "$(cat "$b/.count" 2>/dev/null || echo 0)" "1" "CLI 引数の優先"

it "値を伴わないオプションは unbound variable ではなく使い方を出して停止する"
# set -u 下で $2 を直接読むと、何が足りないかを言わずに落ちる。
d="$(new_workdir)/r"; b="$(new_workdir)/bin"
mk_review_repo "$d"; mk_gemini_stub "$b" "L"
bad=0
for opt in --runs --range --model; do
  err="$( ( cd "$d" && PATH="$b:$PATH" GEMINI_API_KEY=dummy bash scripts/gemini-review.sh "$opt" ) 2>&1 >/dev/null )"
  rc=$?
  [[ "$rc" -eq 1 ]] || { echo "  $opt で exit 1 にならない (exit $rc)"; bad=1; }
  printf '%s' "$err" | grep -q 'には値が必要です' \
    || { echo "  $opt が値不足として扱われていない: $err"; bad=1; }
  printf '%s' "$err" | grep -q 'unbound variable' \
    && { echo "  $opt で unbound variable が出ている: $err"; bad=1; }
done
if [[ "$bad" -eq 0 ]]; then pass; else fail "値なしオプションの扱いが不十分"; fi

exit_with_result
