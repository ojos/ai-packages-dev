#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/monitor-common.sh"

interval="$DEFAULT_INTERVAL"
once="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)
      interval="$2"
      shift 2
      ;;
    --once)
      once="true"
      shift
      ;;
    -h|--help)
      echo "usage: $0 [--interval <sec>] [--once]"
      exit 0
      ;;
    *)
      echo "usage: $0 [--interval <sec>] [--once]" >&2
      exit 1
      ;;
  esac
done

while true; do
  clear
  print_header "terminal.monitor.overview"
  echo 'line | mode | current_gate | work_status | owner_role | risk | last_update | next_gate | blocker | open_pr_count'

  for line_id in "${LINE_IDS[@]}"; do
    management_issue="$(line_management_issue "$line_id")"
    gate_issue="$(line_gate_issue "$line_id")"
    gate_title="$(issue_title "$gate_issue")"
    current_gate="$(derive_gate_name "$gate_title")"
    work_status="$(derive_work_status "$line_id")"
    owner_role="$(derive_owner_role "$gate_issue")"
    risk="$(derive_risk "$management_issue")"
    last_update="$(line_last_update "$line_id")"
    next_gate="$(derive_next_gate "$current_gate")"
    blocker="$(derive_blocker "$management_issue" "$gate_issue")"
    open_pr_count="$(line_open_pr_count "$(line_open_pr_pattern "$line_id")")"

    printf '%s | %s | %s | %s | %s | %s | %s | %s | %s | %s\n' \
      "$(line_name "$line_id")" \
      "$(line_mode "$line_id")" \
      "$current_gate" \
      "$work_status" \
      "$owner_role" \
      "$risk" \
      "$last_update" \
      "$next_gate" \
      "$blocker" \
      "$open_pr_count"
  done

  if ! repeat_or_once "$interval" "$once"; then
    break
  fi
done