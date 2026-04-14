#!/usr/bin/env bash
set -euo pipefail

# 必要: gh CLI, projectスコープ認証
# 使い方: bash create-project-board.sh --owner <org/user> --title <title> [--project-number <n>] [--repo <owner/name>] [--no-link-repo]

OWNER=""
TITLE="Multi-Agent Project Board"
TEMPLATE_JSON="$(dirname "$0")/project-board.json"
PROJECT_NUMBER=""
REPO=""
LINK_REPO="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)
      OWNER="$2"; shift 2;;
    --title)
      TITLE="$2"; shift 2;;
    --project-number)
      PROJECT_NUMBER="$2"; shift 2;;
    --repo)
      REPO="$2"; shift 2;;
    --no-link-repo)
      LINK_REPO="false"; shift;;
    *) echo "Unknown option: $1" >&2; exit 1;;
  esac
done

[[ -n "$OWNER" ]] || { echo "--owner <org/user> 必須" >&2; exit 1; }

if [[ -z "$PROJECT_NUMBER" ]]; then
  PROJECT_NUMBER=$(gh project create --owner "$OWNER" --title "$TITLE" --format json | jq -r '.number')
fi

if [[ "$LINK_REPO" == "true" ]]; then
  if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)"
  fi
  if [[ -n "$REPO" ]]; then
    # idempotent: already linked repository returns non-zero in some contexts, so do best-effort
    gh project link "$PROJECT_NUMBER" --owner "$OWNER" --repo "$REPO" >/dev/null 2>&1 || true
  fi
fi

existing_field_names() {
  gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json 2>/dev/null | jq -r '.fields[].name // empty'
}

# カスタムフィールド追加（既存フィールドはスキップ）
jq -c '.fields[]' "$TEMPLATE_JSON" | while read -r field; do
  NAME=$(echo "$field" | jq -r '.name')
  TYPE=$(echo "$field" | jq -r '.type')

  if existing_field_names | grep -Fxq "$NAME"; then
    echo "skip existing field: $NAME"
    continue
  fi

  if [[ "$TYPE" == "single_select" ]]; then
    OPTIONS=$(echo "$field" | jq -r '.options | join(",")')
    gh project field-create "$PROJECT_NUMBER" --owner "$OWNER" --name "$NAME" --data-type "SINGLE_SELECT" --single-select-options "$OPTIONS"
  else
    DATA_TYPE="TEXT"
    case "$TYPE" in
      text) DATA_TYPE="TEXT" ;;
      number) DATA_TYPE="NUMBER" ;;
      date) DATA_TYPE="DATE" ;;
    esac
    gh project field-create "$PROJECT_NUMBER" --owner "$OWNER" --name "$NAME" --data-type "$DATA_TYPE"
  fi
done

if [[ "$LINK_REPO" == "true" && -n "$REPO" ]]; then
  echo "Project board created: $TITLE (#$PROJECT_NUMBER), linked repo: $REPO"
else
  echo "Project board created: $TITLE (#$PROJECT_NUMBER)"
fi
