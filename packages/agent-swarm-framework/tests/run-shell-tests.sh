#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TESTS=(
  "$SCRIPT_DIR/asf-cli-doctor.sh"
)

if [[ "${RUN_E2E_TESTS:-false}" == "true" ]]; then
  TESTS+=("$SCRIPT_DIR/e2e-init.sh")
fi

for t in "${TESTS[@]}"; do
  echo "[test] $(basename "$t")"
  bash "$t"
done

echo "[ok] shell tests passed"
