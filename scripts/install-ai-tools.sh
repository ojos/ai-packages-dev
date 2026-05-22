#!/usr/bin/env bash
# API 資格情報がある場合に AI CLI ツール（claude, gemini）をインストールする。
# devcontainer の postCreateCommand から呼び出される。
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

# claude: CLAUDE_CODE_OAUTH_TOKEN が必要
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  install_if_missing claude "$CLAUDE_PKG"
else
  echo "[install-ai-tools] SKIP claude (CLAUDE_CODE_OAUTH_TOKEN not set)"
fi

# gemini: GEMINI_API_KEY が必要
if [[ -n "${GEMINI_API_KEY:-}" ]]; then
  install_if_missing gemini "$GEMINI_PKG"
else
  echo "[install-ai-tools] SKIP gemini (GEMINI_API_KEY not set)"
fi
