#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/monitor/monitor-common.sh
source "$SCRIPT_DIR/../monitor/monitor-common.sh"

HISTORY_DIR="$SCRIPT_DIR/../orchestration/command-history"
RETENTION_DAYS=90
MAX_RECORDS=10000

issuer=""
action=""
scope=""
options='{}'

usage() {
  cat <<'EOF'
usage: ./scripts/command-validate.sh --issuer <human|intake-manager|consult-facilitator|orchestrator|closer|implementer> --action <command> --scope <target> [--options <json>]

examples:
  ./scripts/command-validate.sh --issuer orchestrator --action "/pause" --scope line:auto-001
  ./scripts/command-validate.sh --issuer human --action "/merge" --scope pr:#99
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issuer)
      issuer="$2"
      shift 2
      ;;
    --action)
      action="$2"
      shift 2
      ;;
    --scope)
      scope="$2"
      shift 2
      ;;
    --options)
      options="$2"
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

if [[ -z "$issuer" || -z "$action" || -z "$scope" ]]; then
  echo "error: --issuer, --action, --scope are required" >&2
  usage
  exit 1
fi

mkdir -p "$HISTORY_DIR"

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

json_escape() {
  printf '%s' "$1" | jq -Rsa .
}

pr_state() {
  local pr_number="$1"
  local data state merged draft reviews latest

  data="$(run_api "/repos/$REPO/pulls/$pr_number")"
  if [[ -z "$data" ]]; then
    echo "unknown"
    return
  fi

  state="$(printf '%s' "$data" | jq -r '.state // "unknown"')"
  merged="$(printf '%s' "$data" | jq -r '.merged // false')"
  draft="$(printf '%s' "$data" | jq -r '.draft // false')"

  if [[ "$state" == "closed" && "$merged" == "true" ]]; then
    echo "merged"
    return
  fi

  if [[ "$state" == "closed" ]]; then
    echo "closed"
    return
  fi

  if [[ "$draft" == "true" ]]; then
    echo "draft"
    return
  fi

  reviews="$(run_api "/repos/$REPO/pulls/$pr_number/reviews?per_page=100" --jq '.[].state' 2>/dev/null || true)"
  latest="$(printf '%s\n' "$reviews" | awk 'NF {last=$0} END {print last}')"

  case "$latest" in
    APPROVED) echo "approved" ;;
    CHANGES_REQUESTED) echo "changes_requested" ;;
    *) echo "open" ;;
  esac
}

