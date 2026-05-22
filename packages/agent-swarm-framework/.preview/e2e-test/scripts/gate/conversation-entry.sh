#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE_SCRIPT="$SCRIPT_DIR/conversation-gate.sh"
DISPATCH_SCRIPT="$SCRIPT_DIR/command-dispatch.sh"

input_text=""
intent_type=""
existing_issue_number=""
has_edit_request="false"
draft_fields='{}'
is_small_task_candidate="false"
channel_type="vscode_chat"
bypass_requested="false"
bypass_reason=""
existing_issue_body=""
confirm="false"
dry_run="false"
issue_title=""

usage() {
  cat <<'EOF'
usage: ./scripts/gate/conversation-entry.sh \
  --input-text <text> \
  [--intent-type <question|explain|investigate|implement|small_fix>] \
  [--existing-issue-number <number>] \
  [--has-edit-request <true|false>] \
  [--draft-fields <json>] \
  [--is-small-task-candidate <true|false>] \
  [--channel-type <vscode_chat|vscode_editor|slack|other>] \
  [--bypass-requested <true|false>] \
  [--bypass-reason <emergency|external_factor|...>] \
  [--existing-issue-body <markdown>] \
  [--confirm <true|false>] \
  [--dry-run <true|false>] \
  [--issue-title <title>]

behavior:
  1) runs conversation-gate decision
  2) if intake_required=false -> returns continue decision JSON
  3) if intake_required=true -> prints fixed intake draft block
  4) with --confirm=true, creates/reuses issue and dispatches /intake (unless --dry-run=true)
EOF
}

require_bool() {
  local value="$1"
  local name="$2"
  if [[ "$value" != "true" && "$value" != "false" ]]; then
    echo "error: $name must be true or false" >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input-text)
      input_text="$2"
      shift 2
      ;;
    --intent-type)
      intent_type="$2"
      shift 2
      ;;
    --existing-issue-number)
      existing_issue_number="$2"
      shift 2
      ;;
    --has-edit-request)
      has_edit_request="$2"
      shift 2
      ;;
    --draft-fields)
      draft_fields="$2"
      shift 2
      ;;
    --is-small-task-candidate)
      is_small_task_candidate="$2"
      shift 2
      ;;
    --channel-type)
      channel_type="$2"
      shift 2
      ;;
    --bypass-requested)
      bypass_requested="$2"
      shift 2
      ;;
    --bypass-reason)
      bypass_reason="$2"
      shift 2
      ;;
    --existing-issue-body)
      existing_issue_body="$2"
      shift 2
      ;;
    --confirm)
      confirm="$2"
      shift 2
      ;;
    --dry-run)
      dry_run="$2"
      shift 2
      ;;
    --issue-title)
      issue_title="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$input_text" ]]; then
  echo "error: --input-text is required" >&2
  usage
  exit 1
fi

require_bool "$has_edit_request" "--has-edit-request"
require_bool "$is_small_task_candidate" "--is-small-task-candidate"
require_bool "$bypass_requested" "--bypass-requested"
require_bool "$confirm" "--confirm"
require_bool "$dry_run" "--dry-run"

if ! printf '%s' "$draft_fields" | jq -e . >/dev/null 2>&1; then
  echo "error: --draft-fields must be valid JSON" >&2
  exit 1
fi

if [[ ! -x "$GATE_SCRIPT" ]]; then
  echo "error: gate script not found: $GATE_SCRIPT" >&2
  exit 1
fi

gate_json="$("$GATE_SCRIPT" \
  --input-text "$input_text" \
  --intent-type "$intent_type" \
  --existing-issue-number "$existing_issue_number" \
  --has-edit-request "$has_edit_request" \
  --draft-fields "$draft_fields" \
  --is-small-task-candidate "$is_small_task_candidate" \
  --channel-type "$channel_type" \
  --bypass-requested "$bypass_requested" \
  --bypass-reason "$bypass_reason" \
  --existing-issue-body "$existing_issue_body")"

intake_required="$(printf '%s' "$gate_json" | jq -r '.intake_required')"
reason_code="$(printf '%s' "$gate_json" | jq -r '.reason_code')"
reason_message="$(printf '%s' "$gate_json" | jq -r '.reason_message')"
missing_fields_json="$(printf '%s' "$gate_json" | jq -c '.missing_fields')"

