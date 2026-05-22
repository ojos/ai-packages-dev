#!/usr/bin/env bash
set -euo pipefail

input_text=""
intent_type=""
existing_issue_number=""
has_edit_request="false"
draft_fields='{}'
is_small_task_candidate="false"
channel_type="other"
bypass_requested="false"
bypass_reason=""
existing_issue_body=""

usage() {
  cat <<'EOF'
usage: ./scripts/gate/conversation-gate.sh \
  --input-text <text> \
  [--intent-type <question|explain|investigate|implement|small_fix>] \
  [--existing-issue-number <number>] \
  [--has-edit-request <true|false>] \
  [--draft-fields <json>] \
  [--is-small-task-candidate <true|false>] \
  [--channel-type <vscode_chat|vscode_editor|slack|other>] \
  [--bypass-requested <true|false>] \
  [--bypass-reason <emergency|external_factor|...>] \
  [--existing-issue-body <markdown>]

output:
  JSON object with fields:
    - intake_required (boolean)
    - reason_code (string)
    - reason_message (string)
    - missing_fields (array)
EOF
}

json_result() {
  local intake_required="$1"
  local reason_code="$2"
  local reason_message="$3"
  local missing_fields_json="$4"

  jq -cn \
    --argjson intake_required "$intake_required" \
    --arg reason_code "$reason_code" \
    --arg reason_message "$reason_message" \
    --argjson missing_fields "$missing_fields_json" \
    '{intake_required:$intake_required, reason_code:$reason_code, reason_message:$reason_message, missing_fields:$missing_fields}'
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

if ! printf '%s' "$draft_fields" | jq -e . >/dev/null 2>&1; then
  echo "error: --draft-fields must be valid JSON" >&2
  exit 1
fi

case "$intent_type" in
  ""|question|explain|investigate|implement|small_fix) ;;
  *)
    echo "error: invalid --intent-type: $intent_type" >&2
    exit 1
    ;;
esac

case "$channel_type" in
  vscode_chat|vscode_editor|slack|other) ;;
  *)
    echo "error: invalid --channel-type: $channel_type" >&2
    exit 1
    ;;
esac

