#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${MONITOR_REPO:-ojos/agent-swarm-framework}"
DEFAULT_INTERVAL="${MONITOR_INTERVAL:-120}"
API_MAX_RETRIES="${MONITOR_API_MAX_RETRIES:-3}"
API_RETRY_BASE_SECONDS="${MONITOR_API_RETRY_BASE_SECONDS:-2}"

line_env_key_suffix() {
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

normalize_line_id() {
  case "$1" in
    auto-001|auto-002) echo "$1" ;;
    *) echo "$1" ;;
  esac
}

runtime_line_ids() {
  local ids
  ids=""

  if [[ -f "$ROOT_DIR/orchestration/runtime/line-worker-slots.json" ]]; then
    ids="$(jq -r '.slots[]?' "$ROOT_DIR/orchestration/runtime/line-worker-slots.json" 2>/dev/null | xargs echo)"
  fi

  if [[ -z "$ids" && -f "$ROOT_DIR/orchestration/runtime/line-states.json" ]]; then
    ids="$(jq -r '.lines | keys[]?' "$ROOT_DIR/orchestration/runtime/line-states.json" 2>/dev/null | xargs echo)"
  fi

  if [[ -z "$ids" ]]; then
    ids="auto-001 auto-002"
  fi

  printf '%s' "$ids"
}

LINE_IDS=()
read -r -a LINE_IDS <<< "$(runtime_line_ids)"

line_name() {
  local line_id
  line_id="$(normalize_line_id "$1")"
  echo "$line_id"
}

line_mode() {
  echo "logical-parallel"
}

line_management_issue() {
  local line_id suffix key
  line_id="$(normalize_line_id "$1")"
  suffix="$(line_env_key_suffix "$line_id")"
  key="MONITOR_MANAGEMENT_ISSUE_${suffix}"
  printf '%s' "${!key:-}"
}

line_gate_issue() {
  local line_id suffix key
  line_id="$(normalize_line_id "$1")"
  suffix="$(line_env_key_suffix "$line_id")"
  key="MONITOR_GATE_ISSUE_${suffix}"
  printf '%s' "${!key:-}"
}

line_open_pr_pattern() {
  normalize_line_id "$1"
}

run_gh() {
  gh "$@" --repo "$REPO"
}

run_api() {
  local endpoint="$1"
  shift

  local attempt=1
  local wait_seconds="$API_RETRY_BASE_SECONDS"
  local out=""
  local err=""

  while [[ "$attempt" -le "$API_MAX_RETRIES" ]]; do
    if out="$(gh api "$endpoint" "$@" 2>&1)"; then
      printf '%s' "$out"
      return 0
    fi

    err="$out"
    if printf '%s' "$err" | grep -qi 'rate limit\|abuse detection'; then
      sleep "$wait_seconds"
      wait_seconds=$((wait_seconds * 2))
      attempt=$((attempt + 1))
      continue
    fi

    sleep "$wait_seconds"
    wait_seconds=$((wait_seconds * 2))
    attempt=$((attempt + 1))
  done

  # 監視継続を優先し、API取得失敗時は空文字で返す。
  printf ''
  return 0
}

issue_field() {
  local issue_number="$1"
  local field="$2"
  if [[ -z "$issue_number" ]]; then
    echo ""
    return
  fi
  run_api "/repos/$REPO/issues/$issue_number" --jq ".${field} // \"\"" 2>/dev/null || echo ""
}

issue_last_comment() {
  local issue_number="$1"
  if [[ -z "$issue_number" ]]; then
    echo ""
    return
  fi
  local raw
  raw="$(run_api "/repos/$REPO/issues/$issue_number/comments?per_page=100" --jq '.[-1].body // ""' 2>/dev/null || true)"
  printf '%b' "$raw"
}

issue_all_comments() {
  local issue_number="$1"
  if [[ -z "$issue_number" ]]; then
    echo ""
    return
  fi
  local raw
  raw="$(run_api "/repos/$REPO/issues/$issue_number/comments?per_page=100" --jq '.[].body' 2>/dev/null || true)"
  printf '%b\n' "$raw"
}

issue_title() {
  issue_field "$1" title
}

issue_state() {
  issue_field "$1" state
}

issue_updated_at() {
  if [[ -z "$1" ]]; then
    echo ""
    return
  fi
  run_api "/repos/$REPO/issues/$1" --jq '.updated_at // ""' 2>/dev/null || echo ""
}

