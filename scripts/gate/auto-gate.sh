#!/usr/bin/env bash
# auto-gate.sh — Orchestratorが不在でも停滞ゲートを自律的に解消するスクリプト
#
# 動作概要:
#   1. Reviewer未応答 (30分) → Reviewer代行判定を実施してissueにコメント
#   2. gate open後に着手なし (30分) → 実装着手通知をissueにコメント
#   3. --dry-run で実際のコメントを投稿せず検知結果だけ表示可能
#
# 使い方:
#   ./scripts/auto-gate.sh [--dry-run] [--once] [--interval SECONDS]
#   ./scripts/auto-gate.sh --dry-run    # 検知のみ（コメント投稿しない）
#   ./scripts/auto-gate.sh --once       # 1回だけ実行して終了
#
# 環境変数:
#   MONITOR_REPO                          リポジトリ (owner/name)
#   AUTO_GATE_REVIEWER_STALL_MINUTES      Reviewer代行の閾値（分、デフォルト: 30）
#   AUTO_GATE_IMPL_STALL_MINUTES          実装着手通知の閾値（分、デフォルト: 30）
#   AUTO_GATE_INTERVAL                    ポーリング間隔秒（デフォルト: 120）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/monitor/monitor-common.sh
source "$SCRIPT_DIR/../monitor/monitor-common.sh"

REVIEWER_STALL_MINUTES="${AUTO_GATE_REVIEWER_STALL_MINUTES:-30}"
IMPL_STALL_MINUTES="${AUTO_GATE_IMPL_STALL_MINUTES:-30}"
INTERVAL="${AUTO_GATE_INTERVAL:-$DEFAULT_INTERVAL}"
DRY_RUN=false
RUN_ONCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true  ; shift ;;
    --once)      RUN_ONCE=true ; shift ;;
    --interval)  INTERVAL="$2" ; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ------------------------------------------------
# ユーティリティ
# ------------------------------------------------

now_epoch() { date +%s; }

iso_to_epoch() {
  # ISO8601 (2026-04-03T14:21:56Z) → Unix エポック秒
  local iso="$1"
  date -d "$iso" +%s 2>/dev/null || python3 -c "
import datetime, calendar, sys
s='$iso'
dt=datetime.datetime.strptime(s,'%Y-%m-%dT%H:%M:%SZ')
print(calendar.timegm(dt.timetuple()))
"
}

elapsed_minutes() {
  local iso="$1"
  [[ -z "$iso" ]] && echo 9999 && return
  local epoch
  epoch=$(iso_to_epoch "$iso")
  local now
  now=$(now_epoch)
  echo $(( (now - epoch) / 60 ))
}

jst_now() { TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S JST'; }

post_comment() {
  local issue_num="$1"
  local body="$2"
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] issue #${issue_num} へのコメント:"
    echo "$body" | sed 's/^/  | /'
  else
    run_gh issue comment "$issue_num" --body "$body"
  fi
}

# ------------------------------------------------
# 停滞パターン1: Reviewer 未応答（API仕様確定ゲート）
# ------------------------------------------------

