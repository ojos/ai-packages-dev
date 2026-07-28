#!/usr/bin/env bash
# このリポジトリの開発環境へ AI CLI（claude / gemini）を導入する。
# 引数は取らず、未導入のものだけを無条件に導入する。
# 導入対象を選べる --with-claude / --with-gemini / --with-copilot は、生成物側の
# packages/devcontainer-bootstrap/bootstrap.sh のフラグであり、本スクリプトとは無関係。
set -euo pipefail

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

install_if_missing claude "@anthropic-ai/claude-code"
install_if_missing gemini "@google/gemini-cli"
echo "[install-ai-tools] done"