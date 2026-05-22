#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DELEGATE_SCRIPT="$SCRIPT_DIR/delegate-issue-implementation.sh"

dry_run="false"

usage() {
  cat <<'EOF'
usage: ./scripts/worker/auto-enqueue-issues.sh [--dry-run <true|false>]

open 状態の issue を走査し、条件を満たす実装タスクのみを enqueue する。
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
    --dry-run)
      dry_run="$2"
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

require_bool "$dry_run" "--dry-run"

if [[ ! -x "$DELEGATE_SCRIPT" ]]; then
  echo "error: delegate script not found: $DELEGATE_SCRIPT" >&2
  exit 1
fi

has_required_sections() {
  local body="$1"
  [[ "$body" == *"要約"* ]] || return 1
  ([[ "$body" == *"受け入れ条件"* ]] || [[ "$body" == *"Acceptance Criteria"* ]]) || return 1
  return 0
}

parse_task_command() {
  local body="$1"
  printf '%s\n' "$body" | sed -n 's/^task_command:[[:space:]]*//p' | head -n 1
}

parse_line_id() {
  local body="$1"
  local line
  line="$(printf '%s\n' "$body" | sed -n 's/^line:[[:space:]]*//p' | head -n 1)"
  if [[ -z "$line" ]]; then
    line="auto-001"
  fi
  printf '%s' "$line"
}

dependency_open_exists() {
  local body="$1"
  local dep
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    local state
    state="$(cd "$ROOT_DIR" && gh issue view "$dep" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")"
    if [[ "$state" == "OPEN" ]]; then
      return 0
    fi
  done < <(printf '%s\n' "$body" | grep -oE '#[0-9]+' | tr -d '#' | sort -u)
  return 1
}

already_queued_marker() {
  local issue_number="$1"
  cd "$ROOT_DIR" && gh issue view "$issue_number" --json comments --jq '.comments[].body // ""' 2>/dev/null | grep -Fq "auto-enqueue: queued"
}

open_pr_exists_for_issue() {
  local issue_number="$1"
  local count
  count="$(cd "$ROOT_DIR" && gh pr list --state open --search "repo:ojos/ai-packages-dev #$issue_number in:body" --json number | jq 'length' 2>/dev/null || echo 0)"
  [[ "$count" != "0" ]]
}

cd "$ROOT_DIR"

candidates_json="$(gh issue list --state open --limit 200 --label line-task --label auto-enqueue --json number,title,body,url 2>/dev/null || echo '[]')"

printf '%s' "$candidates_json" | jq -c '.[]' | while IFS= read -r row; do
  issue_number="$(printf '%s' "$row" | jq -r '.number')"
  title="$(printf '%s' "$row" | jq -r '.title // ""')"
  body="$(printf '%s' "$row" | jq -r '.body // ""')"

  if [[ ! "$title" =~ ^(implementation:|feature:) ]]; then
    echo "skip #$issue_number: タイトル接頭辞が不一致"
    continue
  fi

  if ! has_required_sections "$body"; then
    echo "skip #$issue_number: 必須セクション不足"
    continue
  fi

  if dependency_open_exists "$body"; then
    echo "skip #$issue_number: 依存 issue が未クローズ"
    continue
  fi

  if open_pr_exists_for_issue "$issue_number"; then
    echo "skip #$issue_number: open PR が既に存在"
    continue
  fi

  if already_queued_marker "$issue_number"; then
    echo "skip #$issue_number: 既に queued マーカーあり"
    continue
  fi

  task_command="$(parse_task_command "$body")"
  if [[ -z "$task_command" ]]; then
    echo "skip #$issue_number: task_command 未設定"
    continue
  fi

  line_id="$(parse_line_id "$body")"

  if [[ "$dry_run" == "true" ]]; then
    jq -cn --arg issue "$issue_number" --arg line "$line_id" --arg task "$task_command" '{issue:$issue,line:$line,task_command:$task,dry_run:true}'
    continue
  fi

  "$DELEGATE_SCRIPT" --issue-number "$issue_number" --line "$line_id" --task-command "$task_command"

  gh issue comment "$issue_number" --body "auto-enqueue: queued (line:$line_id)"
  echo "queued #$issue_number by auto-enqueue"
done
