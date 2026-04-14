#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VALIDATOR="$SCRIPT_DIR/command-validate.sh"
STATUS_SCRIPT="$SCRIPT_DIR/status.sh"
RUNTIME_DIR="$ROOT_DIR/orchestration/runtime"
LINE_STATE_FILE="$RUNTIME_DIR/line-states.json"
SLOTS_FILE="$RUNTIME_DIR/line-worker-slots.json"
CONSULT_STATE_FILE="$RUNTIME_DIR/consult-state.json"
ACTION_QUEUE_FILE="$RUNTIME_DIR/pending-actions.jsonl"

issuer=""
action=""
scope=""
options='{}'

usage() {
  cat <<'EOF'
usage: ./scripts/command-dispatch.sh --issuer <human|orchestrator|closer|implementer> --action <command> --scope <target> [--options <json>]

examples:
  ./scripts/command-dispatch.sh --issuer orchestrator --action "/status" --scope line:auto-001 --options '{"once":true}'
  ./scripts/command-dispatch.sh --issuer orchestrator --action "/pause" --scope line:auto-001
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

mkdir -p "$RUNTIME_DIR"

if ! printf '%s' "$options" | jq -e . >/dev/null 2>&1; then
  echo "error: --options must be valid JSON" >&2
  exit 1
fi

if [[ ! -x "$VALIDATOR" ]]; then
  echo "error: validator not found or not executable: $VALIDATOR" >&2
  exit 1
fi

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

new_action_id() {
  printf 'act-%s-%04d' "$(date +%s%N)" "$((RANDOM % 10000))"
}

line_ids_for_scope() {
  local target_scope="$1"
  local ids
  case "$target_scope" in
    all)
      if [[ -f "$SLOTS_FILE" ]]; then
        ids="$(jq -r '.slots[]?' "$SLOTS_FILE" 2>/dev/null | xargs echo)"
        if [[ -n "$ids" ]]; then
          echo "$ids"
        else
          echo "auto-001"
        fi
      elif [[ -f "$LINE_STATE_FILE" ]]; then
        ids="$(jq -r '.lines | keys[]?' "$LINE_STATE_FILE" 2>/dev/null | xargs echo)"
        if [[ -n "$ids" ]]; then
          echo "$ids"
        else
          echo "auto-001"
        fi
      else
        echo "auto-001"
      fi
      ;;
    line:*)
      echo "${target_scope#line:}"
      ;;
    *)
      echo ""
      ;;
  esac
}

log_line_event() {
  local line_id="$1"
  local event_type="$2"
  local state="$3"
  local note="$4"

  local event_file
  event_file="$RUNTIME_DIR/line-${line_id}-events.jsonl"

  printf '{"timestamp":"%s","line":"%s","issuer":"%s","command":"%s","scope":"%s","event_type":"%s","state":"%s","note":"%s"}\n' \
    "$(now_iso)" "$line_id" "$issuer" "$action" "$scope" "$event_type" "$state" "$note" >>"$event_file"
}

log_line_events_for_scope() {
  local event_type="$1"
  local state="$2"
  local note="$3"
  local lines line_id

  lines="$(line_ids_for_scope "$scope")"
  [[ -z "$lines" ]] && return 0

  for line_id in $lines; do
    log_line_event "$line_id" "$event_type" "$state" "$note"
  done
}

ensure_line_state_file() {
  if [[ ! -f "$LINE_STATE_FILE" ]]; then
    cat >"$LINE_STATE_FILE" <<'EOF'
{
  "all": "idle",
  "lines": {}
}
EOF
  fi
}

ensure_consult_state_file() {
  if [[ ! -f "$CONSULT_STATE_FILE" ]]; then
    cat >"$CONSULT_STATE_FILE" <<'EOF'
{
  "state": "inactive",
  "updated_at": ""
}
EOF
  fi
}

