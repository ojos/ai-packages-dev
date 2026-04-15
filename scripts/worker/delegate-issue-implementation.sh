#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DELEGATE_LINE_TASK="$SCRIPT_DIR/delegate-line-task.sh"

issue_number=""
line="auto-001"
branch=""
base="main"
commit_message=""
pr_title=""
pr_body=""
task_command=""
issue_comment=""
dry_run="false"

usage() {
  cat <<'EOF'
usage: ./scripts/worker/delegate-issue-implementation.sh \
  --issue-number <number> \
  --task-command <shell command> \
  [--line <auto-001>] \
  [--branch <branch>] \
  [--base <main>] \
  [--commit-message <message>] \
  [--pr-title <title>] \
  [--pr-body <body>] \
  [--issue-comment <comment>] \
  [--dry-run <true|false>]

This script converts an implementation issue into an executable line-worker task.
Issue creation/comments alone do not enqueue runtime execution.
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

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/^implementation:[[:space:]]*//; s/^feature:[[:space:]]*//' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g' \
    | cut -c1-40
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue-number)
      issue_number="$2"
      shift 2
      ;;
    --line)
      line="$2"
      shift 2
      ;;
    --branch)
      branch="$2"
      shift 2
      ;;
    --base)
      base="$2"
      shift 2
      ;;
    --commit-message)
      commit_message="$2"
      shift 2
      ;;
    --pr-title)
      pr_title="$2"
      shift 2
      ;;
    --pr-body)
      pr_body="$2"
      shift 2
      ;;
    --task-command)
      task_command="$2"
      shift 2
      ;;
    --issue-comment)
      issue_comment="$2"
      shift 2
      ;;
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

if [[ -z "$issue_number" || ! "$issue_number" =~ ^[0-9]+$ ]]; then
  echo "error: --issue-number must be numeric" >&2
  exit 1
fi

if [[ -z "$task_command" ]]; then
  echo "error: --task-command is required" >&2
  exit 1
fi

if [[ ! -x "$DELEGATE_LINE_TASK" ]]; then
  echo "error: delegate-line-task script not found: $DELEGATE_LINE_TASK" >&2
  exit 1
fi

title="$(cd "$ROOT_DIR" && gh issue view "$issue_number" --json title,state --jq '.title' 2>/dev/null || true)"
state="$(cd "$ROOT_DIR" && gh issue view "$issue_number" --json title,state --jq '.state' 2>/dev/null || true)"

if [[ -z "$title" ]]; then
  echo "error: issue #$issue_number not found or inaccessible" >&2
  exit 1
fi

if [[ "$state" != "OPEN" ]]; then
  echo "error: issue #$issue_number must be OPEN (state=$state)" >&2
  exit 1
fi

slug="$(slugify "$title")"
if [[ -z "$slug" ]]; then
  slug="issue-${issue_number}"
fi

if [[ -z "$branch" ]]; then
  branch="line/issue-${issue_number}-${slug}"
fi

if [[ -z "$commit_message" ]]; then
  commit_message="chore(line): execute issue #${issue_number}"
fi

if [[ -z "$pr_title" ]]; then
  pr_title="chore: execute issue #${issue_number}"
fi

if [[ -z "$pr_body" ]]; then
  pr_body="Implements executable line-worker task for #${issue_number}."
fi

if [[ -z "$issue_comment" ]]; then
  issue_comment="runtime delegation queued: line:${line} branch:${branch}"
fi

if [[ "$dry_run" == "true" ]]; then
  jq -cn \
    --arg issue_number "$issue_number" \
    --arg line "$line" \
    --arg branch "$branch" \
    --arg base "$base" \
    --arg commit_message "$commit_message" \
    --arg pr_title "$pr_title" \
    --arg pr_body "$pr_body" \
    --arg task_command "$task_command" \
    --arg issue_comment "$issue_comment" \
    '{issue_number:$issue_number, line:$line, branch:$branch, base:$base, commit_message:$commit_message, pr_title:$pr_title, pr_body:$pr_body, task_command:$task_command, issue_comment:$issue_comment, dry_run:true}'
  exit 0
fi

"$DELEGATE_LINE_TASK" \
  --line "$line" \
  --branch "$branch" \
  --base "$base" \
  --commit-message "$commit_message" \
  --pr-title "$pr_title" \
  --pr-body "$pr_body" \
  --task-command "$task_command"

cd "$ROOT_DIR" && gh issue comment "$issue_number" --body "$issue_comment" >/dev/null

echo "queued implementation task for issue #$issue_number on line:$line"