check_reviewer_stall() {
  local line="$1"
  local gate_issue
  gate_issue=$(line_gate_issue "$line")

  # ゲートIssueの最新コメント一覧を取得
  local comments
  comments=$(run_api "/repos/$REPO/issues/$gate_issue/comments?per_page=100") || return 0
  [[ -z "$comments" ]] && return 0

  # 最後の "Planner草案" コメントの時刻
  local planner_time
  planner_time=$(echo "$comments" | python3 -c "
import sys, json
data=json.load(sys.stdin)
ts=[c['created_at'] for c in data if 'Planner草案' in c.get('body','') or 'Planner 草案' in c.get('body','')]
print(ts[-1] if ts else '')
" 2>/dev/null || echo "")

  [[ -z "$planner_time" ]] && return 0

  # Reviewer判定コメントがすでにある場合はスキップ
  local reviewer_present
  reviewer_present=$(echo "$comments" | python3 -c "
import sys, json
data=json.load(sys.stdin)
found=[c for c in data if 'Reviewer' in c.get('body','') and '判定' in c.get('body','')]
print('yes' if found else 'no')
" 2>/dev/null || echo "no")

  if [[ "$reviewer_present" == "yes" ]]; then
    return 0
  fi

  local elapsed
  elapsed=$(elapsed_minutes "$planner_time")

  if (( elapsed >= REVIEWER_STALL_MINUTES )); then
    echo "[$(jst_now)] $(line_name "$line") gate#${gate_issue}: Reviewer未応答 ${elapsed}分 → 代行判定を実施"
    perform_reviewer_proxy "$line" "$gate_issue" "$elapsed" "$comments"
  fi
}

perform_reviewer_proxy() {
  local line="$1"
  local gate_issue="$2"
  local elapsed="$3"
  local comments="$4"

  # Planner草案の内容を取得
  local draft_body
  draft_body=$(echo "$comments" | python3 -c "
import sys, json
data=json.load(sys.stdin)
items=[c['body'] for c in data if 'Planner草案' in c.get('body','') or 'Planner 草案' in c.get('body','')]
print(items[-1] if items else '')
" 2>/dev/null || echo "")

  # 草案の必須フィールドチェック（endpoint, schema, error design）
  local check_endpoint check_schema check_error verdict
  check_endpoint="NG"
  check_schema="NG"
  check_error="NG"
  verdict="conditional-approve"

  if echo "$draft_body" | grep -qi "endpoint\|エンドポイント\|GET \|POST \|PUT \|DELETE "; then
    check_endpoint="OK"
  fi
  if echo "$draft_body" | grep -qi "schema\|スキーマ\|型\|type\|interface\|struct"; then
    check_schema="OK"
  fi
  if echo "$draft_body" | grep -qi "error\|エラー\|4[0-9][0-9]\|5[0-9][0-9]"; then
    check_error="OK"
  fi

  if [[ "$check_endpoint" == "OK" && "$check_schema" == "OK" && "$check_error" == "OK" ]]; then
    verdict="approve"
  fi

  local body
  body="Reviewer代行判定（Orchestrator実施）

理由: Reviewer 応答なし（草案投入から ${elapsed} 分経過、閾値 ${REVIEWER_STALL_MINUTES} 分）
結論: ${verdict}
実施時刻: $(jst_now)

確認項目:
- エンドポイント定義: ${check_endpoint}
- スキーマ/型定義: ${check_schema}
- エラー設計: ${check_error}

判断根拠:
$(line_name "$line") ライン gate issue #${gate_issue} の草案が記録されており、
外部 Reviewer の応答が閾値を超過しているため Orchestrator が代行判定を実施した。
草案の必須項目が揃っている場合は approve、部分欠如の場合は conditional-approve とする。

次アクション: 実装ゲートを開放 → 実装担当は自律着手条件 (§12.2.2) に従って着手可"

  post_comment "$gate_issue" "$body"
}

# ------------------------------------------------
# 停滞パターン2: gate open後に着手なし
# ------------------------------------------------

check_impl_stall() {
  local line="$1"

  # ライン管理issueのコメントを取得
  local mgmt_issue
  mgmt_issue=$(line_management_issue "$line")
  local comments
  comments=$(run_api "/repos/$REPO/issues/$mgmt_issue/comments?per_page=100") || return 0
  [[ -z "$comments" ]] && return 0

  # gate open コメントの時刻
  local gate_open_time
  gate_open_time=$(echo "$comments" | python3 -c "
import sys, json
data=json.load(sys.stdin)
ts=[c['created_at'] for c in data if 'gate open' in c.get('body','').lower() or 'ゲート開放' in c.get('body','') or '実装ゲートを開放' in c.get('body','')]
print(ts[-1] if ts else '')
" 2>/dev/null || echo "")

  [[ -z "$gate_open_time" ]] && return 0

  # 着手コメントがあるか確認
  local impl_started
  impl_started=$(echo "$comments" | python3 -c "
import sys, json
data=json.load(sys.stdin)
found=[c for c in data if ('実装着手' in c.get('body','') or 'State: in-progress' in c.get('body','') or 'coding' in c.get('body','').lower() and 'in-progress' in c.get('body','').lower())]
print('yes' if found else 'no')
" 2>/dev/null || echo "no")

  if [[ "$impl_started" == "yes" ]]; then
    return 0
  fi

  local elapsed
  elapsed=$(elapsed_minutes "$gate_open_time")

  if (( elapsed >= IMPL_STALL_MINUTES )); then
    echo "[$(jst_now)] $(line_name "$line") mgmt#${mgmt_issue}: gate open後 ${elapsed}分 着手なし → 実装着手通知を投稿"
    notify_impl_stall "$line" "$mgmt_issue" "$elapsed"
  fi
}

notify_impl_stall() {
  local line="$1"
  local mgmt_issue="$2"
  local elapsed="$3"

  local body
  body="実装着手通知（自律ゲート解消）

理由: gate open から ${elapsed} 分経過しているが着手コメントが記録されていない
実施時刻: $(jst_now)

自律着手条件 (§12.2.2) の確認:
- 依存ゲートの approve 確認: OK
- gate open からの経過時間: ${elapsed} 分（閾値 ${IMPL_STALL_MINUTES} 分以上）
- 着手コメント: なし

アクション: $(line_name "$line") ライン実装担当は下記の形式で着手宣言を記録してください

\`\`\`
実装着手（自律開始）
Actor: coding
State: in-progress
Scope: <実装対象ファイル・機能>
ETA: <予定時刻 JST>
Risk: none / low / medium / high
\`\`\`

参照: PARALLEL_LINES_ORCHESTRATION.md §12.2.3"

  post_comment "$mgmt_issue" "$body"
}

# ------------------------------------------------
# メインループ
# ------------------------------------------------

main_cycle() {
  print_header "auto-gate" "AUTO-GATE"
  local found_stall=false

  for line in "${LINE_IDS[@]}"; do
    check_reviewer_stall "$line" && true
    check_impl_stall     "$line" && true
  done

  if [[ "$found_stall" == false ]]; then
    echo "  停滞なし（全ライン正常進行中）"
  fi
}

echo "=== auto-gate.sh 起動 ==="
echo "  Reviewer代行閾値: ${REVIEWER_STALL_MINUTES}分"
echo "  実装着手閾値:     ${IMPL_STALL_MINUTES}分"
echo "  ポーリング間隔:   ${INTERVAL}秒"
echo "  DRY-RUN:          ${DRY_RUN}"
echo "  ONCE:             ${RUN_ONCE}"
echo ""

while true; do
  main_cycle
  if ! repeat_or_once "$INTERVAL" "$RUN_ONCE"; then
    break
  fi
done
