#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  bash scripts/release-packages.sh \
    --owner <github-owner> \
    --dcb-version <vX.Y.Z> \
    --asf-version <vX.Y.Z> \
    --dotfiles-version <vX.Y.Z> \
    --execute

options:
  --owner <owner>               GitHub owner (required)
  --dcb-version <vX.Y.Z>        DCB release tag (required)
  --asf-version <vX.Y.Z>        ASF release tag (required)
  --dotfiles-version <vX.Y.Z>   dotfiles release tag (required)
  --execute                     Actually execute release operations
  -h, --help                    Show help

notes:
  - Without --execute, this script only validates inputs and exits.
  - This script enforces release-version consistency checks before publishing.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: command not found: $1" >&2
    exit 1
  }
}

require_clean_worktree() {
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is not clean. commit/stash changes first." >&2
    git status --short --branch >&2
    exit 1
  fi
}

extract_semver() {
  local tag="$1"
  if [[ "$tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    echo "error: invalid tag format: $tag (expected: vX.Y.Z)" >&2
    exit 1
  fi
}

validate_dcb_docs() {
  local dcb_tag="$1"
  local en="packages/devcontainer-bootstrap/README.md"
  local ja="packages/devcontainer-bootstrap/README.ja.md"

  grep -q "Latest stable release:" "$en" || {
    echo "error: missing 'Latest stable release' section in $en" >&2
    exit 1
  }
  grep -q "- \\`$dcb_tag\\`" "$en" || {
    echo "error: DCB README.md latest release does not match $dcb_tag" >&2
    exit 1
  }
  grep -q "TAG=$dcb_tag" "$en" || {
    echo "error: DCB README.md TAG does not match $dcb_tag" >&2
    exit 1
  }

  grep -q "最新安定リリース:" "$ja" || {
    echo "error: missing '最新安定リリース' section in $ja" >&2
    exit 1
  }
  grep -q "- \\`$dcb_tag\\`" "$ja" || {
    echo "error: DCB README.ja.md latest release does not match $dcb_tag" >&2
    exit 1
  }
  grep -q "TAG=$dcb_tag" "$ja" || {
    echo "error: DCB README.ja.md TAG does not match $dcb_tag" >&2
    exit 1
  }
}

validate_asf_version() {
  local asf_tag="$1"
  local expected
  expected="$(extract_semver "$asf_tag")"
  local actual
  actual="$(tr -d '\n' < packages/agent-swarm-framework/VERSION)"
  if [[ "$actual" != "$expected" ]]; then
    echo "error: ASF VERSION mismatch. VERSION=$actual expected=$expected" >&2
    exit 1
  fi
}

prepare_asf_release_repo() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"

  cp packages/agent-swarm-framework/install.sh "$dir/"
  cp packages/agent-swarm-framework/init.sh "$dir/"
  cp packages/agent-swarm-framework/config.schema.json "$dir/"
  cp packages/agent-swarm-framework/VERSION "$dir/"
  cp packages/agent-swarm-framework/README.md "$dir/"
  cp packages/agent-swarm-framework/README.ja.md "$dir/"
  cp packages/agent-swarm-framework/retrofit-config.sample.json "$dir/"
  cp -R packages/agent-swarm-framework/runtime-core "$dir/"
  cp -R packages/agent-swarm-framework/agent-skills "$dir/"
  cp -R packages/agent-swarm-framework/executors "$dir/"
  cp -R packages/agent-swarm-framework/template-project "$dir/"
  cp -R packages/agent-swarm-framework/docs "$dir/"
  cp -R packages/agent-swarm-framework/tests "$dir/"
}

prepare_dotfiles_release_repo() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R dotfiles/. "$dir/"
}

init_and_push_release_repo() {
  local dir="$1"
  local repo="$2"
  local vis="$3" # public|private

  pushd "$dir" >/dev/null
  git init -b main
  git add .
  git commit -m "chore: release snapshot"

  if gh repo view "$repo" >/dev/null 2>&1; then
    git remote add origin "https://github.com/$repo.git" || true
    git push -u origin main
  else
    gh repo create "$repo" "--$vis" --source . --remote origin --push
  fi
  popd >/dev/null
}

tag_and_release() {
  local dir="$1"
  local repo="$2"
  local tag="$3"
  local notes="$4"

  pushd "$dir" >/dev/null
  if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    git tag "$tag"
  fi
  if ! git ls-remote --tags origin | grep -q "refs/tags/$tag$"; then
    git push origin "$tag"
  fi
  popd >/dev/null

  if ! gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    gh release create "$tag" --repo "$repo" --title "$tag" --notes "$notes"
  fi
}

OWNER=""
DCB_TAG=""
ASF_TAG=""
DOTFILES_TAG=""
EXECUTE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --dcb-version) DCB_TAG="$2"; shift 2 ;;
    --asf-version) ASF_TAG="$2"; shift 2 ;;
    --dotfiles-version) DOTFILES_TAG="$2"; shift 2 ;;
    --execute) EXECUTE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[[ -n "$OWNER" && -n "$DCB_TAG" && -n "$ASF_TAG" && -n "$DOTFILES_TAG" ]] || {
  echo "error: required options are missing" >&2
  usage
  exit 1
}

require_cmd git
require_cmd gh
require_clean_worktree
extract_semver "$DCB_TAG" >/dev/null
extract_semver "$ASF_TAG" >/dev/null
extract_semver "$DOTFILES_TAG" >/dev/null
validate_dcb_docs "$DCB_TAG"
validate_asf_version "$ASF_TAG"

echo "[ok] preflight checks passed"

if [[ "$EXECUTE" != "true" ]]; then
  echo "[info] dry-run mode. add --execute to publish releases"
  exit 0
fi

ROOT_DIR="$(pwd)"
DCB_DIR="/tmp/dcb-release"
ASF_DIR="/tmp/asf-release"
DOTFILES_DIR="/tmp/dotfiles-release"

bash scripts/setup-devcontainer-bootstrap-release-repo.sh \
  --target-dir "$DCB_DIR" \
  --repo "$OWNER/devcontainer-bootstrap" \
  --create-remote \
  --force

tag_and_release "$DCB_DIR" "$OWNER/devcontainer-bootstrap" "$DCB_TAG" "Release $DCB_TAG"

prepare_asf_release_repo "$ASF_DIR"
init_and_push_release_repo "$ASF_DIR" "$OWNER/agent-swarm-framework" public
tag_and_release "$ASF_DIR" "$OWNER/agent-swarm-framework" "$ASF_TAG" "Initial release $ASF_TAG"

prepare_dotfiles_release_repo "$DOTFILES_DIR"
init_and_push_release_repo "$DOTFILES_DIR" "$OWNER/ai-dotfiles" public
tag_and_release "$DOTFILES_DIR" "$OWNER/ai-dotfiles" "$DOTFILES_TAG" "Initial release $DOTFILES_TAG"

cd "$ROOT_DIR"
echo "[ok] completed releases"
for r in "$OWNER/devcontainer-bootstrap" "$OWNER/agent-swarm-framework" "$OWNER/ai-dotfiles"; do
  echo "[repo] $r"
  gh release list --repo "$r" --limit 3 || true
  echo "---"
done
