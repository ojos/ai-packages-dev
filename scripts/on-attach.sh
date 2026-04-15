#!/usr/bin/env bash
set -euo pipefail

echo "[on-attach] standard bootstrap active"
if [[ -x "scripts/github-account-switch.sh" ]]; then
  bash scripts/github-account-switch.sh auto --git-scope local
fi

if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 && echo "[on-attach] gh auth OK" || \
    echo "[on-attach] WARN: gh auth missing"
fi

echo "[on-attach] profile list: bash scripts/github-account-switch.sh list"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  hooks_path="$(git config --local --get core.hooksPath || true)"
  if [[ -z "$hooks_path" || "$hooks_path" == ".githooks" ]]; then
    if [[ -x "scripts/gate/install-git-hooks.sh" ]]; then
      bash scripts/gate/install-git-hooks.sh >/dev/null 2>&1 && \
        echo "[on-attach] ASF git hooks installed" || \
        echo "[on-attach] WARN: failed to install ASF git hooks"
    fi
  else
    echo "[on-attach] skip ASF git hooks (custom core.hooksPath=$hooks_path)"
  fi
fi

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