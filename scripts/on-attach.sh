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

# ASF workflow bootstrap: detect installation, validate runtime, and optionally start workers.
if [[ -f ".agent-swarm-framework.config.json" && -x "scripts/asf-workflow.sh" ]]; then
  echo "[on-attach] ASF detected"
  if bash scripts/asf-workflow.sh preflight >/dev/null 2>&1; then
    echo "[on-attach] ASF preflight OK"
    bash scripts/asf-workflow.sh status | head -20 || true

    if [[ "${ASF_AUTO_START:-false}" == "true" ]]; then
      interval="${ASF_INTERVAL:-15}"
      echo "[on-attach] ASF auto start: up --interval ${interval}"
      bash scripts/asf-workflow.sh up --interval "${interval}" || \
        echo "[on-attach] WARN: ASF auto start failed"
    else
      echo "[on-attach] ASF auto start is disabled (set ASF_AUTO_START=true to enable)"
    fi
  else
    echo "[on-attach] WARN: ASF detected but preflight failed"
  fi
else
  echo "[on-attach] ASF not detected (skip ASF bootstrap)"
fi

command -v go   >/dev/null 2>&1 && echo "[on-attach] go OK"   || true
command -v node >/dev/null 2>&1 && echo "[on-attach] node OK" || true