to_epoch() {
  local ts="$1"
  if [[ -z "$ts" ]]; then
    echo 0
    return
  fi
  date -d "$ts" +%s 2>/dev/null || echo 0
}

latest_timestamp() {
  local latest_ts=""
  local latest_epoch=0
  local ts epoch

  for ts in "$@"; do
    epoch="$(to_epoch "$ts")"
    if [[ "$epoch" -gt "$latest_epoch" ]]; then
      latest_epoch="$epoch"
      latest_ts="$ts"
    fi
  done

  printf '%s' "$latest_ts"
}

line_last_update() {
  local line_id="$1"
  local management_issue gate_issue
  management_issue="$(line_management_issue "$line_id")"
  gate_issue="$(line_gate_issue "$line_id")"

  local management_updated gate_updated
  management_updated="$(issue_updated_at "$management_issue")"
  gate_updated="$(issue_updated_at "$gate_issue")"

  latest_timestamp "$management_updated" "$gate_updated"
}

last_nonempty_line() {
  awk 'NF { line=$0 } END { print line }'
}

extract_prefixed_value() {
  local key="$1"
  local issue_number="$2"
  local value
  value="$({
    issue_all_comments "$issue_number" \
      | sed 's/^"//; s/"$//' \
      | grep -E "(^|[-[:space:]])${key}:" || true
  } | sed -E "s/^.*${key}:[[:space:]]*//" | last_nonempty_line)"
  printf '%s' "$value"
}

derive_gate_name() {
  local title="$1"
  case "$title" in
    *DB*|*db*) echo "DB" ;;
    *UI*|*ui*) echo "UI" ;;
    *API*|*api*) echo "API" ;;
    *統合*|*integration*) echo "Integration" ;;
    *実装*|*CI/CD*) echo "Implementation" ;;
    *) echo "Unknown" ;;
  esac
}

derive_next_gate() {
  local gate="$1"
  case "$gate" in
    DB) echo "UI" ;;
    UI) echo "API" ;;
    API) echo "Implementation" ;;
    Implementation) echo "Integration" ;;
    Integration) echo "Done" ;;
    *) echo "Unknown" ;;
  esac
}

derive_risk() {
  local management_issue="$1"
  if [[ -z "$management_issue" ]]; then
    echo "low"
    return
  fi
  local latest_comment
  latest_comment="$(issue_last_comment "$management_issue")"
  if printf '%s' "$latest_comment" | grep -qi 'high'; then
    echo "high"
  elif printf '%s' "$latest_comment" | grep -qi 'medium'; then
    echo "medium"
  else
    echo "low"
  fi
}

derive_blocker() {
  local management_issue="$1"
  local gate_issue="$2"
  if [[ -z "$management_issue" || -z "$gate_issue" ]]; then
    echo "none"
    return
  fi
  local blocker
  blocker="$(extract_prefixed_value 'Blocker' "$gate_issue")"
  if [[ "$blocker" == "なし or 内容" ]]; then
    blocker=""
  fi
  if [[ "$blocker" =~ ^(State|Coverage|ETA): ]]; then
    blocker=""
  fi
  if [[ -n "$blocker" ]]; then
    printf '%s' "$blocker" | sed -E 's/^[[:space:]]*-[[:space:]]*//'
    return
  fi
  blocker="$({
    issue_last_comment "$management_issue" | grep -E 'ブロッカー|blocked|paused|未確定|待ち' || true
  } | grep -Ev 'State:|Coverage:|ETA:|再開します|paused から再開' | tail -n 1)"
  if [[ -n "$blocker" ]]; then
    printf '%s' "$blocker" | sed -E 's/^[[:space:]]*-[[:space:]]*//'
  else
    echo "none"
  fi
}

derive_owner_role() {
  local gate_issue="$1"
  if [[ -z "$gate_issue" ]]; then
    echo "unassigned"
    return
  fi
  local owner_role
  owner_role="$(extract_prefixed_value 'Owner Role' "$gate_issue")"
  if [[ -n "$owner_role" ]]; then
    echo "$owner_role"
  else
    echo "unassigned"
  fi
}

