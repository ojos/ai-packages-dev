#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  # release one package
  bash scripts/release-packages.sh --owner <github-owner> --dcb-version <vX.Y.Z> --execute
  bash scripts/release-packages.sh --owner <github-owner> --dotfiles-version <vX.Y.Z> --execute

  # release both in one run
  bash scripts/release-packages.sh --owner <github-owner> \
    --dcb-version <vX.Y.Z> --dotfiles-version <vX.Y.Z> --execute

options:
  --owner <owner>               GitHub owner (required)
  --dcb-version <vX.Y.Z>        DCB release tag
  --dotfiles-version <vX.Y.Z>   dotfiles release tag
  --execute                     Actually execute release operations
  --audit                       Audit release assets across all repos and exit
  -h, --help                    Show help

notes:
  - Specify at least one of --dcb-version / --dotfiles-version.
    Only the specified packages are touched; the others are left untouched.
  - Published versions are immutable. Re-releasing an existing version fails
    during preflight, before any side effect.
  - Without --execute, this script only validates inputs and exits.
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
  local pinned="- \`$dcb_tag\`"

  grep -q "Latest stable release:\|最新安定リリース:" "$en" || {
    echo "error: missing release section header in $en" >&2
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
}

# 公開済みのリリースは不変とする。
#
# 同じタグで再実行すると、tag_and_release が gh release upload --clobber で資産を
# 差し替える。タグは動かないのに中身だけが変わるため、利用者がタグを固定しても
# 内容の同一性が保証されない。実際に dotfiles v0.3.0 の資産が、DCB の別リリースに
# 巻き込まれて 4 分間で 2 回書き換わった。
#
# PACKAGE_ARCHIVE.tar.gz は tar がタイムスタンプを埋めるため同じ内容でもハッシュが
# 変わる。したがって「内容が同じなら上書きしてよい」という冪等判定は成立せず、
# 上書きは常に別物への差し替えになる。
#
# この検査は preflight で行う。init_and_push_release_repo が公開 main を全置換した
# 後に気づいても手遅れなため。
require_version_unpublished() {
  local repo="$1" tag="$2"
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    echo "error: $repo already has a release for $tag" >&2
    echo "       公開済みのリリースは不変です。版を上げてください。" >&2
    echo "       やり直す場合は、先に公開側の release を削除してください:" >&2
    echo "         gh release delete $tag --repo $repo --cleanup-tag" >&2
    exit 1
  fi
}