if [[ "$intake_required" != "true" ]]; then
  jq -cn \
    --arg status "continue" \
    --arg reason_code "$reason_code" \
    --arg reason_message "$reason_message" \
    --argjson gate "$gate_json" \
    '{status:$status, reason_code:$reason_code, reason_message:$reason_message, gate:$gate}'
  exit 0
fi

field_value() {
  local json="$1"
  local key="$2"
  printf '%s' "$json" | jq -r --arg k "$key" '
    if has($k) then
      (.[$k].value // "")
    elif ($k == "scope.in" and (.scope.in? != null)) then
      (.scope.in.value // "")
    elif ($k == "scope.out" and (.scope.out? != null)) then
      (.scope.out.value // "")
    else
      ""
    end
  '
}

goal="$(field_value "$draft_fields" "goal")"
scope_in="$(field_value "$draft_fields" "scope.in")"
scope_out="$(field_value "$draft_fields" "scope.out")"
acceptance="$(field_value "$draft_fields" "acceptance")"
priority="$(field_value "$draft_fields" "priority")"
constraints="$(field_value "$draft_fields" "constraints")"

if [[ -z "$issue_title" ]]; then
  issue_title="intake: ${input_text:0:60}"
fi

cat <<EOF
=== INTAKE_CONFIRMATION_BLOCK_BEGIN ===
type: orchestrator-intake
goal: ${goal}
scope.in: ${scope_in}
scope.out: ${scope_out}
constraints: ${constraints}
acceptance: ${acceptance}
priority: ${priority}
reason_code: ${reason_code}
reason_message: ${reason_message}
missing_fields: ${missing_fields_json}
=== INTAKE_CONFIRMATION_BLOCK_END ===
EOF

if [[ "$confirm" != "true" ]]; then
  jq -cn \
    --arg status "needs_confirmation" \
    --arg reason_code "$reason_code" \
    --arg reason_message "$reason_message" \
    --arg issue_title "$issue_title" \
    --argjson missing_fields "$missing_fields_json" \
    '{status:$status, reason_code:$reason_code, reason_message:$reason_message, issue_title:$issue_title, missing_fields:$missing_fields}'
  exit 0
fi

target_issue="$existing_issue_number"

if [[ -z "$target_issue" ]]; then
  if [[ "$dry_run" == "true" ]]; then
    target_issue="DRY_RUN_NEW_ISSUE"
  else
    body_file="$(mktemp)"
    cat >"$body_file" <<EOF
type: orchestrator-intake
goal: ${goal}
scope.in: ${scope_in}
scope.out: ${scope_out}
constraints: ${constraints}
acceptance: ${acceptance}
priority: ${priority}

## source

- channel_type: ${channel_type}
- reason_code: ${reason_code}
- reason_message: ${reason_message}
EOF
    issue_url="$(gh issue create --title "$issue_title" --body-file "$body_file")"
    target_issue="$(printf '%s' "$issue_url" | sed -E 's#.*/issues/([0-9]+)$#\1#')"
  fi
fi

if [[ "$dry_run" == "true" ]]; then
  jq -cn \
    --arg status "ready_to_dispatch" \
    --arg issue "$target_issue" \
    --arg dispatch_scope "issue:#$target_issue" \
    --arg reason_code "$reason_code" \
    --arg reason_message "$reason_message" \
    '{status:$status, issue:$issue, dispatch_scope:$dispatch_scope, reason_code:$reason_code, reason_message:$reason_message, dry_run:true}'
  exit 0
fi

if [[ ! -x "$DISPATCH_SCRIPT" ]]; then
  echo "error: dispatch script not found: $DISPATCH_SCRIPT" >&2
  exit 1
fi

dispatch_options="$(jq -cn --arg goal "$goal" --arg priority "$priority" '{goal:$goal, priority:$priority}')"
"$DISPATCH_SCRIPT" --issuer intake-manager --action /intake --scope "issue:#$target_issue" --options "$dispatch_options" >/dev/null

jq -cn \
  --arg status "dispatched" \
  --arg issue "$target_issue" \
  --arg reason_code "$reason_code" \
  --arg reason_message "$reason_message" \
  '{status:$status, issue:$issue, reason_code:$reason_code, reason_message:$reason_message, dispatched_command:"/intake"}'
