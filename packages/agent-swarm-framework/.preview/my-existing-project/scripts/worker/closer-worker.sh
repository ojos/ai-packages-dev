#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/monitor-common.sh
source "$SCRIPT_DIR/monitor-common.sh"
RUNTIME_DIR="$SCRIPT_DIR/../orchestration/runtime"
PID_DIR="$RUNTIME_DIR/pids"

ROOT_DIR="$SCRIPT_DIR/.."
DISPATCH_SCRIPT="$SCRIPT_DIR/command-dispatch.sh"

interval="15"
once="false"
auto_execute="false"
max_retries="${CLOSER_WORKER_MAX_RETRIES:-${WORKER_MAX_RETRIES:-3}}"

usage() {
  cat <<'EOF'
usage: ./scripts/closer-worker.sh [--interval <sec>] [--once] [--auto-execute]
EOF
}

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
    --auto-execute)
      auto_execute="true"
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

mkdir -p "$RUNTIME_DIR" "$PID_DIR"

QUEUE_FILE="$RUNTIME_DIR/closer-queue.jsonl"
PROCESSED_FILE="$RUNTIME_DIR/closer-processed.ids"
PROCESS_LOG="$RUNTIME_DIR/closer-process.log"
PID_FILE="$PID_DIR/closer-worker.pid"
ATTEMPT_FILE="$RUNTIME_DIR/closer-attempts.tsv"
DEAD_LETTER_FILE="$RUNTIME_DIR/closer-dead-letter.jsonl"
AUTO_REVIEW_TRACK_FILE="$RUNTIME_DIR/closer-auto-review-tracked.txt"

touch "$QUEUE_FILE" "$PROCESSED_FILE" "$PROCESS_LOG" "$ATTEMPT_FILE" "$DEAD_LETTER_FILE" "$AUTO_REVIEW_TRACK_FILE"
printf '%s\n' "$BASHPID" >"$PID_FILE"

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_process() {
  printf '[%s] %s\n' "$(now_iso)" "$1" >>"$PROCESS_LOG"
}

json_field() {
  local line="$1"
  local jq_expr="$2"
  printf '%s' "$line" | jq -r "$jq_expr" 2>/dev/null || true
}