# 公開リポジトリには tests/ も規範ソースも渡らないため、リリース前のこの位置が
# 機能テストを通せる唯一のゲートになる。v0.2.0 は構文チェックのみで公開され、
# URL 経路が壊れていた。
run_dcb_tests() {
  local runner="packages/devcontainer-bootstrap/tests/run-tests.sh"
  [[ -x "$runner" || -f "$runner" ]] || {
    echo "error: DCB tests not found: $runner" >&2
    exit 1
  }
  echo "[preflight] running DCB tests"
  bash "$runner" >/dev/null || {
    echo "error: DCB tests failed. run: bash $runner" >&2
    exit 1
  }
  echo "[ok] DCB tests passed"
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
  local archive_tmp

  pushd "$dir" >/dev/null

  # PACKAGE_ARCHIVE.tar.gz — full tree minus the .git directory
  archive_tmp="$(mktemp)"
  tar \
    --exclude='./.git' \
    --exclude='./PACKAGE_ARCHIVE.tar.gz' \
    --exclude='./SHA256SUMS' \
    --exclude='./RELEASE-MANIFEST.json' \
    -czf "$archive_tmp" .
  mv "$archive_tmp" PACKAGE_ARCHIVE.tar.gz

  # SHA256SUMS — ユーザーが実際にダウンロードするファイルのみを対象にする。
  #
  # 対象を広げると、documented な手順が壊れる。DCB の README は bootstrap.sh と
  # SHA256SUMS だけを取得して sha256sum -c を実行するよう指示しており、SHA256SUMS が
  # 手元に無いファイルを列挙していると FAILED になり非ゼロ終了する。
  # 検証ファイルは「検証する人が持っているもの」を列挙しなければ意味がない。
  #
  # 追加の資産（PACKAGE_ARCHIVE.tar.gz）のハッシュは RELEASE-MANIFEST.json 側が持つ。
  if [[ ${#SUMS_TARGETS[@]} -eq 0 ]]; then
    echo "error: internal: SUMS_TARGETS not set for $pkg_name" >&2
    exit 1
  fi
  local t
  for t in "${SUMS_TARGETS[@]}"; do
    [[ -f "$t" ]] || {
      echo "error: checksum target not found in release tree: $t" >&2
      exit 1
    }
  done
  sha256sum "${SUMS_TARGETS[@]}" > SHA256SUMS

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

prepare_dcb_release_repo() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"

  cp packages/devcontainer-bootstrap/bootstrap.sh "$dir/"
  cp packages/devcontainer-bootstrap/doctor.sh "$dir/"
  cp packages/devcontainer-bootstrap/README.md "$dir/"
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

  # 公開済みリリースは不変。preflight の require_version_unpublished が既に検査して
  # いるが、ここでも守る。preflight から到達するまでの間に別経路で作られた場合や、
  # 将来この関数が別の場所から呼ばれた場合に、黙って上書きしないようにする。
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    echo "error: $repo already has a release for $tag; refusing to overwrite" >&2
    exit 1
  fi

  if [[ ${#assets[@]} -gt 0 ]]; then
    gh release create "$tag" --repo "$repo" --title "$tag" --notes "$notes" "${assets[@]}"
  else
    gh release create "$tag" --repo "$repo" --title "$tag" --notes "$notes"
  fi
}

# Audit required release assets across all repos for the given owner.
# Prints a report and exits non-zero if any required asset is missing.
audit_release_assets() {
  local owner="$1"
  local repos=("$owner/ai-dotfiles" "$owner/devcontainer-bootstrap")
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
DOTFILES_TAG=""
EXECUTE="false"
AUDIT="false"
SUMS_TARGETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --dcb-version) DCB_TAG="$2"; shift 2 ;;
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

[[ -n "$OWNER" ]] || {
  echo "error: --owner is required" >&2
  usage
  exit 1
}

# パッケージは独立してリリースできる。片方の修正が他方の公開物へ波及しないよう、
# 指定されたパッケージだけを対象にする。
[[ -n "$DCB_TAG" || -n "$DOTFILES_TAG" ]] || {
  echo "error: specify at least one of --dcb-version or --dotfiles-version" >&2
  usage
  exit 1
}

require_cmd git
require_cmd gh
require_cmd bash
require_cmd tar
require_cmd sha256sum
require_clean_worktree

# 検査は安い順に並べる。版の重複は問い合わせ 1 回で分かるため、テスト実行のような
# 重い検査より先に判定する。手戻りが早いだけでなく、テストから release-packages.sh を
# 呼んだときに run_dcb_tests が再びテスト一式を起動する再帰も避けられる。
if [[ -n "$DCB_TAG" ]]; then
  extract_semver "$DCB_TAG" >/dev/null
  require_version_unpublished "$OWNER/devcontainer-bootstrap" "$DCB_TAG"
  validate_dcb_docs "$DCB_TAG"
  validate_markdown_links_in_tree "$(pwd)/packages/devcontainer-bootstrap"
  # DCB は規範パッケージの templates/ を配布するため、規範側の健全性にも依存する。
  validate_markdown_links_in_tree "$(pwd)/dotfiles"
  run_dcb_tests
fi

if [[ -n "$DOTFILES_TAG" ]]; then
  extract_semver "$DOTFILES_TAG" >/dev/null
  require_version_unpublished "$OWNER/ai-dotfiles" "$DOTFILES_TAG"
  validate_markdown_links_in_tree "$(pwd)/dotfiles"
fi

echo "[ok] preflight checks passed"

if [[ "$EXECUTE" != "true" ]]; then
  echo "[info] dry-run mode. add --execute to publish releases"
  exit 0
fi

ROOT_DIR="$(pwd)"
DCB_DIR="/tmp/dcb-release"
DOTFILES_DIR="/tmp/dotfiles-release"

if [[ -n "$DCB_TAG" ]]; then
  DCB_VER="$(extract_semver "$DCB_TAG")"
  prepare_dcb_release_repo "$DCB_DIR"
  # ユーザーは bootstrap.sh と SHA256SUMS だけを取得する（README の手順）。
  SUMS_TARGETS=(bootstrap.sh doctor.sh)
  generate_standard_assets "$DCB_DIR" "devcontainer-bootstrap" "$DCB_VER"
  init_and_push_release_repo "$DCB_DIR" "$OWNER/devcontainer-bootstrap" public
  tag_and_release "$DCB_DIR" "$OWNER/devcontainer-bootstrap" "$DCB_TAG" "Release $DCB_TAG" \
    "$DCB_DIR/bootstrap.sh" \
    "$DCB_DIR/doctor.sh" \
    "$DCB_DIR/RELEASE-MANIFEST.json" \
    "$DCB_DIR/SHA256SUMS" \
    "$DCB_DIR/PACKAGE_ARCHIVE.tar.gz"
fi

if [[ -n "$DOTFILES_TAG" ]]; then
  DOTFILES_VER="$(extract_semver "$DOTFILES_TAG")"
  prepare_dotfiles_release_repo "$DOTFILES_DIR"
  # dotfiles はタグ固定で取り込む運用のため、資産のダウンロードを前提としない。
  # 現状は互換のため README を対象にしておく。資産そのものの要否は未決（RELEASE_PROCESS_REVIEW）。
  SUMS_TARGETS=(README.md)
  generate_standard_assets "$DOTFILES_DIR" "ai-dotfiles" "$DOTFILES_VER"
  init_and_push_release_repo "$DOTFILES_DIR" "$OWNER/ai-dotfiles" public
  tag_and_release "$DOTFILES_DIR" "$OWNER/ai-dotfiles" "$DOTFILES_TAG" "Release $DOTFILES_TAG" \
    "$DOTFILES_DIR/RELEASE-MANIFEST.json" \
    "$DOTFILES_DIR/SHA256SUMS" \
    "$DOTFILES_DIR/PACKAGE_ARCHIVE.tar.gz"
fi

cd "$ROOT_DIR"

if [[ -x scripts/update-release-status.sh ]]; then
  bash scripts/update-release-status.sh --owner "$OWNER" --readme README.md
  echo "[info] README release status refreshed. commit README.md if changed."
else
  echo "[warn] scripts/update-release-status.sh not found or not executable; skip README refresh"
fi

echo "[ok] completed releases"
for r in "$OWNER/devcontainer-bootstrap" "$OWNER/ai-dotfiles"; do
  echo "[repo] $r"
  gh release list --repo "$r" --limit 3 || true
  echo "---"
done

audit_release_assets "$OWNER"

