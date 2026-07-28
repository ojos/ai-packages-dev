#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  # release one package
  bash scripts/release-packages.sh --owner <github-owner> --dcb-version <vX.Y.Z> --execute
  bash scripts/release-packages.sh --owner <github-owner> --playbook-version <vX.Y.Z> --execute

  # release both in one run
  bash scripts/release-packages.sh --owner <github-owner> \
    --dcb-version <vX.Y.Z> --playbook-version <vX.Y.Z> --execute

options:
  --owner <owner>               GitHub owner (required)
  --dcb-version <vX.Y.Z>        DCB release tag
  --playbook-version <vX.Y.Z>   ai-playbook tag (source-only, no release)
  --execute                     Actually execute release operations
  --audit                       Audit release assets across all repos and exit
  -h, --help                    Show help

notes:
  - Specify at least one of --dcb-version / --playbook-version.
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

# リポジトリ外の一時クローンでコミットする際に使う identity。
# 供給元はプロジェクト .env（GIT_IDENTITY_NAME / GIT_IDENTITY_EMAIL）に一本化する。
# global へのフォールバックには依存しない。setup-git-identity.sh が global identity を
# 削除して user.useConfigOnly=true を立てるため、フォールバックは存在しない。
RELEASE_AUTHOR_NAME=""
RELEASE_AUTHOR_EMAIL=""
resolve_release_identity() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # 環境に値があっても必ずローダーを通す。load-project-env.sh は .env を後勝ちで
  # 上書きする契約であり、「.env が唯一の供給元」を保つには常に通す必要がある。
  # 未設定のときだけ読むと、シェルへ手で export した古い値が .env に勝ってしまい、
  # 一時クローンの commit が意図しない名義になる。
  if [[ -f "$here/load-project-env.sh" ]]; then
    # shellcheck source=/dev/null
    . "$here/load-project-env.sh"
  fi
  RELEASE_AUTHOR_NAME="${GIT_IDENTITY_NAME:-}"
  RELEASE_AUTHOR_EMAIL="${GIT_IDENTITY_EMAIL:-}"
  # 解決できないまま進むと、一時クローンでの commit が exit 128 で止まる。
  # 途中まで公開状態を変えてから落ちるより、着手前に止めるほうが安全。
  if [[ -z "$RELEASE_AUTHOR_NAME" || -z "$RELEASE_AUTHOR_EMAIL" ]]; then
    echo "error: GIT_IDENTITY_NAME / GIT_IDENTITY_EMAIL が解決できません。" >&2
    echo "       プロジェクトルートの .env に設定してください（雛形: .env.example）。" >&2
    exit 1
  fi
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

