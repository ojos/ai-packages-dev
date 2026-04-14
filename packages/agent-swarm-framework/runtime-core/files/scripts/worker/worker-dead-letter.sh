#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_DIR="$SCRIPT_DIR/../orchestration/runtime"
PENDING_FILE="$RUNTIME_DIR/pending-actions.jsonl"

mode=""
worker=""
limit="20"
replay_id=""
dry_run="false"

usage() {
  cat <<'EOF'
usage: ./scripts/worker-dead-letter.sh <list|replay> --worker <line-<id>|line:<id>|closer|orchestrator> [options]

options:
  --limit <n>      list件数上限 (default: 20)
  --id <dead_id>   replay対象の dead_letter_id を1件指定
  --dry-run        replay内容を表示のみ（再投入しない）

examples:
  ./scripts/worker-dead-letter.sh list --worker line-auto-001 --limit 10
  ./scripts/worker-dead-letter.sh replay --worker closer --id act-123...
  ./scripts/worker-dead-letter.sh replay --worker orchestrator
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

mode="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worker)
      worker="$2"
      shift 2
      ;;
    --limit)
      limit="$2"
      shift 2
      ;;
    --id)
      replay_id="$2"
      shift 2
      ;;
    --dry-run)
      dry_run="true"
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

if [[ "$mode" != "list" && "$mode" != "replay" ]]; then
  echo "error: mode must be list or replay" >&2
  usage
  exit 1
fi

case "$worker" in
  line:*)
    worker="line-${worker#line:}"
    ;;
  line-*)
    ;;
  closer|orchestrator)
    ;;
  *)
    echo "error: --worker must be one of line-<id>|line:<id>|closer|orchestrator" >&2
    usage
    exit 1
    ;;
esac

DEAD_FILE="$RUNTIME_DIR/${worker}-dead-letter.jsonl"

if [[ ! -f "$DEAD_FILE" ]]; then
  echo "no dead-letter file: $DEAD_FILE"
  exit 0
fi

mkdir -p "$RUNTIME_DIR"
touch "$PENDING_FILE"

new_action_id() {
  printf 'act-%s-%04d' "$(date +%s%N)" "$RANDOM"
}

list_entries() {
  if [[ ! -s "$DEAD_FILE" ]]; then
    echo "no dead-letter entries for $worker"
    return
  fi

  tail -n "$limit" "$DEAD_FILE" | jq -c '{dead_letter_id, command, scope, attempts, failure_reason, failed_at}'
}

append_pending_action() {
  local entry="$1"
  local new_id ts issuer command scope options note replay_from

  new_id="$(new_action_id)"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  issuer="$(printf '%s' "$entry" | jq -r '.issuer // "orchestrator"')"
  command="$(printf '%s' "$entry" | jq -r '.command // ""')"
  scope="$(printf '%s' "$entry" | jq -r '.scope // ""')"
  options="$(printf '%s' "$entry" | jq -c '.options // {}')"
  replay_from="$(printf '%s' "$entry" | jq -r '.dead_letter_id // ""')"
  note="replayed from dead-letter ${replay_from}"

  if [[ -z "$command" || -z "$scope" ]]; then
    echo "skip invalid dead-letter entry: missing command/scope" >&2
    return 1
  fi

  if [[ "$dry_run" == "true" ]]; then
    jq -nc \
      --arg id "$new_id" \
      --arg ts "$ts" \
      --arg issuer "$issuer" \
      --arg command "$command" \
      --arg scope "$scope" \
      --arg note "$note" \
      --arg replayFrom "$replay_from" \
      --argjson options "$options" \
      '{id:$id,timestamp:$ts,issuer:$issuer,command:$command,scope:$scope,options:$options,note:$note,replayed_from:$replayFrom}'
    return 0
  fi

  jq -nc \
    --arg id "$new_id" \
    --arg ts "$ts" \
    --arg issuer "$issuer" \
    --arg command "$command" \
    --arg scope "$scope" \
    --arg note "$note" \
    --arg replayFrom "$replay_from" \
    --argjson options "$options" \
    '{id:$id,timestamp:$ts,issuer:$issuer,command:$command,scope:$scope,options:$options,note:$note,replayed_from:$replayFrom}' >>"$PENDING_FILE"

  echo "replayed: dead_letter_id=${replay_from} -> action_id=${new_id}"
}

replay_entries() {
  if [[ ! -s "$DEAD_FILE" ]]; then
    echo "no dead-letter entries for $worker"
    return
  fi

  local tmp line matched="false"
  tmp="$(mktemp)"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    local dead_id
    dead_id="$(printf '%s' "$line" | jq -r '.dead_letter_id // ""')"

    if [[ -n "$replay_id" && "$dead_id" != "$replay_id" ]]; then
      printf '%s\n' "$line" >>"$tmp"
      continue
    fi

    matched="true"

    if append_pending_action "$line"; then
      if [[ "$dry_run" == "true" ]]; then
        printf '%s\n' "$line" >>"$tmp"
      fi
    else
      # keep failed entries for retry.
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$DEAD_FILE"

  if [[ "$matched" != "true" ]]; then
    rm -f "$tmp"
    echo "no matching dead-letter entry found"
    return
  fi

  if [[ "$dry_run" != "true" ]]; then
    mv "$tmp" "$DEAD_FILE"
  else
    rm -f "$tmp"
  fi
}

case "$mode" in
  list)
    list_entries
    ;;
  replay)
    replay_entries
    ;;
esac
