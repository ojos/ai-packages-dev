#!/usr/bin/env bash
set -euo pipefail
echo "[check] standard bootstrap checks"
for cmd in bash jq gh node go docker; do
  command -v "$cmd" >/dev/null 2>&1 && echo "[check] $cmd OK" || echo "[check] $cmd missing"
done