#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

issue_number=""
reason=""
summary_en=""
summary_ja=""
verification=""
related=""
dry_run="false"

usage() {
  cat <<'EOF'
usage: ./scripts/worker/close-issue-with-policy.sh \
  --issue-number <N> \
  --reason <completed|superseded|duplicate|invalid|deferred> \
  --summary-en "<English summary>" \
  --summary-ja "<日本語要約>" \
  [--verification "<test/execution result line>"] \
  [--related "#12,#13"] \
  [--dry-run <true|false>]

Standardized close operation:
1) Add bilingual closure reason comment
2) Close issue
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
    --issue-number)
      issue_number="$2"
      shift 2
      ;;
    --reason)
      reason="$2"
      shift 2
      ;;
    --summary-en)
      summary_en="$2"
      shift 2
      ;;
    --summary-ja)
      summary_ja="$2"
      shift 2
      ;;
    --verification)
      verification="$2"
      shift 2
      ;;
    --related)
      related="$2"
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

case "$reason" in
  completed|superseded|duplicate|invalid|deferred) ;;
  *)
    echo "error: --reason must be one of completed|superseded|duplicate|invalid|deferred" >&2
    exit 1
    ;;
esac

if [[ -z "$summary_en" || -z "$summary_ja" ]]; then
  echo "error: --summary-en and --summary-ja are required" >&2
  exit 1
fi

if [[ "$dry_run" != "true" ]]; then
  state="$(cd "$ROOT_DIR" && gh issue view "$issue_number" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")"
  if [[ "$state" != "OPEN" ]]; then
    echo "error: issue #$issue_number must be OPEN (state=$state)" >&2
    exit 1
  fi
fi

if [[ ("$reason" == "superseded" || "$reason" == "duplicate") && -z "$related" ]]; then
  echo "error: --related is required for reason '$reason'" >&2
  exit 1
fi

comment="Closure Reason / クローズ理由\n\n- classification: ${reason}\n- English: ${summary_en}\n- 日本語: ${summary_ja}"

if [[ -n "$related" ]]; then
  comment+="\n- related issues: ${related}"
fi

if [[ -n "$verification" ]]; then
  comment+="\n- verification: ${verification}"
fi

if [[ "$dry_run" == "true" ]]; then
  jq -cn \
    --arg issue "$issue_number" \
    --arg reason "$reason" \
    --arg summary_en "$summary_en" \
    --arg summary_ja "$summary_ja" \
    --arg related "$related" \
    --arg verification "$verification" \
    --arg comment "$comment" \
    '{issue_number:$issue, reason:$reason, summary_en:$summary_en, summary_ja:$summary_ja, related:$related, verification:$verification, comment:$comment, dry_run:true}'
  exit 0
fi

cd "$ROOT_DIR"
gh issue comment "$issue_number" --body "$comment" >/dev/null
gh issue close "$issue_number" --comment "Closed with standardized closure policy." >/dev/null

echo "closed issue #$issue_number with reason=$reason"
