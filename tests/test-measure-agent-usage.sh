#!/usr/bin/env bash
# scripts/measure-agent-usage.sh が、役割別のトークン使用量を正しく集計することを
# 検査する。
#
# 実際のセッション記録は環境ごとに違い、リポジトリにも無い。実記録を対象にすると
# 「誰が回しても同じ数字が出る」ことを検査できないため、**フィクスチャを自前で作り、
# 既知の答えと突き合わせる**。
#
# 固定する不変条件は 4 つ。いずれも「数字が出た」だけでは足りない性質で、壊れても
# 出力の見た目が変わらないものを選んでいる。
#
#   1. 親セッションとサブエージェントの**両方**を集計対象に含める。サブエージェントの
#      記録は親ファイルに入らないため、片方だけを拾う実装でも数字は出てしまう
#      （#259 の実測で実際に見落としかけた）。
#   2. レコード 0 件で**非 0 で終わる**。記録形式が変わって何も拾えなくなると、
#      集計はすべて 0 になり「general-purpose 0%」という正しく見える嘘を返す。
#   3. 出力に**プロンプト本文が出ない**。記録には作業中の差分や機密が含まれうる。
#   4. 分母の異なる 2 つの比率を出す。#255 の「92%」がどちらの分母か分からず
#      再現できなかったのが、この機構を作る動機そのもの。
#
# bash 3.2 互換を維持する。

set -uo pipefail
export LC_ALL=C.UTF-8
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-measure-agent-usage"

SCRIPT="$REPO_ROOT/scripts/measure-agent-usage.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-measure-agent-usage.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# フィクスチャで使う、出力に現れてはいけない文字列。実記録のプロンプト本文に
# 相当する。
SECRET_MARKER='FIXTURE_PROMPT_BODY_MUST_NOT_LEAK'

# assistant レコードを 1 行組み立てる。
#   $1 date / $2 総トークンを input へ入れる値 / $3 output / $4 attributionAgent（空なら付けない）
make_record() {
  local date="$1" input="$2" output="$3" role="$4"
  local attr=""
  [[ -n "$role" ]] && attr=",\"attributionAgent\":\"$role\""
  printf '{"type":"assistant","timestamp":"%sT00:00:00.000Z","message":{"role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"%s"}],"usage":{"input_tokens":%s,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":%s}}%s}\n' \
    "$date" "$SECRET_MARKER" "$input" "$output" "$attr"
}

# ── フィクスチャ ──────────────────────────────────────────────────────────────
#
# 親  2026-01-01 total 100 / output  5   （attributionAgent 無し → main-loop）
# 親  2026-01-02 total 100 / output 10
# 子  2026-01-01 total 100 / output 20   （attributionAgent = explorer）
#
# 期待値:
#   日次 2026-01-01: main-loop 50.0% / explorer 50.0%
#   日次 2026-01-02: main-loop 100.0%
#   期間 main-loop 200 (66.7%) / explorer 100 (33.3%, サブ内 100.0%)

FIX="$TMP_ROOT/projects"
mkdir -p "$FIX/sess1/subagents"
{
  make_record 2026-01-01 100 5 ""
  make_record 2026-01-02 100 10 ""
} > "$FIX/sess1.jsonl"
make_record 2026-01-01 100 20 "explorer" > "$FIX/sess1/subagents/agent-aaa.jsonl"

# 集計対象にならないレコード（usage を持たない user レコード）も置く。これが
# 混ざっても件数と数字が変わらないことを、下の件数検査が併せて担保する。
printf '{"type":"user","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"%s"}}\n' \
  "$SECRET_MARKER" >> "$FIX/sess1.jsonl"

OUT="$(bash "$SCRIPT" --projects-dir "$FIX" 2>&1)"
RC=$?

it "フィクスチャに対して終了コード 0 で終わる"
if [[ "$RC" -eq 0 ]]; then pass; else fail "rc=$RC / 出力: $OUT"; fi

it "親とサブエージェントの記録件数を両方報告する"
if printf '%s' "$OUT" | grep -q '親 1 件 / サブエージェント 1 件'; then
  pass