field_filled() {
  local json="$1"
  local key="$2"
  printf '%s' "$json" | jq -r --arg k "$key" '
    if has($k) then
      (.[$k].filled // false)
    elif ($k == "scope.in" and (.scope.in? != null)) then
      (.scope.in.filled // false)
    elif ($k == "scope.out" and (.scope.out? != null)) then
      (.scope.out.filled // false)
    else
      false
    end
  '
}

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

field_required() {
  local json="$1"
  local key="$2"
  printf '%s' "$json" | jq -r --arg k "$key" '
    if has($k) then
      (.[$k].required // false)
    elif ($k == "scope.out" and (.scope.out? != null)) then
      (.scope.out.required // false)
    elif ($k == "constraints" and (.constraints? != null)) then
      (.constraints.required // false)
    else
      false
    end
  '
}

extract_issue_field() {
  local body="$1"
  local key="$2"
  local lower
  lower="$(printf '%s' "$body" | tr '[:upper:]' '[:lower:]')"
  printf '%s\n' "$lower" | sed -n "s/^${key}[[:space:]]*:[[:space:]]*//p" | head -n 1
}

issue_draft_fields_from_body() {
  local body="$1"
  local goal acceptance priority scope_in scope_out constraints

  goal="$(extract_issue_field "$body" "goal")"
  scope_in="$(extract_issue_field "$body" "scope\.in")"
  scope_out="$(extract_issue_field "$body" "scope\.out")"
  acceptance="$(extract_issue_field "$body" "acceptance")"
  priority="$(extract_issue_field "$body" "priority")"
  constraints="$(extract_issue_field "$body" "constraints")"

  jq -cn \
    --arg goal "$goal" \
    --arg scope_in "$scope_in" \
    --arg scope_out "$scope_out" \
    --arg acceptance "$acceptance" \
    --arg priority "$priority" \
    --arg constraints "$constraints" '
    {
      goal: {value:$goal, filled:($goal|length>0), source_hint:"existing_issue"},
      scope: {
        in: {value:$scope_in, filled:($scope_in|length>0), source_hint:"existing_issue"},
        out: {value:$scope_out, filled:($scope_out|length>0), source_hint:"existing_issue"}
      },
      acceptance: {value:$acceptance, filled:($acceptance|length>0), source_hint:"existing_issue"},
      priority: {value:$priority, filled:($priority|length>0), source_hint:"existing_issue"},
      constraints: {value:$constraints, filled:($constraints|length>0), source_hint:"existing_issue"}
    }'
}

get_existing_issue_body() {
  if [[ -n "$existing_issue_body" ]]; then
    printf '%s' "$existing_issue_body"
    return
  fi
  if [[ -n "${CONVERSATION_GATE_ISSUE_BODY:-}" ]]; then
    printf '%s' "$CONVERSATION_GATE_ISSUE_BODY"
    return
  fi
  if [[ -n "$existing_issue_number" ]] && command -v gh >/dev/null 2>&1; then
    gh issue view "$existing_issue_number" --json body --jq '.body // ""' 2>/dev/null || true
    return
  fi
  printf ''
}

merge_draft_fields() {
  local base_json="$1"
  local issue_json="$2"
  printf '%s' "$base_json" | jq -c --argjson issue "$issue_json" '
    def choose($base; $fallback):
      if ($base.filled // false) == true then $base else $fallback end;
    {
      goal: choose((.goal // {}); ($issue.goal // {})),
      scope: {
        in: choose((.scope.in // {}); ($issue.scope.in // {})),
        out: choose((.scope.out // {}); ($issue.scope.out // {}))
      },
      acceptance: choose((.acceptance // {}); ($issue.acceptance // {})),
      priority: choose((.priority // {}); ($issue.priority // {})),
      constraints: choose((.constraints // {}); ($issue.constraints // {}))
    }
  '
}

effective_draft_fields() {
  local base_json="$1"
  if [[ -z "$existing_issue_number" ]]; then
    printf '%s' "$base_json"
    return
  fi
  local body
  body="$(get_existing_issue_body)"
  if [[ -z "$body" ]]; then
    printf '%s' "$base_json"
    return
  fi
  local issue_json
  issue_json="$(issue_draft_fields_from_body "$body")"
  merge_draft_fields "$base_json" "$issue_json"
}

missing_entry() {
  local field="$1"
  local reason="$2"
  local hint="$3"
  jq -cn --arg field "$field" --arg reason "$reason" --arg hint "$hint" '{field:$field, reason:$reason, prompt_hint:$hint}'
}

build_missing_fields() {
  local json="$1"
  local -a missing=()

  local goal_filled acceptance_filled scope_in_filled priority_filled
  goal_filled="$(field_filled "$json" "goal")"
  acceptance_filled="$(field_filled "$json" "acceptance")"
  scope_in_filled="$(field_filled "$json" "scope.in")"
  priority_filled="$(field_filled "$json" "priority")"

  if [[ "$goal_filled" != "true" ]]; then
    missing+=("$(missing_entry "goal" "missing" "実装の目的（goal）を1文で記述してください")")
  fi
  if [[ "$acceptance_filled" != "true" ]]; then
    missing+=("$(missing_entry "acceptance" "missing" "完了条件（acceptance）を検証可能な形で記述してください")")
  fi
  if [[ "$scope_in_filled" != "true" ]]; then
    missing+=("$(missing_entry "scope.in" "missing" "対象範囲（scope.in）を具体的に列挙してください")")
  fi
  if [[ "$priority_filled" != "true" ]]; then
    missing+=("$(missing_entry "priority" "missing" "優先度（priority）を high/medium/low のいずれかで指定してください")")
  fi

  local scope_out_required constraints_required scope_out_filled constraints_filled
  scope_out_required="$(field_required "$json" "scope.out")"
  constraints_required="$(field_required "$json" "constraints")"
  scope_out_filled="$(field_filled "$json" "scope.out")"
  constraints_filled="$(field_filled "$json" "constraints")"

  if [[ "$scope_out_required" == "true" && "$scope_out_filled" != "true" ]]; then
    missing+=("$(missing_entry "scope.out" "required_for_risk_control" "非対象範囲（scope.out）を明記してください")")
  fi
  if [[ "$constraints_required" == "true" && "$constraints_filled" != "true" ]]; then
    missing+=("$(missing_entry "constraints" "required_for_risk_control" "制約条件（constraints）を明記してください")")
  fi

  printf '%s\n' "${missing[@]}" | jq -sc .
}

choose_implementation_reason() {
  local missing_json="$1"
  local missing_count
  missing_count="$(printf '%s' "$missing_json" | jq 'length')"

  local has_goal has_acceptance has_scope_in has_scope_out has_constraints
  has_goal="$(printf '%s' "$missing_json" | jq -r '[.[] | select(.field=="goal")] | length > 0')"
  has_acceptance="$(printf '%s' "$missing_json" | jq -r '[.[] | select(.field=="acceptance")] | length > 0')"
  has_scope_in="$(printf '%s' "$missing_json" | jq -r '[.[] | select(.field=="scope.in")] | length > 0')"
  has_scope_out="$(printf '%s' "$missing_json" | jq -r '[.[] | select(.field=="scope.out")] | length > 0')"
  has_constraints="$(printf '%s' "$missing_json" | jq -r '[.[] | select(.field=="constraints")] | length > 0')"

  if [[ "$missing_count" -ge 3 ]]; then
    echo "IMPLEMENTATION_MISSING_MULTIPLE"
    return
  fi
  if [[ "$has_goal" == "true" && "$has_acceptance" == "true" ]]; then
    echo "IMPLEMENTATION_MISSING_GOAL_ACCEPTANCE"
    return
  fi
  if [[ "$has_goal" == "true" ]]; then
    echo "IMPLEMENTATION_MISSING_GOAL"
    return
  fi
  if [[ "$has_acceptance" == "true" ]]; then
    echo "IMPLEMENTATION_MISSING_ACCEPTANCE"
    return
  fi
  if [[ "$has_scope_in" == "true" ]]; then
    echo "IMPLEMENTATION_MISSING_SCOPE_IN"
    return
  fi
  if [[ "$has_scope_out" == "true" ]]; then
    echo "IMPLEMENTATION_MISSING_SCOPE_OUT"
    return
  fi
  if [[ "$has_constraints" == "true" ]]; then
    echo "IMPLEMENTATION_MISSING_CONSTRAINTS"
    return
  fi
  echo "IMPLEMENTATION_NEEDS_INTAKE_CONFIRMATION"
}

reason_message_for_code() {
  local code="$1"
  case "$code" in
    IMPLEMENTATION_MISSING_GOAL) echo "Implementation request requires a goal." ;;
    IMPLEMENTATION_MISSING_ACCEPTANCE) echo "Implementation request requires acceptance criteria." ;;
    IMPLEMENTATION_MISSING_SCOPE_IN) echo "Implementation request requires scope.in." ;;
    IMPLEMENTATION_MISSING_SCOPE_OUT) echo "Implementation request requires scope.out in this context." ;;
    IMPLEMENTATION_MISSING_CONSTRAINTS) echo "Implementation request requires constraints in this context." ;;
    IMPLEMENTATION_MISSING_GOAL_ACCEPTANCE) echo "Implementation request requires both goal and acceptance criteria." ;;
    IMPLEMENTATION_MISSING_MULTIPLE) echo "Implementation request is missing multiple required fields." ;;
    IMPLEMENTATION_EXISTING_ISSUE_UNCLEAR) echo "Existing issue reference is unclear for intake reuse." ;;
    IMPLEMENTATION_EXISTING_ISSUE_REUSABLE) echo "Existing issue can be reused as intake." ;;
    IMPLEMENTATION_NEEDS_INTAKE_CONFIRMATION) echo "Implementation requires explicit intake confirmation." ;;
    QUESTION_EXEMPT) echo "Question intent is exempt from intake." ;;
    EXPLAIN_EXEMPT) echo "Explain intent is exempt from intake." ;;
    INVESTIGATE_EXEMPT) echo "Investigate intent is exempt from intake." ;;
    SMALL_FIX_EXEMPT_MEETS_CRITERIA) echo "Small-fix candidate meets exemption criteria." ;;
    SMALL_FIX_REQUIRES_INTAKE) echo "Small-fix candidate does not meet exemption criteria and requires intake." ;;
    EXEMPTION_UNCLEAR_FALLBACK_INTAKE) echo "Exemption judgment is unclear; fallback to intake-required path." ;;
    BYPASS_APPROVED_EMERGENCY) echo "Bypass approved for emergency incident handling." ;;
    BYPASS_APPROVED_EXTERNAL_FACTOR) echo "Bypass approved due to external blocking factor." ;;
    BYPASS_REJECTED_INVALID_REASON) echo "Bypass rejected because the reason is invalid." ;;
    BYPASS_UNNECESSARY_INTAKE_COMPLETE) echo "Bypass is unnecessary because intake is already complete." ;;
    *) echo "Intake decision completed." ;;
  esac
}