extract_pr_number() {
  local scope="$1"
  if [[ "$scope" =~ ^pr:#([0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

should_execute() {
  local line="$1"
  local opt_exec env_exec
  opt_exec="$(json_field "$line" '.options.execute // false')"
  env_exec="${CLOSER_AUTO_EXECUTE:-false}"

  if [[ "$auto_execute" == "true" || "$env_exec" == "true" || "$opt_exec" == "true" ]]; then
    return 0
  fi
  return 1
}

is_true() {
  local value="${1:-false}"
  case "$value" in
    true|1|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

merge_selector() {
  local line="$1"
  local policy approved checks_passed blocking_findings

  policy="$(json_field "$line" '.options.policy // .options.mergePolicy // "manual"')"
  approved="$(json_field "$line" '.options.approved // false')"
  checks_passed="$(json_field "$line" '.options.checksPassed // false')"
  blocking_findings="$(json_field "$line" '.options.blockingFindings // false')"

  case "$policy" in
    auto|conditional)
      if is_true "$approved" && is_true "$checks_passed" && ! is_true "$blocking_findings"; then
        printf 'auto:policy=%s,approved=%s,checksPassed=%s,blockingFindings=%s' "$policy" "$approved" "$checks_passed" "$blocking_findings"
        return
      fi

      local reason="policy=$policy"
      if ! is_true "$approved"; then
        reason+=";missing=approved"
      fi
      if ! is_true "$checks_passed"; then
        reason+=";missing=checksPassed"
      fi
      if is_true "$blocking_findings"; then
        reason+=";blockingFindings=true"
      fi
      printf 'manual:%s' "$reason"
      return
      ;;
    manual)
      printf 'manual:policy=manual'
      return
      ;;
    *)
      printf 'manual:policy=unknown(%s)' "$policy"
      return
      ;;
  esac
}

already_processed() {
  local id="$1"
  grep -Fxq "$id" "$PROCESSED_FILE"
}

mark_processed() {
  local id="$1"
  printf '%s\n' "$id" >>"$PROCESSED_FILE"
}

attempt_count() {
  local id="$1"
  awk -v key="$id" '$1==key {count=$2} END {print count+0}' "$ATTEMPT_FILE"
}

set_attempt_count() {
  local id="$1"
  local count="$2"
  local tmp
  tmp="$(mktemp)"
  awk -v key="$id" '$1!=key {print $0}' "$ATTEMPT_FILE" >"$tmp"
  printf '%s\t%s\n' "$id" "$count" >>"$tmp"
  mv "$tmp" "$ATTEMPT_FILE"
}

clear_attempt_count() {
  local id="$1"
  local tmp
  tmp="$(mktemp)"
  awk -v key="$id" '$1!=key {print $0}' "$ATTEMPT_FILE" >"$tmp"
  mv "$tmp" "$ATTEMPT_FILE"
}

append_dead_letter() {
  local id="$1"
  local attempts="$2"
  local reason="$3"
  local line="$4"

  if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$line" | jq -c --arg id "$id" --arg failedAt "$(now_iso)" --arg reason "$reason" --argjson attempts "$attempts" '. + {dead_letter_id:$id, failed_at:$failedAt, failure_reason:$reason, attempts:$attempts}' >>"$DEAD_LETTER_FILE"
    return
  fi

  printf '{"dead_letter_id":"%s","failed_at":"%s","failure_reason":"%s","attempts":%s,"raw":"%s"}\n' \
    "$id" "$(now_iso)" "$reason" "$attempts" "$(printf '%s' "$line" | sed 's/"/\\"/g')" >>"$DEAD_LETTER_FILE"
}

action_id_from_line() {
  local line="$1"
  local id
  id="$(printf '%s' "$line" | jq -r '.routed_id // .id // empty' 2>/dev/null || true)"
  if [[ -n "$id" ]]; then
    printf '%s' "$id"
    return
  fi

  printf '%s' "$line" | sha1sum | awk '{print "action-"$1}'
}

handle_action() {
  local line="$1"
  local command scope pr_number
  command="$(json_field "$line" '.command // ""')"
  scope="$(json_field "$line" '.scope // ""')"

  if ! extract_pr_number "$scope" >/dev/null 2>&1; then
    case "$command" in
      "/review"|"/merge"|"/close pr")
        log_process "invalid scope for closer command: command=$command scope=$scope"
        return 1
        ;;
    esac
  fi

  pr_number="$(extract_pr_number "$scope" || true)"

  # 安全のため、自動実行は opt-in（--auto-execute / options.execute / env）で有効化する。
  case "$command" in
    "/review")
      if should_execute "$line"; then
        local review_body
        review_body="$(json_field "$line" '.options.reviewBody // "Automated review check completed by closer worker."')"
        if (cd "$ROOT_DIR" && gh pr comment "$pr_number" --body "$review_body" >/dev/null); then
          log_process "executed closer action: command=$command scope=$scope"
          return 0
        fi
        log_process "failed closer action: command=$command scope=$scope"
        return 1
      fi
      log_process "planned closer action: command=$command scope=$scope"
      return 0
      ;;
    "/merge")
      local selector selector_mode selector_reason
      selector="$(merge_selector "$line")"
      selector_mode="${selector%%:*}"
      selector_reason="${selector#*:}"

      if [[ "$selector_mode" != "auto" ]]; then
        log_process "manual required: command=$command scope=$scope reason=$selector_reason"
        return 0
      fi

      if should_execute "$line"; then
        local method
        method="$(json_field "$line" '.options.mergeMethod // "squash"')"
        case "$method" in
          merge)
            if (cd "$ROOT_DIR" && gh pr merge "$pr_number" --merge --delete-branch=false >/dev/null); then
              log_process "executed closer action: command=$command scope=$scope method=merge selector=$selector_reason"
              return 0
            fi
            ;;
          rebase)
            if (cd "$ROOT_DIR" && gh pr merge "$pr_number" --rebase --delete-branch=false >/dev/null); then
              log_process "executed closer action: command=$command scope=$scope method=rebase selector=$selector_reason"
              return 0
            fi
            ;;
          *)
            if (cd "$ROOT_DIR" && gh pr merge "$pr_number" --squash --delete-branch=false >/dev/null); then
              log_process "executed closer action: command=$command scope=$scope method=squash selector=$selector_reason"
              return 0
            fi
            ;;
        esac
        log_process "failed closer action: command=$command scope=$scope"
        return 1
      fi
      log_process "planned closer action: command=$command scope=$scope selector=$selector_reason execute=false"
      return 0
      ;;
    "/close pr")
      if should_execute "$line"; then
        local close_comment
        close_comment="$(json_field "$line" '.options.comment // "Closed by closer worker."')"
        if (cd "$ROOT_DIR" && gh pr close "$pr_number" --comment "$close_comment" >/dev/null); then
          log_process "executed closer action: command=$command scope=$scope"
          return 0
        fi
        log_process "failed closer action: command=$command scope=$scope"
        return 1
      fi
      log_process "planned closer action: command=$command scope=$scope"
      return 0
      ;;
    *)
      log_process "unhandled closer command: command=$command scope=$scope"
      return 0
      ;;
  esac
}