set_line_state() {
  local target_scope="$1"
  local new_state="$2"

  ensure_line_state_file

  if [[ "$target_scope" == "all" ]]; then
    local slots_json
    if [[ -f "$SLOTS_FILE" ]]; then
      slots_json="$(jq -c '.slots // []' "$SLOTS_FILE" 2>/dev/null || echo '[]')"
    else
      slots_json='["auto-001"]'
    fi

    tmp="$(mktemp)"
    jq --arg s "$new_state" --argjson slots "$slots_json" '
      .all = $s
      | .lines = (reduce $slots[] as $slot ({}; .[$slot] = $s))
    ' "$LINE_STATE_FILE" >"$tmp"
    mv "$tmp" "$LINE_STATE_FILE"
    log_line_events_for_scope "state_changed" "$new_state" "line state updated"
    return
  fi

  local line_id
  line_id="${target_scope#line:}"

  tmp="$(mktemp)"
  jq --arg line "$line_id" --arg s "$new_state" '.lines[$line] = $s' "$LINE_STATE_FILE" >"$tmp"
  mv "$tmp" "$LINE_STATE_FILE"
  log_line_event "$line_id" "state_changed" "$new_state" "line state updated"
}

set_consult_state() {
  local new_state="$1"

  ensure_consult_state_file

  tmp="$(mktemp)"
  jq --arg s "$new_state" --arg t "$(now_iso)" '.state = $s | .updated_at = $t' "$CONSULT_STATE_FILE" >"$tmp"
  mv "$tmp" "$CONSULT_STATE_FILE"
}

queue_action() {
  local message="$1"
  local action_id
  action_id="$(new_action_id)"

  printf '{"id":"%s","timestamp":"%s","issuer":"%s","command":"%s","scope":"%s","options":%s,"note":"%s"}\n' \
    "$action_id" "$(now_iso)" "$issuer" "$action" "$scope" "$options" "$message" >>"$ACTION_QUEUE_FILE"

  log_line_events_for_scope "queued" "unchanged" "$message"
}

run_validator() {
  local out
  if ! out="$($VALIDATOR --issuer "$issuer" --action "$action" --scope "$scope" --options "$options" 2>&1)"; then
    printf '%s\n' "$out" >&2
    return 1
  fi

  return 0
}

dispatch_status() {
  local once interval
  once="$(printf '%s' "$options" | jq -r '.once // false')"
  interval="$(printf '%s' "$options" | jq -r '.interval // empty')"

  cmd=("$STATUS_SCRIPT" "--scope" "$scope")

  if [[ -n "$interval" ]]; then
    cmd+=("--interval" "$interval")
  fi

  if [[ "$once" == "true" ]]; then
    cmd+=("--once")
  fi

  "${cmd[@]}"

  log_line_events_for_scope "observed" "unchanged" "status viewed"
}

run_validator

case "$action" in
  "/status")
    dispatch_status
    ;;
  "/start")
    set_line_state "$scope" "running"
    echo "dispatched: $action $scope"
    ;;
  "/pause")
    set_line_state "$scope" "paused"
    echo "dispatched: $action $scope"
    ;;
  "/resume")
    set_line_state "$scope" "running"
    echo "dispatched: $action $scope"
    ;;
  "/stop")
    set_line_state "$scope" "stopped"
    echo "dispatched: $action $scope"
    ;;
  "/abort")
    set_line_state "$scope" "aborted"
    echo "dispatched: $action $scope"
    ;;
  "/close line")
    set_line_state "$scope" "closed"
    echo "dispatched: $action $scope"
    ;;
  "/consult")
    set_consult_state "active"
    log_line_events_for_scope "consult" "unchanged" "consult session started"
    echo "dispatched: $action $scope"
    ;;
  "/log")
    set_consult_state "logged"
    log_line_events_for_scope "consult" "unchanged" "consult logged"
    echo "dispatched: $action $scope"
    ;;
  "/apply")
    set_consult_state "applied"
    log_line_events_for_scope "consult" "unchanged" "consult applied"
    echo "dispatched: $action $scope"
    ;;
  "/defer")
    set_consult_state "deferred"
    log_line_events_for_scope "consult" "unchanged" "consult deferred"
    echo "dispatched: $action $scope"
    ;;
  "/review"|"/merge"|"/close pr"|"/approve"|"/reject"|"/hold"|"/add line"|"/reassign"|"/escalate"|"/hotfix"|"/backlog"|"/implement")
    queue_action "accepted and queued for external/system integration"
    echo "queued: $action $scope"
    ;;
  *)
    echo "error: unsupported action: $action" >&2
    exit 1
    ;;
esac
