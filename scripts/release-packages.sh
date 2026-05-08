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
  --audit                       Audit release assets across all repos and exit
  -h, --help                    Show help

notes:
  - Without --execute, this script only validates inputs and exits.
  - This script enforces release-version consistency checks before publishing.
  - Use --audit to check asset completeness across all repos without releasing.
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
  local pinned="- \`$dcb_tag\`"

  grep -q "Latest stable release:" "$en" || {
    echo "error: missing 'Latest stable release' section in $en" >&2
    exit 1
  }
  grep -Fq -- "$pinned" "$en" || {
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
  grep -Fq -- "$pinned" "$ja" || {
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

validate_markdown_links_in_tree() {
  local base_dir="$1"
  python3 - "$base_dir" <<'PY'
import re
import sys
from pathlib import Path

base = Path(sys.argv[1]).resolve()
md_files = sorted(base.rglob("README*.md"))
link_re = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
heading_re = re.compile(r"^#{1,6}\s+(.+?)\s*$", re.M)

def slugify(text: str) -> str:
    s = text.strip().lower()
    s = re.sub(r"[`*_~\[\](){}.!?,:;\"']", "", s)
    s = re.sub(r"\s+", "-", s)
    s = re.sub(r"-+", "-", s)
    return s

def heading_slugs(path: Path):
    txt = path.read_text(encoding="utf-8", errors="ignore")
    return {slugify(m.group(1)) for m in heading_re.finditer(txt)}

failed = []

for md in md_files:
    txt = md.read_text(encoding="utf-8", errors="ignore")
    for m in link_re.finditer(txt):
        raw = m.group(1).strip()
        if not raw:
            continue
        if raw.startswith(("http://", "https://", "mailto:", "tel:", "data:")):
            continue
        if raw.startswith("#"):
            anchor = raw[1:]
            if anchor and anchor not in heading_slugs(md):
                failed.append((str(md), raw, "missing local anchor"))
            continue

        path_part, _, frag = raw.partition("#")
        path_part = path_part.split("?", 1)[0]
        target = (md.parent / path_part).resolve()
        if not target.exists():
            failed.append((str(md), raw, "missing target file"))
            continue

        if frag and target.suffix.lower() == ".md":
            if frag not in heading_slugs(target):
                failed.append((str(md), raw, "missing target anchor"))

if failed:
    for md, raw, reason in failed:
        print(f"error: broken markdown link in {md} -> {raw} ({reason})", file=sys.stderr)
    print(f"error: markdown link validation failed under {base}", file=sys.stderr)
    sys.exit(1)
PY
}

# Required assets every package release must include.
REQUIRED_RELEASE_ASSETS=("RELEASE-MANIFEST.json" "SHA256SUMS" "PACKAGE_ARCHIVE.tar.gz")

# Generate the three standard release assets in <dir> for a given package.
# Usage: generate_standard_assets <dir> <package-name> <version>
generate_standard_assets() {
  local dir="$1"
  local pkg_name="$2"
  local version="$3"

  pushd "$dir" >/dev/null

  # PACKAGE_ARCHIVE.tar.gz — full tree minus the .git directory
  tar \
    --exclude='./.git' \
    --exclude='./PACKAGE_ARCHIVE.tar.gz' \
    --exclude='./SHA256SUMS' \
    --exclude='./RELEASE-MANIFEST.json' \
    -czf PACKAGE_ARCHIVE.tar.gz .

  # SHA256SUMS — covers all regular files except itself and the manifest
  find . -type f \
    ! -name SHA256SUMS \
    ! -name 'RELEASE-MANIFEST.json' \
    ! -path './.git/*' \
    | sort | xargs sha256sum > SHA256SUMS

  # RELEASE-MANIFEST.json
  local archive_sha
  archive_sha=$(sha256sum PACKAGE_ARCHIVE.tar.gz | awk '{print $1}')
  local sums_sha
  sums_sha=$(sha256sum SHA256SUMS | awk '{print $1}')
  cat > RELEASE-MANIFEST.json <<JSON
{
  "package": "$pkg_name",
  "version": "$version",
  "assets": [
    "RELEASE-MANIFEST.json",
    "SHA256SUMS",
    "PACKAGE_ARCHIVE.tar.gz"
  ],
  "checksums": {
    "PACKAGE_ARCHIVE.tar.gz": "$archive_sha",
    "SHA256SUMS": "$sums_sha"
  }
}
JSON

  popd >/dev/null
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

prepare_dcb_release_repo() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/.github/workflows"

  cp packages/devcontainer-bootstrap/bootstrap.sh "$dir/"
  cp packages/devcontainer-bootstrap/doctor.sh "$dir/"
  cp packages/devcontainer-bootstrap/README.md "$dir/"
  if [[ -f packages/devcontainer-bootstrap/README.ja.md ]]; then
    cp packages/devcontainer-bootstrap/README.ja.md "$dir/"
  fi
  cp packages/devcontainer-bootstrap/.github/workflows/release.yml "$dir/.github/workflows/"
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

  if gh repo view "$repo" >/dev/null 2>&1; then
    local stage_dir
    stage_dir="${dir}.stage"
    rm -rf "$stage_dir"
    mv "$dir" "$stage_dir"
    git clone --depth 1 "https://github.com/$repo.git" "$dir"
    find "$dir" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    cp -R "$stage_dir"/. "$dir"/
    rm -rf "$stage_dir"
  else
    pushd "$dir" >/dev/null
    git init -b main
    popd >/dev/null
  fi

  pushd "$dir" >/dev/null
  git add .
  if ! git diff --cached --quiet; then
    git commit -m "chore: release snapshot"
  fi

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
  shift 4
  local assets=("$@")

  pushd "$dir" >/dev/null
  if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    git tag "$tag"
  fi
  if ! git ls-remote --tags origin | grep -q "refs/tags/$tag$"; then
    git push origin "$tag"
  fi
  popd >/dev/null

  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    if [[ ${#assets[@]} -gt 0 ]]; then
      gh release upload "$tag" --repo "$repo" --clobber "${assets[@]}"
    fi
    gh release edit "$tag" --repo "$repo" --title "$tag" --notes "$notes"
  else
    if [[ ${#assets[@]} -gt 0 ]]; then
      gh release create "$tag" --repo "$repo" --title "$tag" --notes "$notes" "${assets[@]}"
    else
      gh release create "$tag" --repo "$repo" --title "$tag" --notes "$notes"
    fi
  fi
}

# Audit required release assets across all repos for the given owner.
# Prints a report and exits non-zero if any required asset is missing.
audit_release_assets() {
  local owner="$1"
  local repos=("$owner/agent-swarm-framework" "$owner/ai-dotfiles" "$owner/devcontainer-bootstrap")
  local failed=0

  echo "[audit] checking required release assets: ${REQUIRED_RELEASE_ASSETS[*]}"
  for repo in "${repos[@]}"; do
    local tag
    tag=$(gh release list --repo "$repo" --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || true)
    if [[ -z "$tag" ]]; then
      echo "[audit] WARN  $repo — no releases found"
      continue
    fi
    local present
    present=$(gh release view "$tag" --repo "$repo" --json assets --jq '[.assets[].name]' 2>/dev/null || echo '[]')
    for asset in "${REQUIRED_RELEASE_ASSETS[@]}"; do
      if echo "$present" | grep -qF "\"$asset\""; then
        echo "[audit] OK    $repo@$tag  $asset"
      else
        echo "[audit] MISS  $repo@$tag  $asset"
        failed=1
      fi
    done
  done

  if [[ $failed -eq 0 ]]; then
    echo "[audit] all required assets present"
  else
    echo "[audit] missing required assets detected" >&2
    return 1
  fi
}

OWNER=""
DCB_TAG=""
ASF_TAG=""
DOTFILES_TAG=""
EXECUTE="false"
AUDIT="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --dcb-version) DCB_TAG="$2"; shift 2 ;;
    --asf-version) ASF_TAG="$2"; shift 2 ;;
    --dotfiles-version) DOTFILES_TAG="$2"; shift 2 ;;
    --execute) EXECUTE="true"; shift ;;
    --audit) AUDIT="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# --audit only requires --owner
if [[ "$AUDIT" == "true" ]]; then
  [[ -n "$OWNER" ]] || {
    echo "error: --owner is required for --audit" >&2
    usage
    exit 1
  }
  require_cmd gh
  audit_release_assets "$OWNER"
  exit $?
fi

[[ -n "$OWNER" && -n "$DCB_TAG" && -n "$ASF_TAG" && -n "$DOTFILES_TAG" ]] || {
  echo "error: required options are missing" >&2
  usage
  exit 1
}

require_cmd git
require_cmd gh
require_cmd bash
require_cmd tar
require_cmd sha256sum
require_clean_worktree
extract_semver "$DCB_TAG" >/dev/null
extract_semver "$ASF_TAG" >/dev/null
extract_semver "$DOTFILES_TAG" >/dev/null
validate_dcb_docs "$DCB_TAG"
validate_asf_version "$ASF_TAG"
validate_markdown_links_in_tree "$(pwd)/dotfiles"
validate_markdown_links_in_tree "$(pwd)/packages/devcontainer-bootstrap"
validate_markdown_links_in_tree "$(pwd)/packages/agent-swarm-framework"

echo "[ok] preflight checks passed"

if [[ "$EXECUTE" != "true" ]]; then
  echo "[info] dry-run mode. add --execute to publish releases"
  exit 0
fi

ROOT_DIR="$(pwd)"
DCB_DIR="/tmp/dcb-release"
ASF_DIR="/tmp/asf-release"
DOTFILES_DIR="/tmp/dotfiles-release"

DCB_VER="$(extract_semver "$DCB_TAG")"
ASF_VER="$(extract_semver "$ASF_TAG")"
DOTFILES_VER="$(extract_semver "$DOTFILES_TAG")"

prepare_dcb_release_repo "$DCB_DIR"
generate_standard_assets "$DCB_DIR" "devcontainer-bootstrap" "$DCB_VER"
init_and_push_release_repo "$DCB_DIR" "$OWNER/devcontainer-bootstrap" public
tag_and_release "$DCB_DIR" "$OWNER/devcontainer-bootstrap" "$DCB_TAG" "Release $DCB_TAG" \
  "$DCB_DIR/bootstrap.sh" \
  "$DCB_DIR/doctor.sh" \
  "$DCB_DIR/RELEASE-MANIFEST.json" \
  "$DCB_DIR/SHA256SUMS" \
  "$DCB_DIR/PACKAGE_ARCHIVE.tar.gz"

prepare_asf_release_repo "$ASF_DIR"
generate_standard_assets "$ASF_DIR" "agent-swarm-framework" "$ASF_VER"
init_and_push_release_repo "$ASF_DIR" "$OWNER/agent-swarm-framework" public
tag_and_release "$ASF_DIR" "$OWNER/agent-swarm-framework" "$ASF_TAG" "Release $ASF_TAG" \
  "$ASF_DIR/RELEASE-MANIFEST.json" \
  "$ASF_DIR/SHA256SUMS" \
  "$ASF_DIR/PACKAGE_ARCHIVE.tar.gz"

prepare_dotfiles_release_repo "$DOTFILES_DIR"
generate_standard_assets "$DOTFILES_DIR" "ai-dotfiles" "$DOTFILES_VER"
init_and_push_release_repo "$DOTFILES_DIR" "$OWNER/ai-dotfiles" public
tag_and_release "$DOTFILES_DIR" "$OWNER/ai-dotfiles" "$DOTFILES_TAG" "Release $DOTFILES_TAG" \
  "$DOTFILES_DIR/RELEASE-MANIFEST.json" \
  "$DOTFILES_DIR/SHA256SUMS" \
  "$DOTFILES_DIR/PACKAGE_ARCHIVE.tar.gz"

cd "$ROOT_DIR"

if [[ -x scripts/update-release-status.sh ]]; then
  bash scripts/update-release-status.sh --owner "$OWNER" --readme README.md
  echo "[info] README release status refreshed. commit README.md if changed."
else
  echo "[warn] scripts/update-release-status.sh not found or not executable; skip README refresh"
fi

echo "[ok] completed releases"
for r in "$OWNER/devcontainer-bootstrap" "$OWNER/agent-swarm-framework" "$OWNER/ai-dotfiles"; do
  echo "[repo] $r"
  gh release list --repo "$r" --limit 3 || true
  echo "---"
done

audit_release_assets "$OWNER"

