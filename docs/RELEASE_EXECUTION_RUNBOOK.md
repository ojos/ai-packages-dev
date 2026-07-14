# Release Execution Runbook

This runbook defines the exact execution flow for final package releases after implementation issues are merged.
このランブックは、実装 issue のマージ後に最終パッケージリリースを実行する手順を定義する。

## Scope

Target repositories:
- `ojos/ai-packages-dev` (coordination)
- `ojos/ai-dotfiles`
- `ojos/devcontainer-bootstrap`

Related proposal:
- `docs/RELEASE_ASSET_STANDARDIZATION_PROPOSAL.md`

## Required Release Asset Contract

Every release across all packages **must** include the following three assets:

| Asset | Description |
|---|---|
| `RELEASE-MANIFEST.json` | Package name, version, asset list, and SHA-256 checksums |
| `SHA256SUMS` | SHA-256 checksums of all files in the release tree |
| `PACKAGE_ARCHIVE.tar.gz` | Full release tree as a compressed tarball |

Package-specific additional assets (e.g. `bootstrap.sh`, `doctor.sh` for DCB) are permitted alongside the three required assets.

## Gate Conditions (Must Pass)

Run releases only when all conditions are true:
- Identity rewrite check reports old identity count = 0 for all target repos
- Working tree clean in the release-driving workspace

## Tagging Convention

Recommended convention:
- `ai-dotfiles/vX.Y.Z`
- `devcontainer-bootstrap/vX.Y.Z`

Reason:
- avoids ambiguity in multi-package release streams

## Version Baseline

Current observed baseline:
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

git tag ai-dotfiles/v1.0.0
git push origin ai-dotfiles/v1.0.0
```

Repeat with package-specific prefixes.

#### 3-A) ai-dotfiles

```bash
set -euo pipefail
WORK=/tmp/release-dotfiles
rm -rf "$WORK"
git clone https://github.com/ojos/ai-dotfiles.git "$WORK"
cd "$WORK"

TAG="ai-dotfiles/v1.0.0"
git fetch --tags
git tag "$TAG"
git push origin "$TAG"
```

#### 3-B) devcontainer-bootstrap

```bash
set -euo pipefail
WORK=/tmp/release-dcb
rm -rf "$WORK"
git clone https://github.com/ojos/devcontainer-bootstrap.git "$WORK"
cd "$WORK"

TAG="devcontainer-bootstrap/v1.0.0"
git fetch --tags
git tag "$TAG"
git push origin "$TAG"
```

### 4) GitHub Release Publication

Use `scripts/release-packages.sh` to publish all packages in a single idempotent operation:

```bash
set -euo pipefail
cd /workspaces/ojos-ai-packages-dev

bash scripts/release-packages.sh \
  --owner ojos \
  --dcb-version v0.1.12 \
  --dotfiles-version v0.1.0 \
  --execute
```

The script automatically generates and attaches `RELEASE-MANIFEST.json`, `SHA256SUMS`, and `PACKAGE_ARCHIVE.tar.gz` for every package. For existing releases it uploads assets with `--clobber` and edits the release metadata; for new releases it creates the release with assets in one step.

#### 4-A) ai-dotfiles (manual fallback)

```bash
set -euo pipefail
gh release create ai-dotfiles/v1.0.0 \
  --repo ojos/ai-dotfiles \
  --title "ai-dotfiles v1.0.0" \
  --notes-file /workspaces/ojos-ai-packages-dev/docs/release-notes-ai-dotfiles.md \
  /tmp/dotfiles-release/RELEASE-MANIFEST.json \
  /tmp/dotfiles-release/SHA256SUMS \
  /tmp/dotfiles-release/PACKAGE_ARCHIVE.tar.gz
```

#### 4-B) devcontainer-bootstrap (manual fallback)

```bash
set -euo pipefail
gh release create devcontainer-bootstrap/v1.0.0 \
  --repo ojos/devcontainer-bootstrap \
  --title "devcontainer-bootstrap v1.0.0" \
  --notes-file /workspaces/ojos-ai-packages-dev/docs/release-notes-devcontainer-bootstrap.md \
  /tmp/dcb-release/bootstrap.sh \
  /tmp/dcb-release/doctor.sh \
  /tmp/dcb-release/RELEASE-MANIFEST.json \
  /tmp/dcb-release/SHA256SUMS \
  /tmp/dcb-release/PACKAGE_ARCHIVE.tar.gz
```

### 5) Asset Verification

After publication, run the cross-repo asset audit to confirm all required assets are present:

```bash
set -euo pipefail
bash scripts/release-packages.sh --owner ojos --audit
```

Expected output — every line should read `[audit] OK`:

```
[audit] checking required release assets: RELEASE-MANIFEST.json SHA256SUMS PACKAGE_ARCHIVE.tar.gz
[audit] OK    ojos/ai-dotfiles@vX.Y.Z  RELEASE-MANIFEST.json
[audit] OK    ojos/ai-dotfiles@vX.Y.Z  SHA256SUMS
[audit] OK    ojos/ai-dotfiles@vX.Y.Z  PACKAGE_ARCHIVE.tar.gz
[audit] OK    ojos/devcontainer-bootstrap@vX.Y.Z  RELEASE-MANIFEST.json
[audit] OK    ojos/devcontainer-bootstrap@vX.Y.Z  SHA256SUMS
[audit] OK    ojos/devcontainer-bootstrap@vX.Y.Z  PACKAGE_ARCHIVE.tar.gz
[audit] all required assets present
```

If any line reads `[audit] MISS`, the script exits non-zero. Re-run the release script with `--execute` to repair; it is idempotent and will upload the missing assets with `--clobber`.

Additional checks:
- verify release pages are published
- verify tags are visible remotely
- verify links from README/docs

## Rollback Policy

If release content is incorrect:
- publish corrective patch release (`vX.Y.(Z+1)`)
- avoid rewriting published release tags unless critical

## Ownership

- decision/coordination: consult-facilitator
- implementation: implementer role
- review/approval: reviewer role
- release execution: maintainer with repo admin/tag permissions

