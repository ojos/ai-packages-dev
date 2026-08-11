#!/usr/bin/env bash
# measure-agent-usage.sh — サブエージェントの役割別トークン使用量を集計する。
#
# #255 で入れたモデル配分機構の効果を、誰が回しても同じ数字が出る形で測るための
# レポート。**合否判定はしない**（閾値を決める根拠になる運用実績がまだ無い。#279）。
#
# ## 集計元
#
# Claude Code のセッション記録は 2 階層ある。**サブエージェントの記録は親ファイルに
# 入らない**ため、片方だけを見ると委譲分がまるごと欠ける（#259 の実測で実際に
# 見落としかけた）。
#
#   <projects-dir>/<sessionId>.jsonl                       親セッション
#   <projects-dir>/<sessionId>/subagents/agent-<id>.jsonl  サブエージェント
#
# type=="assistant" のレコードが集計に必要な 2 項目を持つ。
#
#   message.usage       input / cache_creation / cache_read / output のトークン数
#   attributionAgent    どの役割が消費したかの正本。親ループのレコードは持たない
#
# 役割の判定に message.model は使わない。モデルは役割から一意に決まるが逆は決まらない。
# general-purpose は親のモデルを継承するため親ループと区別がつかず、役割を増やせば
# 同じモデルを共有する組（かつての planner と implementer はどちらも sonnet だった）が
# できる。配分を変えた瞬間に対応が崩れる形へ依存しない。
#
# ## 分母を 2 つ出す理由
#
# 「役割別 / 全体」と「役割別 / サブエージェント合計」では数字が倍近く変わる。
# #255 が記録した「general-purpose 92%」はどちらの分母か票に書かれておらず、
# 再現できなかった。同じことを繰り返さないため両方を出し、列名で分母を明示する。
#
# ## 出さないもの
#
# プロンプト本文・ファイル内容・ツールの入出力は一切出さない。出すのは日付・役割名・
# トークン数だけ。記録には作業中の差分や機密が含まれうるため、集計結果を貼れない
# 形にしない。
#
# 依存: jq, awk。bash 3.2 互換（連想配列・mapfile を使わない）。
set -uo pipefail

usage() {
  cat <<'EOF'
usage:
  bash scripts/measure-agent-usage.sh [--projects-dir <dir>] [--since <YYYY-MM-DD>] [--until <YYYY-MM-DD>]

options:
  --projects-dir <dir>  セッション記録のディレクトリ
                        (default: ~/.claude/projects/<cwd をエンコードした名前>)
  --since <date>        この日以降（YYYY-MM-DD、当日を含む）
  --until <date>        この日以前（YYYY-MM-DD、当日を含む）
  -h, --help            このヘルプ

notes:
  - レポート専用。合否判定はしない。
  - 集計対象のレコードが 1 件も無い場合は非 0 で終わる（記録形式が変わったときに
    「0%」と報告して静かに通るのを防ぐため）。
EOF
}

PROJECTS_DIR=""
SINCE=""
UNTIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --projects-dir) PROJECTS_DIR="$2"; shift 2 ;;
    --since)        SINCE="$2"; shift 2 ;;
    --until)        UNTIL="$2"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "error: command not found: jq" >&2; exit 1; }

# 既定の記録ディレクトリ。Claude Code は cwd の "/" を "-" へ置き換えた名前を使う
# （/workspaces/foo → -workspaces-foo）。
if [[ -z "$PROJECTS_DIR" ]]; then
  encoded="${PWD//\//-}"
  PROJECTS_DIR="$HOME/.claude/projects/$encoded"
fi

[[ -d "$PROJECTS_DIR" ]] || {
  echo "error: セッション記録のディレクトリがありません: $PROJECTS_DIR" >&2
  echo "       --projects-dir で明示してください。" >&2
  exit 1
}

# 親とサブエージェントの記録を数える。両方を対象にしていることを出力で見せる
# （片方だけ拾う実装へ退行しても数字は出てしまうため、件数を目視できるようにする）。
parent_count=0
sub_count=0
for f in "$PROJECTS_DIR"/*.jsonl; do
  [[ -f "$f" ]] && parent_count=$((parent_count + 1))
done
for f in "$PROJECTS_DIR"/*/subagents/agent-*.jsonl; do
  [[ -f "$f" ]] && sub_count=$((sub_count + 1))
done

echo "[measure-agent-usage] 対象: $PROJECTS_DIR"
echo "[measure-agent-usage] セッション記録: 親 ${parent_count} 件 / サブエージェント ${sub_count} 件"
[[ -n "$SINCE" || -n "$UNTIL" ]] && echo "[measure-agent-usage] 期間: ${SINCE:-（指定なし）} 〜 ${UNTIL:-（指定なし）}"

