#!/usr/bin/env bash
# Install AI CLI tools (claude, gemini) if API credentials are available.
# Called from devcontainer postCreateCommand.
set -euo pipefail

CLAUDE_PKG="@anthropic-ai/claude-code"
GEMINI_PKG="@google/gemini-cli"

install_if_missing() {
  local cmd="$1"
  local pkg="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "[install-ai-tools] $cmd already installed, skipping"
    return 0
  fi
  echo "[install-ai-tools] installing $pkg ..."
  npm install -g "$pkg"
  echo "[install-ai-tools] $cmd installed: $(command -v "$cmd")"
}

# claude: requires CLAUDE_CODE_OAUTH_TOKEN
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  install_if_missing claude "$CLAUDE_PKG"
else
  echo "[install-ai-tools] SKIP claude (CLAUDE_CODE_OAUTH_TOKEN not set)"
fi

# gemini: requires GEMINI_API_KEY
if [[ -n "${GEMINI_API_KEY:-}" ]]; then
  install_if_missing gemini "$GEMINI_PKG"
else
  echo "[install-ai-tools] SKIP gemini (GEMINI_API_KEY not set)"
fi