else
  fail "件数の報告が合わない: $(printf '%s' "$OUT" | grep 'セッション記録')"
fi

it "usage を持つレコードだけを数える（3 件）"
if printf '%s' "$OUT" | grep -q '集計対象レコード: 3 件'; then
  pass
else
  fail "$(printf '%s' "$OUT" | grep '集計対象レコード')"
fi

it "サブエージェント側の役割（explorer）が集計に現れる"
# 親ファイルだけを読む実装でも他の検査は通ってしまう。ここが唯一の歯止め。
if printf '%s' "$OUT" | grep -q 'explorer'; then
  pass
else
  fail "explorer が出力に無い（サブエージェントの記録を読んでいない）"
fi

it "日次の比率が既知の値と一致する（2026-01-01 は 50% ずつ）"
d1_main="$(printf '%s\n' "$OUT" | awk '$1=="2026-01-01" && $2=="main-loop" {print $5}')"
d1_exp="$(printf '%s\n' "$OUT" | awk '$1=="2026-01-01" && $2=="explorer" {print $5}')"
if [[ "$d1_main" == "50.0%" && "$d1_exp" == "50.0%" ]]; then
  pass
else
  fail "main-loop='$d1_main' explorer='$d1_exp'（ともに 50.0% を期待）"
fi

it "日次の比率が既知の値と一致する（2026-01-02 は main-loop 100%）"
d2_main="$(printf '%s\n' "$OUT" | awk '$1=="2026-01-02" && $2=="main-loop" {print $5}')"
assert_eq "$d2_main" "100.0%" "2026-01-02 の main-loop 比率"

it "期間合計のトークン数が既知の値と一致する"
tot_main="$(printf '%s\n' "$OUT" | awk '$1=="main-loop" && $2 ~ /^[0-9]+$/ {print $2}')"
tot_exp="$(printf '%s\n' "$OUT" | awk '$1=="explorer" && $2 ~ /^[0-9]+$/ {print $2}')"
if [[ "$tot_main" == "200" && "$tot_exp" == "100" ]]; then
  pass
else
  fail "main-loop='$tot_main'（200 を期待） explorer='$tot_exp'（100 を期待）"
fi

it "分母の異なる 2 つの比率を出す（全体 / サブエージェント内）"
# explorer は全体の 33.3%、サブエージェント内では 100.0%。この 2 つが同じ行に
# 並ぶことが、#255 の「どちらの分母か分からない」を繰り返さないための担保。
exp_line="$(printf '%s\n' "$OUT" | awk '$1=="explorer" && $2 ~ /^[0-9]+$/')"
if printf '%s' "$exp_line" | grep -q '33\.3%' && printf '%s' "$exp_line" | grep -q '100\.0%'; then
  pass
else
  fail "explorer 行に 2 つの分母の比率が並んでいない: $exp_line"
fi

it "main-loop にはサブエージェント内比率を出さない"
main_line="$(printf '%s\n' "$OUT" | awk '$1=="main-loop" && $2 ~ /^[0-9]+$/')"
if printf '%s' "$main_line" | grep -qE '\-$'; then
  pass
else
  fail "main-loop 行の SHARE_OF_SUBAGENTS が '-' でない: $main_line"
fi

it "出力にプロンプト本文が含まれない"
if ! printf '%s' "$OUT" | grep -q "$SECRET_MARKER"; then
  pass
else
  fail "記録の本文が出力へ漏れている"
fi

it "同じ入力に対して同じ出力を返す（決定性）"
# 集計は連想配列を走査するため、整列しないと実行ごとに行順が変わる。
OUT2="$(bash "$SCRIPT" --projects-dir "$FIX" 2>&1)"
if [[ "$OUT" == "$OUT2" ]]; then
  pass
else
  fail "2 回の実行で出力が異なる:
$(diff <(printf '%s\n' "$OUT") <(printf '%s\n' "$OUT2") | head -n 10)"
fi

