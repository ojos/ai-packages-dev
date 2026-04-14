#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=""
LABELS_FILE=""

usage() {
  cat <<'EOF'
usage: bash apply-labels.sh --repo-root <path> --labels-file <path>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    --labels-file)
      LABELS_FILE="$2"
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

[[ -n "$REPO_ROOT" && -n "$LABELS_FILE" ]] || { usage >&2; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "error: gh not found" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "error: jq not found" >&2; exit 1; }

cd "$REPO_ROOT"
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

while IFS= read -r entry; do
  name="$(printf '%s' "$entry" | jq -r '.name')"
  color="$(printf '%s' "$entry" | jq -r '.color')"
  description="$(printf '%s' "$entry" | jq -r '.description')"
  existing="$(gh label list --repo "$REPO" --json name --jq ".[] | select(.name == \"$name\") | .name" 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    gh label edit "$name" --repo "$REPO" --color "$color" --description "$description" >/dev/null
  else
    gh label create "$name" --repo "$REPO" --color "$color" --description "$description" >/dev/null
  fi
done < <(jq -c '.[]' "$LABELS_FILE")

echo "labels ensured: $REPO"
