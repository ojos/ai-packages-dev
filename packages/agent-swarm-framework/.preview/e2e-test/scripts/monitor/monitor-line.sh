#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/monitor-common.sh"

interval="$DEFAULT_INTERVAL"
once="false"
line_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --line)
      line_id="$2"
      shift 2
      ;;
    --interval)
      interval="$2"
      shift 2
      ;;
    --once)
      once="true"
      shift
      ;;
    -h|--help)
      echo "usage: $0 --line <line-id> [--interval <sec>] [--once]"
      exit 0
      ;;
    *)
      echo "usage: $0 --line <line-id> [--interval <sec>] [--once]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$line_id" ]]; then
  echo "error: --line is required" >&2
  exit 1
fi

line_id="$(normalize_line_id "$line_id")"

management_issue="$(line_management_issue "$line_id")"
gate_issue="$(line_gate_issue "$line_id")"

if [[ -z "$management_issue" ]]; then
  management_issue="N/A"
fi
if [[ -z "$gate_issue" ]]; then
  gate_issue="N/A"
fi

while true; do
  clear
  print_header "terminal.monitor.line.${line_id}"

  gate_title="$(issue_title "$gate_issue")"
  current_gate="$(derive_gate_name "$gate_title")"
  gate_state="$(issue_state "$gate_issue")"
  work_status="$(derive_work_status "$line_id")"
  owner_role="$(derive_owner_role "$gate_issue")"
  risk="$(derive_risk "$management_issue")"
  blocker="$(derive_blocker "$management_issue" "$gate_issue")"
  last_update="$(line_last_update "$line_id")"

  echo 'gate timeline'
  render_gate_timeline "$current_gate" "$work_status"
  printf '\n'

  echo 'issue status'
  printf 'line: %s\n' "$(line_name "$line_id")"
  if [[ "$management_issue" == "N/A" ]]; then
    printf 'management_issue: %s\n' "$management_issue"
  else
    printf 'management_issue: #%s\n' "$management_issue"
  fi
  if [[ "$gate_issue" == "N/A" ]]; then
    printf 'gate_issue: %s\n' "$gate_issue"
  else
    printf 'gate_issue: #%s\n' "$gate_issue"
  fi
  printf 'gate_title: %s\n' "$gate_title"
  printf 'gate_state: %s\n' "$gate_state"
  printf 'work_status: %s\n' "$work_status"
  printf 'owner_role: %s\n' "$owner_role"
  printf 'risk: %s\n' "$risk"
  printf 'last_update: %s\n' "$last_update"
  printf 'blocker: %s\n\n' "$blocker"

  echo 'handoff latest'
  handoff_text="$(line_handoff_latest "$management_issue")"
  format_handoff_latest "$handoff_text"

  if ! repeat_or_once "$interval" "$once"; then
    break
  fi
done