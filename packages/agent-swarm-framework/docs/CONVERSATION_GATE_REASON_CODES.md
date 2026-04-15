# Conversation Gate Reason Codes

This document defines the canonical `reason_code` list for the conversation gate in ASF.
These codes are used by the core decision engine and consumed by entry integrations (IDE/chat adapters).

## Scope

- Applies to the conversation gate output contract:
  - `intake_required`
  - `reason_code`
  - `reason_message`
  - `missing_fields[]`
- Applies to both new-intake and existing-issue-reuse paths.

## Naming Rules

- Use `SCREAMING_SNAKE_CASE`.
- Keep one semantic meaning per code.
- Keep code stable; change behavior via implementation, not ad-hoc renames.

## Output Contract Reference

```json
{
  "intake_required": true,
  "reason_code": "IMPLEMENTATION_MISSING_ACCEPTANCE",
  "reason_message": "Implementation request requires acceptance criteria.",
  "missing_fields": [
    {
      "field": "acceptance",
      "reason": "missing",
      "prompt_hint": "List concrete completion criteria."
    }
  ]
}
```

## Code Groups

### 1) Intake Required: Implementation Path

| reason_code | intake_required | Description |
|---|---:|---|
| IMPLEMENTATION_MISSING_GOAL | true | `goal` is missing for an implementation request. |
| IMPLEMENTATION_MISSING_ACCEPTANCE | true | `acceptance` is missing for an implementation request. |
| IMPLEMENTATION_MISSING_SCOPE_IN | true | `scope.in` is missing for an implementation request. |
| IMPLEMENTATION_MISSING_SCOPE_OUT | true | `scope.out` is missing where required by context. |
| IMPLEMENTATION_MISSING_CONSTRAINTS | true | Required constraints are missing for safe execution. |
| IMPLEMENTATION_MISSING_GOAL_ACCEPTANCE | true | Both `goal` and `acceptance` are missing. |
| IMPLEMENTATION_MISSING_MULTIPLE | true | Three or more required fields are missing. |
| IMPLEMENTATION_EXISTING_ISSUE_UNCLEAR | true | Existing issue is referenced but cannot be safely reused as intake. |
| IMPLEMENTATION_NEEDS_INTAKE_CONFIRMATION | true | Draft is present but explicit intake confirmation is still required. |

### 2) Intake Not Required: Exempt Path

| reason_code | intake_required | Description |
|---|---:|---|
| QUESTION_EXEMPT | false | Question-only intent; no implementation requested. |
| EXPLAIN_EXEMPT | false | Explanation-only intent; no implementation requested. |
| INVESTIGATE_EXEMPT | false | Investigation-only intent; no implementation requested. |
| SMALL_FIX_EXEMPT_MEETS_CRITERIA | false | Small fix candidate meets exemption conditions. |
| IMPLEMENTATION_EXISTING_ISSUE_REUSABLE | false | Existing issue contains required intake fields and can be reused. |

### 3) Exempt Rejected: Must Intake

| reason_code | intake_required | Description |
|---|---:|---|
| SMALL_FIX_REQUIRES_INTAKE | true | Small-fix candidate failed exemption conditions. |
| EXEMPTION_UNCLEAR_FALLBACK_INTAKE | true | Exemption judgment is unclear; fallback to intake-required path. |

### 4) Bypass Policy

| reason_code | intake_required | Description |
|---|---:|---|
| BYPASS_APPROVED_EMERGENCY | false | Bypass approved for emergency incident handling. |
| BYPASS_APPROVED_EXTERNAL_FACTOR | false | Bypass approved due to external blocking factor. |
| BYPASS_REJECTED_INVALID_REASON | true | Bypass requested with invalid or unsupported reason. |
| BYPASS_UNNECESSARY_INTAKE_COMPLETE | false | Bypass requested but intake is already complete. |

## `missing_fields[].reason` Values

Allowed values:
- `missing`
- `insufficient_detail`
- `conflicting_with_existing_issue`
- `required_for_risk_control`

## `missing_fields[].field` Values (initial)

- `goal`
- `scope.in`
- `scope.out`
- `acceptance`
- `priority`
- `constraints`

## Compatibility Policy

- Additive changes are backward compatible (new codes/fields allowed).
- Renaming or removing existing codes is breaking and must be versioned accordingly.
- Entry adapters should treat unknown `reason_code` as intake-required safe fallback unless explicitly exempted.
