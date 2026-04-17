#!/usr/bin/env bash
set -euo pipefail

# Release preflight check for B-3 execution.
# This script validates gate conditions before running tag/release commands.

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; }

FAIL_COUNT=0

check_issue_closed() {
  local num="$1"
  local state
  state="$(gh issue view "$num" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")"
  if [[ "$state" == "CLOSED" ]]; then
    pass "issue #$num is CLOSED"
  else
    fail "issue #$num is not CLOSED (state=$state)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

check_no_open_pr_linked() {
  local issue_num="$1"
  local count
  count="$(gh pr list --state open --search "repo:ojos/ai-packages-dev #$issue_num in:body" --json number | jq 'length' 2>/dev/null || echo 999)"
  if [[ "$count" == "0" ]]; then
    pass "no open PR linked to #$issue_num"
  else
    fail "open PR linked to #$issue_num count=$count"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

check_identity_zero() {
  local tmp
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" EXIT

  local repos=(
    "ojos/ai-packages-dev"
    "ojos/agent-swarm-framework"
    "ojos/ai-dotfiles"
    "ojos/devcontainer-bootstrap"
  )

  for repo in "${repos[@]}"; do
    local name
    name="${repo##*/}"
    git clone --quiet "https://github.com/$repo.git" "$tmp/$name"
    local old_count
    old_count="$(git -C "$tmp/$name" log --all --format='%an <%ae>' | awk '$0=="bascule-aizu <aizu@bascule.co.jp>"{c++} END{print c+0}')"
    if [[ "$old_count" == "0" ]]; then
      pass "identity clean in $repo"
    else
      fail "old identity remains in $repo count=$old_count"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  done
}

check_worktree_clean() {
  if [[ -z "$(git status --porcelain)" ]]; then
    pass "working tree clean"
  else
    fail "working tree is not clean"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

printf '=== Release Preflight Check ===\n'
check_issue_closed 12
check_issue_closed 13
check_no_open_pr_linked 12
check_no_open_pr_linked 13
check_identity_zero
check_worktree_clean

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf '=== RESULT: FAIL (%s) ===\n' "$FAIL_COUNT"
  exit 1
fi

printf '=== RESULT: PASS ===\n'
