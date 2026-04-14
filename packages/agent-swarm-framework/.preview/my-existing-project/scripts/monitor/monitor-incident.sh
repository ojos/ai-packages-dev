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
  print_header "terminal.monitor.incident"
  echo 'line | incident_type | blocked_since | current_blocker | required_action | resume_condition'

  for line_id in "${LINE_IDS[@]}"; do
    management_issue="$(line_management_issue "$line_id")"
    gate_issue="$(line_gate_issue "$line_id")"
    work_status="$(derive_work_status "$line_id")"

    if [[ "$work_status" != "paused" && "$work_status" != "blocked" ]]; then
      continue
    fi

    case "$work_status" in
      paused) incident_type="incident" ;;
      blocked) incident_type="blocked" ;;
      *) incident_type="attention" ;;
    esac

    blocked_since="$(issue_updated_at "$management_issue")"
    current_blocker="$(derive_blocker "$management_issue" "$gate_issue")"
    required_action="owner reply or monitoring fix"
    resume_condition="#96 accepted and #87 restart approved"

    printf '%s | %s | %s | %s | %s | %s\n' \
      "$(line_name "$line_id")" \
      "$incident_type" \
      "$blocked_since" \
      "$current_blocker" \
      "$required_action" \
      "$resume_condition"
  done

  if ! repeat_or_once "$interval" "$once"; then
    break
  fi
done