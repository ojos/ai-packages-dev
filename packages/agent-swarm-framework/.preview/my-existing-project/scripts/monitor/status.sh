#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/monitor-common.sh"

RUNTIME_DIR="$(cd "$(dirname "$0")/.." && pwd)/orchestration/runtime"
HISTORY_DIR="$(cd "$(dirname "$0")/.." && pwd)/orchestration/command-history"

scope="all"
interval="$DEFAULT_INTERVAL"
once="false"

usage() {
  cat <<'EOF'
usage: ./scripts/status.sh [--scope <target>] [--interval <sec>] [--once]

scope:
  all            dynamic line overview + merge queue
  line:<name>    line detail (dynamic line-id)
  gate           merge queue
  issue:#<num>   issue status and allowed commands
  pr:#<num>      pull request status and allowed commands
EOF
}

dynamic_line_ids() {
  local ids
  ids=""

  if [[ -f "$RUNTIME_DIR/line-worker-slots.json" ]]; then
    ids="$(jq -r '.slots[]?' "$RUNTIME_DIR/line-worker-slots.json" 2>/dev/null | xargs echo)"
  fi

  if [[ -z "$ids" && -f "$RUNTIME_DIR/line-states.json" ]]; then
    ids="$(jq -r '.lines | keys[]?' "$RUNTIME_DIR/line-states.json" 2>/dev/null | xargs echo)"
  fi

  if [[ -z "$ids" ]]; then
    ids="$(ls "$RUNTIME_DIR"/pids/line-*-worker.pid 2>/dev/null | sed -E 's#^.*/line-(.+)-worker\.pid$#\1#' | xargs echo)"
  fi

  if [[ -z "$ids" ]]; then
    ids="auto-001"
  fi

  printf '%s' "$ids"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      scope="$2"
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

print_overview() {
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
}

print_line() {
  local line_id="$1"

  local logical_state queue_size
  logical_state="$(jq -r --arg line "$line_id" '.lines[$line] // .all // "unknown"' "$RUNTIME_DIR/line-states.json" 2>/dev/null || echo "unknown")"
  queue_size="$(wc -l <"$RUNTIME_DIR/line-${line_id}-queue.jsonl" 2>/dev/null | tr -d ' ' || echo 0)"

  local last_transition
  last_transition="$(line_last_transition "$line_id")"
  local worker_state worker_last_log
  worker_state="$(line_worker_state "$line_id")"
  worker_last_log="$(line_worker_last_log "$line_id")"

  echo 'line status'
  printf 'line: %s\n' "$line_id"
  printf 'logical_state: %s\n' "$logical_state"
  printf 'queue_size: %s\n' "$queue_size"
  printf 'last_transition: %s\n' "$last_transition"
  printf 'worker_state: %s\n' "$worker_state"
  printf 'worker_last_log: %s\n' "$worker_last_log"
  printf '\n'

  echo 'allowed_commands'
  case "$logical_state" in
    paused)
      echo '/resume /stop /abort'
      ;;
    closed)
      echo '/close line'
      ;;
    *)
      echo '/pause /stop /abort'
      ;;
  esac
}

line_last_transition() {
  local line_id="$1"
  local event_file line
  event_file="$RUNTIME_DIR/line-${line_id}-events.jsonl"

  if [[ ! -f "$event_file" ]]; then
    echo "none"
    return
  fi

  line="$(tail -n 1 "$event_file" 2>/dev/null || true)"
  if [[ -z "$line" ]]; then
    echo "none"
    return
  fi

  printf '%s' "$line" | jq -r '"\(.timestamp) \(.issuer) \(.command) -> \(.event_type) (state=\(.state))"' 2>/dev/null || echo "none"
}

line_worker_state() {
  local line_id="$1"
  local pid_file pid
  pid_file="$RUNTIME_DIR/pids/line-${line_id}-worker.pid"

  if [[ ! -f "$pid_file" ]]; then
    echo "stopped"
    return
  fi

  pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "running(pid=$pid)"
  else
    echo "stopped"
  fi
}

line_worker_last_log() {
  local line_id="$1"
  local process_log
  process_log="$RUNTIME_DIR/line-${line_id}-process.log"

  if [[ ! -f "$process_log" ]]; then
    echo "none"
    return
  fi

  tail -n 1 "$process_log" 2>/dev/null || echo "none"
}