process_once() {
  [[ -f "$QUEUE_FILE" ]] || return 0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local id
    id="$(action_id_from_line "$line")"

    if already_processed "$id"; then
      continue
    fi

    if handle_action "$line"; then
      mark_processed "$id"
      clear_attempt_count "$id"
      continue
    fi

    local attempts
    attempts="$(( $(attempt_count "$id") + 1 ))"
    set_attempt_count "$id" "$attempts"

    if (( attempts > max_retries )); then
      append_dead_letter "$id" "$attempts" "action_failed" "$line"
      mark_processed "$id"
      clear_attempt_count "$id"
      log_process "dead-lettered id=$id attempts=$attempts"
    else
      log_process "retry scheduled id=$id attempt=$attempts/$max_retries"
    fi
  done <"$QUEUE_FILE"
}

already_auto_tracked() {
  local scope="$1"
  grep -Fxq "$scope" "$AUTO_REVIEW_TRACK_FILE"
}

mark_auto_tracked() {
  local scope="$1"
  printf '%s\n' "$scope" >>"$AUTO_REVIEW_TRACK_FILE"
}

review_count_for_pr() {
  local pr_number="$1"
  local count
  count="$(cd "$ROOT_DIR" && run_api "/repos/$REPO/pulls/$pr_number/reviews?per_page=100" --jq 'length' 2>/dev/null || echo "0")"
  [[ "$count" =~ ^[0-9]+$ ]] || count="0"
  printf '%s' "$count"
}

auto_enqueue_review_for_open_prs() {
  local prs
  prs="$(cd "$ROOT_DIR" && run_api "/repos/$REPO/pulls?state=open&per_page=100" --jq '.[] | .number' 2>/dev/null || true)"
  [[ -z "$prs" ]] && return 0

  local pr_number scope reviews body
  while IFS= read -r pr_number; do
    [[ -z "$pr_number" ]] && continue
    scope="pr:#$pr_number"

    if already_auto_tracked "$scope"; then
      continue
    fi

    reviews="$(review_count_for_pr "$pr_number")"
    if (( reviews > 0 )); then
      mark_auto_tracked "$scope"
      continue
    fi

    body="Auto closer review: open PR detected without reviews. CI/merge readiness check was triggered automatically."
    if bash "$DISPATCH_SCRIPT" --issuer closer --action "/review" --scope "$scope" --options "$(jq -cn --arg msg "$body" '{execute:true, reviewBody:$msg}')" >/dev/null 2>&1; then
      log_process "auto-dispatched review: scope=$scope"
      mark_auto_tracked "$scope"
    else
      log_process "auto-dispatch failed: scope=$scope"
    fi
  done <<<"$prs"
}

log_process "worker started"

while true; do
  auto_enqueue_review_for_open_prs
  process_once

  if [[ "$once" == "true" ]]; then
    break
  fi

  sleep "$interval"
done

log_process "worker stopped"