has_required_intake_fields() {
  local json="$1"
  local goal_filled acceptance_filled scope_in_filled priority_filled
  goal_filled="$(field_filled "$json" "goal")"
  acceptance_filled="$(field_filled "$json" "acceptance")"
  scope_in_filled="$(field_filled "$json" "scope.in")"
  priority_filled="$(field_filled "$json" "priority")"

  [[ "$goal_filled" == "true" && "$acceptance_filled" == "true" && "$scope_in_filled" == "true" && "$priority_filled" == "true" ]]
}

decide_result() {
  local missing_json='[]'
  local draft_effective
  draft_effective="$(effective_draft_fields "$draft_fields")"

  if [[ "$bypass_requested" == "true" ]]; then
    if has_required_intake_fields "$draft_effective"; then
      local code="BYPASS_UNNECESSARY_INTAKE_COMPLETE"
      json_result false "$code" "$(reason_message_for_code "$code")" '[]'
      return
    fi
    case "$bypass_reason" in
      emergency)
        local code="BYPASS_APPROVED_EMERGENCY"
        json_result false "$code" "$(reason_message_for_code "$code")" '[]'
        return
        ;;
      external_factor)
        local code="BYPASS_APPROVED_EXTERNAL_FACTOR"
        json_result false "$code" "$(reason_message_for_code "$code")" '[]'
        return
        ;;
      *)
        local code="BYPASS_REJECTED_INVALID_REASON"
        json_result true "$code" "$(reason_message_for_code "$code")" '[]'
        return
        ;;
    esac
  fi

  case "$intent_type" in
    question)
      local code="QUESTION_EXEMPT"
      json_result false "$code" "$(reason_message_for_code "$code")" '[]'
      return
      ;;
    explain)
      local code="EXPLAIN_EXEMPT"
      json_result false "$code" "$(reason_message_for_code "$code")" '[]'
      return
      ;;
    investigate)
      local code="INVESTIGATE_EXEMPT"
      json_result false "$code" "$(reason_message_for_code "$code")" '[]'
      return
      ;;
    small_fix)
      if [[ "$is_small_task_candidate" == "true" ]]; then
        local code="SMALL_FIX_EXEMPT_MEETS_CRITERIA"
        json_result false "$code" "$(reason_message_for_code "$code")" '[]'
      else
        local code="SMALL_FIX_REQUIRES_INTAKE"
        json_result true "$code" "$(reason_message_for_code "$code")" '[]'
      fi
      return
      ;;
  esac

  if [[ "$intent_type" == "implement" || "$has_edit_request" == "true" || -n "$existing_issue_number" ]]; then
    missing_json="$(build_missing_fields "$draft_effective")"

    if [[ -n "$existing_issue_number" ]]; then
      if has_required_intake_fields "$draft_effective"; then
        local code="IMPLEMENTATION_EXISTING_ISSUE_REUSABLE"
        json_result false "$code" "$(reason_message_for_code "$code")" '[]'
      else
        local code="IMPLEMENTATION_EXISTING_ISSUE_UNCLEAR"
        json_result true "$code" "$(reason_message_for_code "$code")" "$missing_json"
      fi
      return
    fi

    local code
    code="$(choose_implementation_reason "$missing_json")"
    if [[ "$code" == "IMPLEMENTATION_NEEDS_INTAKE_CONFIRMATION" ]]; then
      json_result true "$code" "$(reason_message_for_code "$code")" '[]'
    else
      json_result true "$code" "$(reason_message_for_code "$code")" "$missing_json"
    fi
    return
  fi

  local fallback_code="EXEMPTION_UNCLEAR_FALLBACK_INTAKE"
  json_result true "$fallback_code" "$(reason_message_for_code "$fallback_code")" '[]'
}

decide_result