it "入力側トークンが 0 の日でも壊れない（ゼロ除算）"
# 出力トークンだけを持つレコードは実在し、その日だけを集計すると分母が 0 になる。
# mawk は nan を返し（`nan%` という読めない値が出る）、gawk は fatal で落ちる。
# awk の実装で結果が変わる式を残さない。
ZERO="$TMP_ROOT/zero"
mkdir -p "$ZERO"
printf '{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"assistant","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":42}}}\n' \
  > "$ZERO/s.jsonl"
out_zero="$(bash "$SCRIPT" --projects-dir "$ZERO" 2>&1)"
rc_zero=$?
if [[ "$rc_zero" -eq 0 ]] \
   && ! printf '%s' "$out_zero" | grep -qi 'nan' \
   && printf '%s' "$out_zero" | grep -q '0\.0%'; then
  pass
else
  fail "rc=$rc_zero / 出力: $out_zero"
fi

# ── 期間指定 ──────────────────────────────────────────────────────────────────

it "--since で期間を絞れる"
OUT_SINCE="$(bash "$SCRIPT" --projects-dir "$FIX" --since 2026-01-02 2>&1)"
if printf '%s' "$OUT_SINCE" | grep -q '集計対象レコード: 1 件' \
   && ! printf '%s' "$OUT_SINCE" | grep -q '2026-01-01'; then
  pass
else
  fail "$(printf '%s' "$OUT_SINCE" | grep '集計対象レコード')"
fi

it "--until で期間を絞れる"
OUT_UNTIL="$(bash "$SCRIPT" --projects-dir "$FIX" --until 2026-01-01 2>&1)"
if printf '%s' "$OUT_UNTIL" | grep -q '集計対象レコード: 2 件' \
   && ! printf '%s' "$OUT_UNTIL" | grep -q '2026-01-02'; then
  pass
else
  fail "$(printf '%s' "$OUT_UNTIL" | grep '集計対象レコード')"
fi

# ── 0 件を成功にしない ────────────────────────────────────────────────────────

it "対象レコードが 0 件なら非 0 で終わる（記録形式の変化を静かに通さない）"
EMPTY="$TMP_ROOT/empty"
mkdir -p "$EMPTY"
printf '{"type":"user","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"user","content":"x"}}\n' \
  > "$EMPTY/sess.jsonl"
out_empty="$(bash "$SCRIPT" --projects-dir "$EMPTY" 2>&1)"
rc_empty=$?
if [[ "$rc_empty" -ne 0 ]] && printf '%s' "$out_empty" | grep -q '1 件もありません'; then
  pass
else
  fail "rc=$rc_empty / 出力: $out_empty"
fi

it "期間指定で 0 件になった場合も非 0 で終わる"
out_range="$(bash "$SCRIPT" --projects-dir "$FIX" --since 2030-01-01 2>&1)"
rc_range=$?
if [[ "$rc_range" -ne 0 ]]; then
  pass
else
  fail "範囲外の期間指定が 0 で終わった: $out_range"
fi

it "存在しないディレクトリを指定すると非 0 で終わる"
out_missing="$(bash "$SCRIPT" --projects-dir "$TMP_ROOT/does-not-exist" 2>&1)"
rc_missing=$?
if [[ "$rc_missing" -ne 0 ]]; then
  pass
else
  fail "存在しないディレクトリが 0 で終わった: $out_missing"
fi

it "未知のオプションを拒否する"
out_unknown="$(bash "$SCRIPT" --nope 2>&1)"
rc_unknown=$?
if [[ "$rc_unknown" -ne 0 ]] && printf '%s' "$out_unknown" | grep -q 'unknown option'; then
  pass
else
  fail "rc=$rc_unknown / 出力: $out_unknown"
fi

# ── カタログ登録 ──────────────────────────────────────────────────────────────

it "scripts/CATALOG.md に登録されている"
if grep -q 'scripts/measure-agent-usage\.sh' "$REPO_ROOT/scripts/CATALOG.md"; then
  pass
else
  fail "CATALOG.md に登録が無い"
fi

exit_with_result
