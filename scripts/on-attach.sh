#!/usr/bin/env bash
set -euo pipefail

echo "[on-attach] standard bootstrap active"

# Dev Container はホストの ~/.gitconfig をコピーするため、別アカウントの
# identity がグローバル設定に残る。リポジトリ外の一時クローン（リリース
# スクリプト等）がこれへフォールバックしないよう、グローバル identity を
# プロファイルの値で強制上書きする（.github/project-ai-rules.md「Git identity」）。
if [[ -n "${GIT_AUTHOR_NAME_OJOS:-}" && -n "${GIT_AUTHOR_EMAIL_OJOS:-}" ]]; then
  git config --global user.name "$GIT_AUTHOR_NAME_OJOS"
  git config --global user.email "$GIT_AUTHOR_EMAIL_OJOS"
  echo "[on-attach] global git identity -> ${GIT_AUTHOR_NAME_OJOS} <${GIT_AUTHOR_EMAIL_OJOS}>"
fi

if [[ -x "scripts/github-account-switch.sh" ]]; then
  bash scripts/github-account-switch.sh auto --git-scope local
fi

if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 && echo "[on-attach] gh auth OK" || \
    echo "[on-attach] WARN: gh auth missing"
fi

echo "[on-attach] profile list: bash scripts/github-account-switch.sh list"

command -v go   >/dev/null 2>&1 && echo "[on-attach] go OK"   || true
command -v node >/dev/null 2>&1 && echo "[on-attach] node OK" || true