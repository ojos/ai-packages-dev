# Release Execution Runbook

This runbook defines the exact execution flow for final package releases after implementation issues are merged.
このランブックは、実装 issue のマージ後に最終パッケージリリースを実行する手順を定義する。

## Scope

Target repositories:
- `ojos/ai-packages-dev` (coordination)
- `ojos/agent-swarm-framework`
- `ojos/ai-dotfiles`
- `ojos/devcontainer-bootstrap`

## Gate Conditions (Must Pass)

Run releases only when all conditions are true:
- Issue `#12` merged (conversation-gate core)
- Issue `#13` merged (conversation-entry adapter)
- Identity rewrite check reports old identity count = 0 for all target repos
- Working tree clean in the release-driving workspace

## Tagging Convention

Recommended convention:
- `agent-swarm-framework/vX.Y.Z`
- `ai-dotfiles/vX.Y.Z`
- `devcontainer-bootstrap/vX.Y.Z`

Reason:
- avoids ambiguity in multi-package release streams

## Version Baseline

Current observed baseline:
- `agent-swarm-framework`: `0.1.1`
- `ai-dotfiles`: unknown (no accessible `VERSION` file via API at prep time)
- `devcontainer-bootstrap`: unknown (no accessible `VERSION` file via API at prep time)

Action before release:
- confirm canonical version source per repo (`VERSION` file or package manifest)

## Execution Steps

### 1) Preflight

```bash
set -euo pipefail
cd /workspaces/ojos-ai-packages-dev

git status --short --branch

gh issue view 12 --json state

gh issue view 13 --json state

gh pr list --state open --search 'repo:ojos/ai-packages-dev #12 in:body'
gh pr list --state open --search 'repo:ojos/ai-packages-dev #13 in:body'
```

Expected:
- issue 12/13 closed
- no blocking open PRs

### 2) Changelog Assembly

Create/append release notes for each package with:
- Added: conversation gate core/entry and delegation workflow docs
- Changed: boundary clarification updates
- Internal: delegation standardization and issue template updates

### 3) Tag Creation (Per Repo)

```bash
# Example in target repo
set -euo pipefail

git tag agent-swarm-framework/v1.0.0
git push origin agent-swarm-framework/v1.0.0
```

Repeat with package-specific prefixes.

### 4) GitHub Release Publication

```bash
# Example
set -euo pipefail

gh release create agent-swarm-framework/v1.0.0 \
  --title "agent-swarm-framework v1.0.0" \
  --notes-file /path/to/release-notes.md
```

### 5) Verification

- verify release pages are published
- verify tags are visible remotely
- verify links from README/docs

## Rollback Policy

If release content is incorrect:
- publish corrective patch release (`vX.Y.(Z+1)`)
- avoid rewriting published release tags unless critical

## Ownership

- decision/coordination: consult-facilitator
- implementation: line workers
- review/approval: reviewer role
- release execution: maintainer with repo admin/tag permissions
