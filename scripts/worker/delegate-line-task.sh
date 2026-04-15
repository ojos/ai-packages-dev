#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCH=""

dispatch_script_path() {
  if [[ -x "$SCRIPT_DIR/command-dispatch.sh" ]]; then
    echo "$SCRIPT_DIR/command-dispatch.sh"
    return
  fi
  if [[ -x "$SCRIPT_DIR/../gate/command-dispatch.sh" ]]; then
    echo "$SCRIPT_DIR/../gate/command-dispatch.sh"
    return
  fi
  echo ""
}

line=""
branch=""
base="main"
commit_message=""
pr_title=""
pr_body="Automated PR by line worker"
task_command=""

usage() {
  cat <<'EOF'
usage: ./scripts/delegate-line-task.sh \
  --line <line-id> \
  --branch <branch> \
  --commit-message <message> \
  --pr-title <title> \
  --task-command <shell command> \
  [--base <main>] \
  [--pr-body <body>]

example:
  ./scripts/delegate-line-task.sh \
    --line auto-001 \
    --branch feature/sample-implementation \
    --commit-message "feat(line): add sample implementation" \
    --pr-title "feat: sample implementation" \
    --task-command "go test ./backend/..."
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

if [[ -z "$line" || ! "$line" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "error: --line must match ^[a-z0-9][a-z0-9-]*$" >&2
  exit 1
fi

DISPATCH="$(dispatch_script_path)"
if [[ -z "$DISPATCH" ]]; then
  echo "error: command-dispatch script not found in worker or gate paths" >&2
  exit 1
fi

if [[ -z "$branch" || -z "$commit_message" || -z "$pr_title" || -z "$task_command" ]]; then
  echo "error: --branch, --commit-message, --pr-title, --task-command are required" >&2
  exit 1
fi

scope="line:${line}"
options="$(jq -nc \
  --arg branch "$branch" \
  --arg base "$base" \
  --arg commitMessage "$commit_message" \
  --arg prTitle "$pr_title" \
  --arg prBody "$pr_body" \
  --arg taskCommand "$task_command" \
  '{branch:$branch, base:$base, commitMessage:$commitMessage, prTitle:$prTitle, prBody:$prBody, taskCommand:$taskCommand}')"

"$DISPATCH" --issuer orchestrator --action "/implement" --scope "$scope" --options "$options"