line_state_from_history() {
  local target_scope="$1"
  local state="idle"

  shopt -s nullglob
  local files=("$HISTORY_DIR"/*.jsonl)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    echo "$state"
    return
  fi

  local line command result rec_scope
  for file in "${files[@]}"; do
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      result="$(printf '%s' "$line" | jq -r '.result // ""' 2>/dev/null || echo "")"
      [[ "$result" != "allowed" ]] && continue

      rec_scope="$(printf '%s' "$line" | jq -r '.scope // ""' 2>/dev/null || echo "")"
      [[ "$rec_scope" != "$target_scope" ]] && continue

      command="$(printf '%s' "$line" | jq -r '.command // ""' 2>/dev/null || echo "")"
      case "$command" in
        "/start") state="running" ;;
        "/pause") state="paused" ;;
        "/resume") state="running" ;;
        "/stop") state="stopped" ;;
        "/abort") state="aborted" ;;
        "/close line") state="closed" ;;
      esac
    done <"$file"
  done

  echo "$state"
}

pr_reviewed_in_history() {
  local target_scope="$1"

  shopt -s nullglob
  local files=("$HISTORY_DIR"/*.jsonl)
  shopt -u nullglob

  [[ ${#files[@]} -eq 0 ]] && return 1

  local rec line command result rec_scope
  for file in "${files[@]}"; do
    while IFS= read -r rec; do
      [[ -z "$rec" ]] && continue
      result="$(printf '%s' "$rec" | jq -r '.result // ""' 2>/dev/null || echo "")"
      [[ "$result" != "allowed" ]] && continue

      rec_scope="$(printf '%s' "$rec" | jq -r '.scope // ""' 2>/dev/null || echo "")"
      [[ "$rec_scope" != "$target_scope" ]] && continue

      command="$(printf '%s' "$rec" | jq -r '.command // ""' 2>/dev/null || echo "")"
      [[ "$command" == "/review" ]] && return 0
    done <"$file"
  done

  return 1
}

allowed_for_issuer() {
  local who="$1"
  local cmd="$2"

  if [[ "$cmd" == "/status" ]]; then
    return 0
  fi

  case "$who" in
    human)
      case "$cmd" in
        "/approve"|"/merge"|"/abort"|"/reject") return 0 ;;
        *) return 1 ;;
      esac
      ;;
    orchestrator)
      case "$cmd" in
        "/start"|"/pause"|"/resume"|"/stop"|"/add line"|"/close line"|"/reassign"|"/escalate"|"/hotfix"|"/backlog"|"/hold"|"/defer"|"/apply"|"/implement") return 0 ;;
        *) return 1 ;;
      esac
      ;;
    intake-manager)
      case "$cmd" in
        "/intake"|"/consult"|"/log"|"/apply"|"/defer") return 0 ;;
        *) return 1 ;;
      esac
      ;;
    consult-facilitator)
      case "$cmd" in
        "/consult"|"/log"|"/apply"|"/defer") return 0 ;;
        *) return 1 ;;
      esac
      ;;
    closer)
      case "$cmd" in
        "/review"|"/close pr") return 0 ;;
        *) return 1 ;;
      esac
      ;;
    implementer)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

validate_scope_shape() {
  local cmd="$1"
  local tgt="$2"

  case "$cmd" in
    "/intake")
      [[ "$tgt" =~ ^issue:#[0-9]+$ ]] || return 1
      ;;
    "/start"|"/pause"|"/resume"|"/stop"|"/abort")
      [[ "$tgt" == "all" || "$tgt" =~ ^line:.+ ]] || return 1
      ;;
    "/implement")
      [[ "$tgt" =~ ^line:[a-z0-9][a-z0-9-]*$ ]] || return 1
      ;;
    "/add line"|"/hotfix"|"/escalate"|"/backlog")
      [[ "$tgt" =~ ^issue:#[0-9]+$ ]] || return 1
      ;;
    "/close line")
      [[ "$tgt" =~ ^line:.+$ ]] || return 1
      ;;
    "/reassign")
      [[ "$tgt" =~ ^line:.+$ || "$tgt" =~ ^issue:#[0-9]+$ ]] || return 1
      ;;
    "/approve")
      [[ "$tgt" == "plan" ]] || return 1
      ;;
    "/reject"|"/hold")
      [[ "$tgt" == "plan" || "$tgt" =~ ^pr:#[0-9]+$ ]] || return 1
      ;;
    "/review"|"/merge"|"/close pr")
      [[ "$tgt" =~ ^pr:#[0-9]+$ ]] || return 1
      ;;
    "/consult"|"/log"|"/apply"|"/defer")
      [[ "$tgt" == "consult" ]] || return 1
      ;;
    "/status")
      [[ "$tgt" == "all" || "$tgt" == "gate" || "$tgt" == "consult" || "$tgt" =~ ^line:.+$ || "$tgt" =~ ^issue:#[0-9]+$ || "$tgt" =~ ^pr:#[0-9]+$ ]] || return 1
      ;;
    *)
      return 1
      ;;
  esac

  return 0
}

validate_transition() {
  local cmd="$1"
  local tgt="$2"

  case "$cmd" in
    "/pause"|"/resume"|"/stop"|"/close line"|"/abort")
      if [[ "$tgt" =~ ^line:.+$ ]]; then
        local line_state
        line_state="$(line_state_from_history "$tgt")"

        case "$cmd" in
          "/pause") [[ "$line_state" == "running" ]] || return 1 ;;
          "/resume") [[ "$line_state" == "paused" ]] || return 1 ;;
          "/stop") [[ "$line_state" == "running" || "$line_state" == "paused" ]] || return 1 ;;
          "/close line") [[ "$line_state" == "stopped" || "$line_state" == "aborted" ]] || return 1 ;;
          "/abort") [[ "$line_state" != "closed" ]] || return 1 ;;
        esac
      fi
      ;;
    "/review"|"/merge"|"/close pr")
      local pr_number prst
      pr_number="${tgt#pr:#}"
      prst="$(pr_state "$pr_number")"

      case "$cmd" in
        "/review") [[ "$prst" == "open" || "$prst" == "draft" ]] || return 1 ;;
        "/merge") [[ "$prst" == "approved" ]] || pr_reviewed_in_history "$tgt" || return 1 ;;
        "/close pr") [[ "$prst" == "open" || "$prst" == "draft" || "$prst" == "changes_requested" ]] || return 1 ;;
      esac
      ;;
  esac

  return 0
}

enforce_retention() {
  find "$HISTORY_DIR" -type f -name '*.jsonl' -mtime +"$RETENTION_DAYS" -delete || true

  local total
  total="$(find "$HISTORY_DIR" -type f -name '*.jsonl' -print0 | xargs -0 cat 2>/dev/null | wc -l | tr -d ' ')"
  [[ -z "$total" ]] && total=0

  if (( total <= MAX_RECORDS )); then
    return
  fi

  local f lines
  while (( total > MAX_RECORDS )); do
    f="$(find "$HISTORY_DIR" -type f -name '*.jsonl' | sort | head -n 1)"
    [[ -z "$f" ]] && break
    lines="$(wc -l <"$f" | tr -d ' ')"
    rm -f "$f"
    total=$((total - lines))
  done
}

write_history() {
  local result="$1"
  local reason="$2"
  local log_file
  log_file="$HISTORY_DIR/$(date +%F).jsonl"

  local ts issuer_json command_json scope_json options_json reason_json
  ts="$(now_iso)"
  issuer_json="$(json_escape "$issuer")"
  command_json="$(json_escape "$action")"
  scope_json="$(json_escape "$scope")"
  options_json="$options"
  reason_json="$(json_escape "$reason")"

  if ! printf '%s' "$options_json" | jq -e . >/dev/null 2>&1; then
    options_json='{}'
  fi

  printf '{"timestamp":"%s","issuer":%s,"command":%s,"scope":%s,"options":%s,"result":"%s","reason":%s}\n' \
    "$ts" "$issuer_json" "$command_json" "$scope_json" "$options_json" "$result" "$reason_json" >>"$log_file"

  enforce_retention
}

deny() {
  local reason="$1"
  write_history "denied" "$reason"
  printf 'denied\nreason: %s\n' "$reason"
  exit 2
}

allow() {
  local reason="$1"
  write_history "allowed" "$reason"
  printf 'allowed\nreason: %s\n' "$reason"
  exit 0
}

if ! allowed_for_issuer "$issuer" "$action"; then
  deny "issuer '$issuer' is not allowed to execute '$action'"
fi

if ! validate_scope_shape "$action" "$scope"; then
  deny "invalid scope '$scope' for command '$action'"
fi

if ! validate_transition "$action" "$scope"; then
  deny "state transition is not allowed for command '$action' on scope '$scope'"
fi

allow "validation passed"