derive_work_status() {
  local line_id
  line_id="$(normalize_line_id "$1")"
  local management_issue gate_issue
  management_issue="$(line_management_issue "$line_id")"
  gate_issue="$(line_gate_issue "$line_id")"

  if [[ -z "$management_issue" || -z "$gate_issue" ]]; then
    local logical_state
    logical_state="$(jq -r --arg line "$line_id" '.lines[$line] // .all // "unknown"' "$ROOT_DIR/orchestration/runtime/line-states.json" 2>/dev/null || echo "unknown")"
    case "$logical_state" in
      running) echo "gate open" ;;
      paused) echo "paused" ;;
      stopped) echo "stopped" ;;
      closed) echo "done" ;;
      aborted) echo "blocked" ;;
      *) echo "unknown" ;;
    esac
    return
  fi

  local management_comment gate_comment gate_state owner_role
  management_comment="$(issue_last_comment "$management_issue")"
  gate_comment="$(issue_last_comment "$gate_issue")"
  gate_state="$(issue_state "$gate_issue")"
  owner_role="$(derive_owner_role "$gate_issue")"

  if printf '%s\n%s' "$management_comment" "$gate_comment" | grep -qi 'paused から再開\|再開します'; then
    if [[ "$owner_role" != "unassigned" ]]; then
      echo "work started"
    else
      echo "gate open"
    fi
  elif printf '%s\n%s' "$management_comment" "$gate_comment" | grep -qi 'paused 継続\|pause 管理'; then
    echo "paused"
  elif printf '%s\n%s' "$management_comment" "$gate_comment" | grep -qi 'blocked'; then
    echo "blocked"
  elif [[ "$gate_state" == "CLOSED" ]]; then
    echo "done"
  elif [[ "$owner_role" != "unassigned" ]] || printf '%s' "$gate_comment" | grep -qi 'First Action'; then
    echo "work started"
  else
    echo "gate open"
  fi
}

line_open_pr_count() {
  local pattern="$1"
  run_api "/repos/$REPO/pulls?state=open&per_page=100" --jq \
    "map(select((.title | ascii_downcase | contains(\"${pattern}\")) or (.head.ref | ascii_downcase | contains(\"${pattern}\")))) | length" 2>/dev/null || echo "0"
}

line_handoff_latest() {
  local management_issue="$1"
  if [[ -z "$management_issue" ]]; then
    echo "none"
    return
  fi
  issue_last_comment "$management_issue"
}

render_gate_timeline() {
  local current_gate="$1"
  local work_status="$2"
  local gates=("DB" "UI" "API" "Implementation" "Integration")
  local found_current=false
  local gate status

  if [[ -z "$current_gate" || "$current_gate" == "Unknown" ]]; then
    for gate in "${gates[@]}"; do
      case "$work_status" in
        done) status="done" ;;
        blocked) status="blocked" ;;
        paused) status="paused" ;;
        *) status="not-started" ;;
      esac
      printf '  %-18s status: %s\n' "$gate" "$status"
    done
    return
  fi

  for gate in "${gates[@]}"; do
    if [[ "$found_current" == "true" ]]; then
      status="not-started"
    elif [[ "$gate" == "$current_gate" ]]; then
      found_current=true
      case "$work_status" in
        blocked) status="blocked" ;;
        paused)  status="paused" ;;
        done)    status="done" ;;
        *)       status="current" ;;
      esac
    else
      status="done"
    fi
    printf '  %-18s status: %s\n' "$gate" "$status"
  done
}

format_handoff_latest() {
  local comment="$1"
  if [[ -z "$comment" ]]; then
    echo "none"
    return
  fi
  local fields=("Actor" "State" "Scope" "Next" "Risk")
  local found_any=false
  local field value ts

  for field in "${fields[@]}"; do
    value="$(printf '%s' "$comment" | grep -iE "^[-*[:space:]]*${field}[[:space:]]*:" | \
      sed -E "s/^[^:]*:[[:space:]]*//" | head -1 || true)"
    if [[ -n "$value" ]]; then
      printf '  %-10s %s\n' "${field}:" "$value"
      found_any=true
    fi
  done

  ts="$(printf '%s' "$comment" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?' | head -1 || true)"
  if [[ -n "$ts" ]]; then
    printf '  %-10s %s\n' "timestamp:" "$ts"
    found_any=true
  fi

  if [[ "$found_any" == "false" ]]; then
    printf '%s' "$comment" | grep -v '^[[:space:]]*$' | head -1
  fi
}

print_header() {
  printf '[%s]\n' "$1"
  TZ=Asia/Tokyo date '+%Y-%m-%d %H:%M:%S JST'
  printf '\n'
}

repeat_or_once() {
  local interval="$1"
  local once="$2"
  if [[ "$once" == "true" ]]; then
    return 1
  fi
  sleep "$interval"
  return 0
}