pr_reviewed_in_history() {
  local target_scope="$1"

  shopt -s nullglob
  local files=("$HISTORY_DIR"/*.jsonl)
  shopt -u nullglob

  [[ ${#files[@]} -eq 0 ]] && return 1

  local rec command result rec_scope
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

pr_state_and_allowed() {
  local pr_number="$1"
  local data state merged draft

  data="$(run_api "/repos/$REPO/pulls/$pr_number")"
  if [[ -z "$data" ]]; then
    echo 'state=unknown'
    echo 'allowed=none'
    return
  fi

  state="$(printf '%s' "$data" | jq -r '.state // "unknown"')"
  merged="$(printf '%s' "$data" | jq -r '.merged // false')"
  draft="$(printf '%s' "$data" | jq -r '.draft // false')"

  if [[ "$state" == "closed" && "$merged" == "true" ]]; then
    echo 'state=merged'
    echo 'allowed=none'
    return
  fi

  if [[ "$state" == "closed" ]]; then
    echo 'state=closed'
    echo 'allowed=none'
    return
  fi

  if [[ "$draft" == "true" ]]; then
    if pr_reviewed_in_history "pr:#$pr_number"; then
      echo 'state=reviewed'
      echo 'allowed=/merge'
    else
      echo 'state=draft'
      echo 'allowed=/review /close pr'
    fi
    return
  fi

  local reviews latest
  reviews="$(run_api "/repos/$REPO/pulls/$pr_number/reviews?per_page=100" --jq '.[].state' 2>/dev/null || true)"
  latest="$(printf '%s\n' "$reviews" | awk 'NF { last=$0 } END { print last }')"

  case "$latest" in
    APPROVED)
      echo 'state=approved'
      echo 'allowed=/merge'
      ;;
    CHANGES_REQUESTED)
      echo 'state=changes_requested'
      echo 'allowed=push update or /close pr'
      ;;
    *)
      if pr_reviewed_in_history "pr:#$pr_number"; then
        echo 'state=reviewed'
        echo 'allowed=/merge'
      else
        echo 'state=open'
        echo 'allowed=/review /close pr'
      fi
      ;;
  esac
}

print_pr() {
  local pr_number="$1"
  local data

  data="$(run_api "/repos/$REPO/pulls/$pr_number")"
  if [[ -z "$data" ]]; then
    echo "pr: #$pr_number"
    echo 'state: unknown'
    echo 'allowed_commands: none'
    echo 'reason: unable to fetch pull request'
    return
  fi

  local title head_ref base_ref author updated_at
  title="$(printf '%s' "$data" | jq -r '.title // ""')"
  head_ref="$(printf '%s' "$data" | jq -r '.head.ref // ""')"
  base_ref="$(printf '%s' "$data" | jq -r '.base.ref // ""')"
  author="$(printf '%s' "$data" | jq -r '.user.login // ""')"
  updated_at="$(printf '%s' "$data" | jq -r '.updated_at // ""')"

  local state_and_allowed state_line allowed_line
  state_and_allowed="$(pr_state_and_allowed "$pr_number")"
  state_line="$(printf '%s\n' "$state_and_allowed" | sed -n '1p')"
  allowed_line="$(printf '%s\n' "$state_and_allowed" | sed -n '2p')"

  echo "pr: #$pr_number"
  printf 'title: %s\n' "$title"
  printf 'author: %s\n' "$author"
  printf 'head: %s -> base: %s\n' "$head_ref" "$base_ref"
  printf 'updated_at: %s\n' "$updated_at"
  printf 'state: %s\n' "${state_line#state=}"
  printf 'allowed_commands: %s\n' "${allowed_line#allowed=}"
}

issue_state_and_allowed() {
  local issue_number="$1"
  local state labels

  state="$(issue_state "$issue_number" | tr '[:upper:]' '[:lower:]')"
  labels="$(run_api "/repos/$REPO/issues/$issue_number" --jq '.labels[].name' 2>/dev/null || true)"

  if [[ "$state" == "closed" ]]; then
    echo 'state=closed'
    echo 'allowed=none'
    return
  fi

  if printf '%s\n' "$labels" | grep -qi 'deferred\|backlog'; then
    echo 'state=deferred'
    echo 'allowed=/start /escalate'
    return
  fi

  if printf '%s\n' "$labels" | grep -qi 'blocked'; then
    echo 'state=blocked'
    echo 'allowed=/consult /defer /hotfix'
    return
  fi

  if printf '%s\n' "$labels" | grep -qi 'hotfix'; then
    echo 'state=hotfix'
    echo 'allowed=/review /merge after approval'
    return
  fi

  echo 'state=in_progress'
  echo 'allowed=/pause /defer /escalate /hotfix'
}

print_issue() {
  local issue_number="$1"
  local data

  data="$(run_api "/repos/$REPO/issues/$issue_number")"
  if [[ -z "$data" ]]; then
    echo "issue: #$issue_number"
    echo 'state: unknown'
    echo 'allowed_commands: none'
    echo 'reason: unable to fetch issue'
    return
  fi

  local title author updated_at github_state
  title="$(printf '%s' "$data" | jq -r '.title // ""')"
  author="$(printf '%s' "$data" | jq -r '.user.login // ""')"
  updated_at="$(printf '%s' "$data" | jq -r '.updated_at // ""')"
  github_state="$(printf '%s' "$data" | jq -r '.state // ""')"

  local state_and_allowed state_line allowed_line
  state_and_allowed="$(issue_state_and_allowed "$issue_number")"
  state_line="$(printf '%s\n' "$state_and_allowed" | sed -n '1p')"
  allowed_line="$(printf '%s\n' "$state_and_allowed" | sed -n '2p')"

  echo "issue: #$issue_number"
  printf 'title: %s\n' "$title"
  printf 'author: %s\n' "$author"
  printf 'github_state: %s\n' "$github_state"
  printf 'updated_at: %s\n' "$updated_at"
  printf 'state: %s\n' "${state_line#state=}"
  printf 'allowed_commands: %s\n' "${allowed_line#allowed=}"
}

print_gate() {
  echo 'pr_number | from_line | issue | review_status | merge_readiness | reason_waiting'

  local rows
  rows="$(run_api "/repos/$REPO/pulls?state=open&per_page=100" --jq '.[] | [.number, .title, .head.ref] | @tsv' 2>/dev/null || true)"
  if [[ -z "$rows" ]]; then
    echo 'none | none | none | none | none | no open pull requests'
    return
  fi

  while IFS=$'\t' read -r pr_number title head_ref; do
    local from_line
    from_line="unknown"
    if printf '%s' "$head_ref" | grep -qi 'auto-[0-9]\+'; then
      from_line="$(printf '%s' "$head_ref" | grep -oiE 'auto-[0-9]+' | head -1)"
    elif printf '%s %s' "$title" "$head_ref" | grep -qi 'hotfix'; then
      from_line='Hotfix'
    fi

    printf '#%s | %s | %s | %s | %s | %s\n' \
      "$pr_number" \
      "$from_line" \
      "$title" \
      'pending' \
      'pending' \
      'awaiting closer review and merge decision'
  done <<< "$rows"
}

print_consult() {
  local consult_state_file consult_log_file state updated_at blocking lines last_log
  consult_state_file="$RUNTIME_DIR/consult-state.json"
  consult_log_file="$RUNTIME_DIR/consult-log.jsonl"

  if [[ ! -f "$consult_state_file" ]]; then
    echo 'scope: consult'
    echo 'state: inactive'
    echo 'blocking: false'
    echo 'lines: []'
    echo 'last_log: none'
    echo 'allowed_commands: /consult /log /apply /defer'
    return
  fi

  state="$(jq -r '.state // "inactive"' "$consult_state_file" 2>/dev/null || echo inactive)"
  updated_at="$(jq -r '.updated_at // ""' "$consult_state_file" 2>/dev/null || true)"
  blocking="$(jq -r '.blocking // false' "$consult_state_file" 2>/dev/null || echo false)"
  lines="$(jq -c '.lines // []' "$consult_state_file" 2>/dev/null || echo '[]')"

  if [[ -f "$consult_log_file" ]]; then
    last_log="$(tail -n 1 "$consult_log_file" 2>/dev/null || true)"
  else
    last_log=""
  fi

  echo 'scope: consult'
  printf 'state: %s\n' "$state"
  printf 'updated_at: %s\n' "${updated_at:-none}"
  printf 'blocking: %s\n' "$blocking"
  printf 'lines: %s\n' "$lines"
  if [[ -n "$last_log" ]]; then
    printf 'last_log: %s\n' "$(printf '%s' "$last_log" | jq -r '"\(.timestamp) \(.issuer) \(.command) state=\(.state)"' 2>/dev/null || echo present)"
  else
    echo 'last_log: none'
  fi
  echo 'allowed_commands: /consult /log /apply /defer'
}

print_scope() {
  local line_ids line_id
  case "$scope" in
    all)
      echo '[overview]'
      echo 'line | logical_state | worker_state | queue_size | last_transition'
      line_ids="$(dynamic_line_ids)"
      for line_id in $line_ids; do
        logical_state="$(jq -r --arg line "$line_id" '.lines[$line] // .all // "unknown"' "$RUNTIME_DIR/line-states.json" 2>/dev/null || echo "unknown")"
        worker_state="$(line_worker_state "$line_id")"
        queue_size="$(wc -l <"$RUNTIME_DIR/line-${line_id}-queue.jsonl" 2>/dev/null | tr -d ' ' || echo 0)"
        last_transition="$(line_last_transition "$line_id")"
        printf '%s | %s | %s | %s | %s\n' "$line_id" "$logical_state" "$worker_state" "$queue_size" "$last_transition"
      done
      echo
      echo '[gate]'
      print_gate
      echo
      echo '[consult]'
      print_consult
      ;;
    line:*)
      print_line "${scope#line:}"
      ;;
    gate)
      print_gate
      ;;
    issue:#*)
      print_issue "${scope#issue:#}"
      ;;
    pr:#*)
      print_pr "${scope#pr:#}"
      ;;
    consult)
      print_consult
      ;;
    *)
      echo "error: unsupported scope: $scope" >&2
      usage
      exit 1
      ;;
  esac
}

while true; do
  clear
  print_header "terminal.monitor.status"
  printf 'scope: %s\n\n' "$scope"
  print_scope

  if ! repeat_or_once "$interval" "$once"; then
    break
  fi
done
