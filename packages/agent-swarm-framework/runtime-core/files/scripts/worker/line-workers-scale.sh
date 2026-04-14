#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/../orchestration/runtime"
PID_DIR="$RUNTIME_DIR/pids"
SLOTS_FILE="$RUNTIME_DIR/line-worker-slots.json"

count=""

usage() {
  cat <<'EOF'
usage: ./scripts/line-workers-scale.sh --count <n>

Scales dynamic line workers using slot names line:auto-001 ... line:auto-N.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)
      count="$2"
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

if [[ -z "$count" || ! "$count" =~ ^[0-9]+$ ]]; then
  echo "error: --count must be a non-negative integer" >&2
  exit 1
fi

MAX_WORKERS="${MAX_LINE_WORKERS:-4}"
if [[ ! "$MAX_WORKERS" =~ ^[0-9]+$ ]]; then
  MAX_WORKERS=4
fi

if (( count < 1 )); then
  count=1
fi

if (( count > MAX_WORKERS )); then
  count="$MAX_WORKERS"
fi

mkdir -p "$RUNTIME_DIR" "$PID_DIR"

now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

slot_name() {
  local idx="$1"
  printf 'auto-%03d' "$idx"
}

hotfix_slots_from_state() {
  local state_file="$RUNTIME_DIR/line-states.json"
  if [[ ! -f "$state_file" ]]; then
    return
  fi

  jq -r '.lines | keys[]? | select(test("^hotfix-[0-9]+$"))' "$state_file" 2>/dev/null || true
}

queued_slots() {
  shopt -s nullglob
  local q base slot
  for q in "$RUNTIME_DIR"/line-*-queue.jsonl; do
    [[ -s "$q" ]] || continue
    base="$(basename "$q")"
    slot="${base#line-}"
    slot="${slot%-queue.jsonl}"
    printf '%s\n' "$slot"
  done
  shopt -u nullglob
}

slot_queue_file() {
  local slot="$1"
  printf '%s/line-%s-queue.jsonl' "$RUNTIME_DIR" "$slot"
}

slot_pid_file() {
  local slot="$1"
  printf '%s/line-%s-worker.pid' "$PID_DIR" "$slot"
}

slot_log_file() {
  local slot="$1"
  printf '%s/line-%s-worker.stdout.log' "$RUNTIME_DIR" "$slot"
}

start_slot_worker() {
  local slot="$1"
  local pid_file log_file existing_pid
  pid_file="$(slot_pid_file "$slot")"
  log_file="$(slot_log_file "$slot")"

  if [[ -f "$pid_file" ]]; then
    existing_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      return
    fi
  fi

  nohup bash -lc "$SCRIPT_DIR/line-worker.sh --line $slot --interval ${WORKER_INTERVAL:-15}" >>"$log_file" 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" >"$pid_file"
}

queue_has_backlog() {
  local slot="$1"
  local queue_file
  queue_file="$(slot_queue_file "$slot")"
  [[ -s "$queue_file" ]]
}

is_high_priority_action() {
  local line="$1"
  local cmd prio
  cmd="$(printf '%s' "$line" | jq -r '.command // ""' 2>/dev/null || true)"
  prio="$(printf '%s' "$line" | jq -r '.options.priority // ""' 2>/dev/null || true)"

  [[ "$prio" == "high" || "$cmd" == "/hotfix" || "$cmd" == "/escalate" ]]
}

least_loaded_slot() {
  local slots=("$@")
  local best=""
  local best_count=999999
  local slot q c

  for slot in "${slots[@]}"; do
    q="$(slot_queue_file "$slot")"
    if [[ -f "$q" ]]; then
      c="$(wc -l <"$q" | tr -d ' ')"
    else
      c=0
    fi

    if (( c < best_count )); then
      best_count="$c"
      best="$slot"
    fi
  done

  printf '%s' "$best"
}

