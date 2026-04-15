#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HOOKS_DIR="$ROOT_DIR/.githooks"

if ! git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[hooks] not a git repository: $ROOT_DIR" >&2
  exit 1
fi

mkdir -p "$HOOKS_DIR"
chmod +x "$HOOKS_DIR/pre-commit" "$HOOKS_DIR/pre-push" "$ROOT_DIR/scripts/gate/asf-enforcement-check.sh"

git -C "$ROOT_DIR" config --local core.hooksPath .githooks
echo "[hooks] installed: core.hooksPath=.githooks"
