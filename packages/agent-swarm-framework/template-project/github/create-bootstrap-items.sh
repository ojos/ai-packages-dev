#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=""
DEFINITIONS_DIR=""

usage() {
  cat <<'EOF'
usage: bash create-bootstrap-items.sh --repo-root <path> --definitions-dir <path>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    --definitions-dir)
      DEFINITIONS_DIR="$2"
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

[[ -n "$REPO_ROOT" && -n "$DEFINITIONS_DIR" ]] || { usage >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "error: gh not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 1; }

cd "$REPO_ROOT"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

declare -A MILESTONE_NUMBERS
while IFS= read -r item; do
  title="$(printf '%s' "$item" | jq -r '.title')"
  description="$(printf '%s' "$item" | jq -r '.description')"
  existing="$(gh api "/repos/$REPO/milestones?state=all&per_page=100" --jq ".[] | select(.title == \"$title\") | .number" 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    MILESTONE_NUMBERS["$title"]="$existing"
    continue
  fi
  number="$(gh api "/repos/$REPO/milestones" -X POST -f title="$title" -f description="$description" --jq '.number')"
  MILESTONE_NUMBERS["$title"]="$number"
done < <(jq -c '.[]' "$DEFINITIONS_DIR/milestones.json")

for issue_file in "$DEFINITIONS_DIR"/issues/bootstrap/*.md; do
  [[ -f "$issue_file" ]] || continue
  title="$(grep '^Title:' "$issue_file" | sed 's/^Title:[[:space:]]*//')"
  milestone_title="$(grep '^Milestone:' "$issue_file" | sed 's/^Milestone:[[:space:]]*//')"
  labels_raw="$(grep '^Labels:' "$issue_file" | sed 's/^Labels:[[:space:]]*//')"
  body="$(sed '1,/^$/d' "$issue_file")"

  existing_issue="$(gh issue list --repo "$REPO" --state all --limit 200 --json title,number --jq ".[] | select(.title == \"$title\") | .number" 2>/dev/null || true)"
  if [[ -n "$existing_issue" ]]; then
    continue
  fi

  args=(issue create --repo "$REPO" --title "$title" --body "$body")
  if [[ -n "$milestone_title" && -n "${MILESTONE_NUMBERS[$milestone_title]:-}" ]]; then
    args+=(--milestone "$milestone_title")
  fi
  IFS=' ' read -r -a labels <<< "${labels_raw//,/ }"
  for label in "${labels[@]}"; do
    [[ -n "$label" ]] && args+=(--label "$label")
  done
  gh "${args[@]}" >/dev/null
 done

echo "bootstrap milestones/issues ensured: $REPO"