# Release を作らずタグのみで配布するパッケージ（ai-playbook）向け。
# 不変性の対象は Release ではなくタグそのもの。
require_tag_unpublished() {
  local repo="$1" tag="$2"
  if gh api "repos/$repo/git/refs/tags/$tag" >/dev/null 2>&1; then
    echo "error: $repo already has tag $tag" >&2
    echo "       公開済みのタグは不変です。版を上げてください。" >&2
    echo "       やり直す場合は、先に公開側のタグを削除してください:" >&2
    echo "         git push $repo :refs/tags/$tag" >&2
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

# すべてのパッケージリリースに必須のリリース資産。
REQUIRED_RELEASE_ASSETS=("RELEASE-MANIFEST.json" "SHA256SUMS" "PACKAGE_ARCHIVE.tar.gz")

# ソースを公開リポジトリへ反映し、タグを push する。GitHub Release は作らない。
# 文書パッケージ（ai-playbook）向け。消費者は git タグを固定して取り込むため、
# タグそのものが配布物になる。
push_source_and_tag() {
  local dir="$1" repo="$2" tag="$3"

  init_and_push_release_repo "$dir" "$repo" public

  pushd "$dir" >/dev/null
  # 既存タグは動かさない。公開済みのタグが別の内容を指すと、固定した利用者の
  # 取り込み結果が変わる。unpublished 検査は preflight 済みだが、ここでも守る。
  if git ls-remote --tags origin | grep -q "refs/tags/$tag\$"; then
    echo "error: $repo already has tag $tag; refusing to move it" >&2
    popd >/dev/null
    exit 1
  fi
  git tag "$tag"
  git push origin "$tag"
  popd >/dev/null
  echo "[ok] $repo tagged $tag (source-only, no release)"
}

# 指定パッケージの標準リリース資産 3 点を <dir> に生成する。
# 使い方: generate_standard_assets <dir> <package-name> <version>
generate_standard_assets() {
  local dir="$1"
  local pkg_name="$2"
  local version="$3"
  local archive_tmp

  pushd "$dir" >/dev/null

  # PACKAGE_ARCHIVE.tar.gz — .git ディレクトリを除いた全ツリー
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

  # assets は「この Release に添付されるファイル」の一覧。標準 3 資産だけを固定で
  # 書いていると、README が公式の入手手順として案内する bootstrap.sh / doctor.sh が
  # 載らず、マニフェストだけを見た利用者は何を取得すればよいか分からない。
  # SUMS_TARGETS が「利用者が実際にダウンロードするファイル」の正本なので、そこから
  # 組み立てる。連想配列を使わないのは macOS の bash 3.2 互換を保つため。
  local assets_json="" asset
  for asset in RELEASE-MANIFEST.json SHA256SUMS PACKAGE_ARCHIVE.tar.gz "${SUMS_TARGETS[@]}"; do
    case "$assets_json" in
      *"\"$asset\""*) continue ;;
    esac
    if [[ -n "$assets_json" ]]; then
      assets_json="$assets_json,"$'\n'
    fi
    assets_json="$assets_json    \"$asset\""
  done

  cat > RELEASE-MANIFEST.json <<JSON
{
  "package": "$pkg_name",
  "version": "$version",
  "assets": [
$assets_json
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

prepare_playbook_release_repo() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  # 配布リポジトリのルート = .ai-playbook の中身。ドット始まりの正本を展開する。
  cp -R .ai-playbook/. "$dir/"
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
    # identity を明示する。ここはリポジトリ外の一時クローンであり、local 設定を
    # 持たない。setup-git-identity.sh が global identity を削除し
    # user.useConfigOnly=true を立てているため、明示しないと git が exit 128 で止まる
    # （黙って別名義でコミットされるより安全側に倒した設計。
    #  .github/project-ai-rules.md「Git identity」）。
    git -c user.name="$RELEASE_AUTHOR_NAME" -c user.email="$RELEASE_AUTHOR_EMAIL" \
      commit -m "chore: release snapshot"
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

# 指定 owner の全リポジトリを対象に、必須リリース資産を監査する。
# レポートを出力し、必須資産に欠けがあれば非ゼロで終了する。
audit_release_assets() {
  local owner="$1"
  # ai-playbook は Release 資産を持たない（タグのみ配布）ため監査対象外。
  local repos=("$owner/devcontainer-bootstrap")
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
PLAYBOOK_TAG=""
EXECUTE="false"
AUDIT="false"
SUMS_TARGETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="$2"; shift 2 ;;
    --dcb-version) DCB_TAG="$2"; shift 2 ;;
    --playbook-version) PLAYBOOK_TAG="$2"; shift 2 ;;
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
[[ -n "$DCB_TAG" || -n "$PLAYBOOK_TAG" ]] || {
  echo "error: specify at least one of --dcb-version or --playbook-version" >&2
  usage
  exit 1
}

require_cmd git
require_cmd gh
require_cmd bash
require_cmd tar
require_cmd sha256sum
# python3 は validate_markdown_links_in_tree の実体であり、preflight で必ず走る。
# ここで検査しないと、不在環境では「python3: command not found」という、
# 何の前提が欠けているのか分からないエラーで preflight が落ちる。
require_cmd python3
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
  validate_markdown_links_in_tree "$(pwd)/.ai-playbook"
  run_dcb_tests
fi

if [[ -n "$PLAYBOOK_TAG" ]]; then
  extract_semver "$PLAYBOOK_TAG" >/dev/null
  require_tag_unpublished "$OWNER/ai-playbook" "$PLAYBOOK_TAG"
  validate_markdown_links_in_tree "$(pwd)/.ai-playbook"
fi

echo "[ok] preflight checks passed"

if [[ "$EXECUTE" != "true" ]]; then
  echo "[info] dry-run mode. add --execute to publish releases"
  exit 0
fi

# identity は「実行が確定した直後・最初の副作用より前」に解決する。
# preflight より前に置くと、.env を持たない環境（CI・テスト）で版の重複検査へ
# 到達できなくなる。identity が要るのは一時クローンでの commit だけなので、
# dry-run と検査だけの実行に .env を要求しない。
resolve_release_identity

ROOT_DIR="$(pwd)"
DCB_DIR="/tmp/dcb-release"
PLAYBOOK_DIR="/tmp/playbook-release"

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

if [[ -n "$PLAYBOOK_TAG" ]]; then
  # ai-playbook は submodule / subtree でタグ固定して取り込む文書パッケージ。
  # 消費者はリリース資産をダウンロードせず、git タグそのものが配布物になる。
  # したがって GitHub Release も 3 資産も作らず、ソースを公開リポジトリへ反映して
  # タグを push するだけにする。DCB の --playbook-from も git 由来の
  # archive/refs/tags/ tarball を使うため、Release は不要（RELEASE_PROCESS_RECORD）。
  prepare_playbook_release_repo "$PLAYBOOK_DIR"
  push_source_and_tag "$PLAYBOOK_DIR" "$OWNER/ai-playbook" "$PLAYBOOK_TAG"
fi

cd "$ROOT_DIR"

if [[ -x scripts/update-release-status.sh ]]; then
  bash scripts/update-release-status.sh --owner "$OWNER" --readme README.md
  echo "[info] README release status refreshed. commit README.md if changed."
else
  echo "[warn] scripts/update-release-status.sh not found or not executable; skip README refresh"
fi

echo "[ok] completed releases"
for r in "$OWNER/devcontainer-bootstrap" "$OWNER/ai-playbook"; do
  echo "[repo] $r"
  gh release list --repo "$r" --limit 3 || true
  echo "---"
done

audit_release_assets "$OWNER"