reassign_high_priority_backlog() {
  local from_slot="$1"
  shift
  local target_slots=("$@")

  local from_q
  from_q="$(slot_queue_file "$from_slot")"
  [[ -f "$from_q" ]] || return 0

  local tmp line
  tmp="$(mktemp)"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    if is_high_priority_action "$line"; then
      local dst_slot dst_q
      dst_slot="$(least_loaded_slot "${target_slots[@]}")"
      dst_q="$(slot_queue_file "$dst_slot")"
      printf '%s\n' "$line" >>"$dst_q"
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$from_q"

  mv "$tmp" "$from_q"
}

stop_slot_worker_if_allowed() {
  local slot="$1"
  shift
  local remaining_slots=("$@")

  # Mixed strategy:
  # - High-priority tasks are reassigned immediately.
  # - Low-priority backlog keeps the worker alive (drain mode).
  reassign_high_priority_backlog "$slot" "${remaining_slots[@]}"

  if queue_has_backlog "$slot"; then
    return
  fi

  local pid_file pid
  pid_file="$(slot_pid_file "$slot")"
  if [[ -f "$pid_file" ]]; then
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  fi
}

# Build desired slots.
desired_slots=()
for i in $(seq 1 "$count"); do
  desired_slots+=("$(slot_name "$i")")
done

# Keep hotfix slots as sticky dynamic lines.
while IFS= read -r hotfix_slot; do
  [[ -z "$hotfix_slot" ]] && continue
  desired_slots+=("$hotfix_slot")
done < <(hotfix_slots_from_state)

# Keep queued slots to prevent starving pending work after scale-down.
while IFS= read -r queued_slot; do
  [[ -z "$queued_slot" ]] && continue
  desired_slots+=("$queued_slot")
done < <(queued_slots)

# Deduplicate slots while preserving order.
deduped_slots=()
for s in "${desired_slots[@]}"; do
  found="false"
  for d in "${deduped_slots[@]}"; do
    if [[ "$d" == "$s" ]]; then
      found="true"
      break
    fi
  done
  if [[ "$found" == "false" ]]; then
    deduped_slots+=("$s")
  fi
done
desired_slots=("${deduped_slots[@]}")

# Start desired slots.
for slot in "${desired_slots[@]}"; do
  start_slot_worker "$slot"
done

# Stop non-desired slot workers using mixed policy.
shopt -s nullglob
for pid_file in "$PID_DIR"/line-auto-*-worker.pid; do
  base="$(basename "$pid_file")"
  slot="${base#line-}"
  slot="${slot%-worker.pid}"

  keep="false"
  for d in "${desired_slots[@]}"; do
    if [[ "$slot" == "$d" ]]; then
      keep="true"
      break
    fi
  done

  if [[ "$keep" == "false" ]]; then
    stop_slot_worker_if_allowed "$slot" "${desired_slots[@]}"
  fi
done
shopt -u nullglob

jq -nc \
  --arg updatedAt "$(now_iso)" \
  --argjson desiredCount "$count" \
  --argjson maxCount "$MAX_WORKERS" \
  --argjson slots "$(printf '%s\n' "${desired_slots[@]}" | jq -R . | jq -s .)" \
  '{updated_at:$updatedAt, desired_count:$desiredCount, max_count:$maxCount, slots:$slots}' >"$SLOTS_FILE"

state_file="$RUNTIME_DIR/line-states.json"
if [[ -f "$state_file" ]]; then
  tmp_state="$(mktemp)"
  jq --argjson slots "$(printf '%s\n' "${desired_slots[@]}" | jq -R . | jq -s .)" '
    .all as $all
    | .lines = (reduce $slots[] as $slot ({}; .[$slot] = ($all // "running")))
  ' "$state_file" >"$tmp_state"
  mv "$tmp_state" "$state_file"
fi

echo "scaled line workers: count=$count slots=${desired_slots[*]}"
