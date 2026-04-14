#!/usr/bin/env bash
set -euo pipefail
echo "[on-attach] standard bootstrap active"
if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 && echo "[on-attach] gh auth OK" || {
    if [ -n "${GITHUB_TOKEN_OJOS:-}" ]; then
      echo "$GITHUB_TOKEN_OJOS" | gh auth login --with-token >/dev/null 2>&1
      echo "[on-attach] gh auth initialized with GITHUB_TOKEN_OJOS"
    else
      echo "[on-attach] WARN: gh auth missing and GITHUB_TOKEN_OJOS not set"
    fi
  }
fi
echo "[on-attach] profile list: bash scripts/github-account-switch.sh list"
command -v go   >/dev/null 2>&1 && echo "[on-attach] go OK"   || true
command -v node >/dev/null 2>&1 && echo "[on-attach] node OK" || true