#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/monitor-common.sh"

interval="$DEFAULT_INTERVAL"
once="false"

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
    -h|--help)
      echo "usage: $0 [--interval <sec>] [--once]"
      exit 0
      ;;
    *)
      echo "usage: $0 [--interval <sec>] [--once]" >&2
      exit 1
      ;;
  esac
done

while true; do
  clear
  print_header "terminal.monitor.merge-queue"
  echo 'pr_number | from_line | issue | review_status | merge_readiness | reason_waiting'

  rows="$(run_api "/repos/$REPO/pulls?state=open&per_page=100" \
    --jq '.[] | [.number, .title, .head.ref, (.draft | tostring), (.mergeable_state // "unknown")] | @tsv' \
    2>/dev/null || true)"
  if [[ -z "$rows" ]]; then
    echo 'none | none | none | none | none | no open pull requests'
  else
    while IFS=$'\t' read -r pr_number title head_ref is_draft mergeable_state; do
      from_line="unknown"
      if printf '%s' "$head_ref" | grep -qi 'auto-[0-9]\+'; then
        from_line="$(printf '%s' "$head_ref" | grep -oiE 'auto-[0-9]+' | head -1)"
      elif printf '%s %s' "$title" "$head_ref" | grep -qi 'hotfix'; then
        from_line='hotfix'
      fi

      issue_ref="$(printf '%s' "$title" | grep -oE '#[0-9]+' | head -1 || true)"
      if [[ -z "$issue_ref" ]]; then
        pr_body="$(run_api "/repos/$REPO/pulls/${pr_number}" --jq '.body // ""' 2>/dev/null || true)"
        issue_ref="$(printf '%s\n%s' "$title" "$pr_body" | grep -oiE '(closes|fixes|resolves) #[0-9]+' | \
          grep -oE '#[0-9]+' | head -1 || true)"
        [[ -z "$issue_ref" ]] && issue_ref="$(printf '%s' "$pr_body" | grep -oE '#[0-9]+' | head -1 || true)"
      fi
      [[ -z "$issue_ref" ]] && issue_ref="$(printf '%.40s' "$title")"

      review_status="$(run_api "/repos/$REPO/pulls/${pr_number}/reviews" \
        --jq '[.[] | .state] | if length == 0 then "no_reviews" elif (map(. == "APPROVED") | any) then "approved" elif (map(. == "CHANGES_REQUESTED") | any) then "changes_requested" else "pending" end' \
        2>/dev/null || echo "unknown")"

      if [[ "$is_draft" == "true" ]]; then
        merge_readiness="draft"
      else
        case "$mergeable_state" in
          clean)    merge_readiness="ready" ;;
          dirty)    merge_readiness="conflicts" ;;
          blocked)  merge_readiness="blocked" ;;
          behind)   merge_readiness="behind" ;;
          unstable) merge_readiness="ci_failing" ;;
          *)        merge_readiness="$mergeable_state" ;;
        esac
      fi

      if [[ "$is_draft" == "true" ]]; then
        reason_waiting="draft PR"
      elif [[ "$merge_readiness" == "conflicts" ]]; then
        reason_waiting="merge conflict"
      elif [[ "$merge_readiness" == "blocked" ]]; then
        if [[ "$review_status" == "changes_requested" ]]; then
          reason_waiting="changes requested"
        elif [[ "$review_status" == "no_reviews" ]]; then
          reason_waiting="awaiting review"
        else
          reason_waiting="blocked by branch protection"
        fi
      elif [[ "$merge_readiness" == "ci_failing" ]]; then
        reason_waiting="CI unstable"
      elif [[ "$merge_readiness" == "behind" ]]; then
        reason_waiting="branch behind base"
      elif [[ "$merge_readiness" == "ready" && "$review_status" == "approved" ]]; then
        reason_waiting="none"
      else
        reason_waiting="awaiting reviewer and merge agent"
      fi

      printf '#%s | %s | %s | %s | %s | %s\n' \
        "$pr_number" \
        "$from_line" \
        "$issue_ref" \
        "$review_status" \
        "$merge_readiness" \
        "$reason_waiting"
    done <<< "$rows"
  fi

  if ! repeat_or_once "$interval" "$once"; then
    break
  fi
done