# ── 抽出 ──────────────────────────────────────────────────────────────────────
#
# 1 レコード 1 行の TSV（date, role, total_tokens, output_tokens）へ落とす。
# role は attributionAgent。持たないレコード（親ループ）は main-loop とする。
#
# jq のエラーは握り潰さない。記録形式が変わって解釈できなくなったことと、
# 集計対象が無いことは別の状態で、前者を後者に見せると原因を追えなくなる。
extract() {
  local f
  for f in "$PROJECTS_DIR"/*.jsonl "$PROJECTS_DIR"/*/subagents/agent-*.jsonl; do
    [[ -f "$f" ]] || continue
    jq -r '
      select(.type == "assistant" and .message.usage != null)
      | [ (.timestamp[0:10]),
          (.attributionAgent // "main-loop"),
          ( (.message.usage.input_tokens // 0)
          + (.message.usage.cache_creation_input_tokens // 0)
          + (.message.usage.cache_read_input_tokens // 0) ),
          (.message.usage.output_tokens // 0) ]
      | @tsv' "$f" || return 1
  done
}

ROWS="$(extract)" || {
  echo "error: セッション記録を解釈できませんでした（記録形式が変わった可能性があります）" >&2
  exit 1
}

# 期間で絞る。日付は YYYY-MM-DD の固定長なので文字列比較で足りる。
if [[ -n "$SINCE" || -n "$UNTIL" ]]; then
  ROWS="$(printf '%s\n' "$ROWS" | SINCE_WANT="$SINCE" UNTIL_WANT="$UNTIL" awk -F'\t' '
    BEGIN { s = ENVIRON["SINCE_WANT"]; u = ENVIRON["UNTIL_WANT"] }
    (s == "" || $1 >= s) && (u == "" || $1 <= u)')"
fi

ROW_COUNT="$(printf '%s\n' "$ROWS" | grep -c . || true)"

# 0 件を成功にしない。記録形式が変わって select が何も拾わなくなった場合、
# 以降の集計はすべて 0 になり「general-purpose 0%」という**正しく見える嘘**を返す。
# #259 の判断材料にする以上、ここは静かに通してはいけない。
if [[ "$ROW_COUNT" -eq 0 ]]; then
  echo "error: 集計対象のレコードが 1 件もありません" >&2
  echo "       記録が無いか、期間指定が範囲外か、記録形式が変わった可能性があります。" >&2
  exit 1
fi

echo "[measure-agent-usage] 集計対象レコード: ${ROW_COUNT} 件"
echo

# ── 集計 ──────────────────────────────────────────────────────────────────────

printf '%s\n' "$ROWS" | awk -F'\t' '
  {
    day_role_total[$1 "\t" $2] += $3
    day_role_out[$1 "\t" $2]   += $4
    day_total[$1]              += $3
    role_total[$2]             += $3
    role_out[$2]               += $4
    grand_total                += $3
    if ($2 != "main-loop") sub_total += $3
    seen_day[$1] = 1
    seen_role[$2] = 1
  }
  END {
    printf "== 日次（TOTAL = input + cache_creation + cache_read） ==\n"
    printf "%-12s %-20s %16s %14s %12s\n", "DATE", "ROLE", "TOTAL", "OUTPUT", "SHARE_OF_DAY"
    n = 0
    for (k in day_role_total) keys[n++] = k
    # 日付 → 役割 の順に並べる。集計順は連想配列の走査順に依存するため、
    # 出力が実行ごとに変わらないよう明示的に整列する（同じ入力に同じ出力）。
    for (i = 0; i < n; i++)
      for (j = i + 1; j < n; j++)
        if (keys[j] < keys[i]) { t = keys[i]; keys[i] = keys[j]; keys[j] = t }
    for (i = 0; i < n; i++) {
      split(keys[i], p, "\t")
      # その日の入力側トークンが全レコードで 0 だと day_total は 0 になる
      # （出力トークンだけを持つレコードは実在する）。awk はゼロ除算で fatal に
      # なるため、集計そのものが落ちる。期間合計側と同じく手前で分ける。
      day_share = (day_total[p[1]] > 0) ? 100 * day_role_total[keys[i]] / day_total[p[1]] : 0
      printf "%-12s %-20s %16d %14d %11.1f%%\n", p[1], p[2], day_role_total[keys[i]], \
             day_role_out[keys[i]], day_share
    }

    printf "\n== 期間合計 ==\n"
    printf "%-20s %16s %14s %14s %20s\n", "ROLE", "TOTAL", "OUTPUT", "SHARE_OF_ALL", "SHARE_OF_SUBAGENTS"
    m = 0
    for (r in role_total) rkeys[m++] = r
    for (i = 0; i < m; i++)
      for (j = i + 1; j < m; j++)
        if (rkeys[j] < rkeys[i]) { t = rkeys[i]; rkeys[i] = rkeys[j]; rkeys[j] = t }
    for (i = 0; i < m; i++) {
      r = rkeys[i]
      share_all = (grand_total > 0) ? 100 * role_total[r] / grand_total : 0
      if (r == "main-loop")      sub_share = "-"
      else if (sub_total > 0)    sub_share = sprintf("%.1f%%", 100 * role_total[r] / sub_total)
      else                       sub_share = "-"
      printf "%-20s %16d %14d %13.1f%% %20s\n", r, role_total[r], role_out[r], share_all, sub_share
    }

    printf "\n分母: SHARE_OF_ALL = 全レコードの合計 / SHARE_OF_SUBAGENTS = main-loop を除いた合計\n"
  }
'
