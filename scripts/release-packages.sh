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
  --audit                       Verify published release asset integrity and exit
  -h, --help                    Show help

notes:
  - Specify at least one of --dcb-version / --playbook-version.
    Only the specified packages are touched; the others are left untouched.
  - Published versions are immutable. Re-releasing an existing version fails
    during preflight, before any side effect.
  - Without --execute, this script only validates inputs and exits.
  - Use --audit to re-download published assets and verify them by recomputing
    SHA256 (SHA256SUMS vs actual files, and RELEASE-MANIFEST.json vs SHA256SUMS).
    Scope is the latest AUDIT_RELEASE_LIMIT releases (default 10); the number of
    releases left outside that scope is always reported. Read-only.
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: command not found: $1" >&2
    exit 1
  }
}

# リリースの実行場所は GitHub Actions に一本化する。
#
# 文書からローカル手順を消すだけでは「規約は禁じているが機構は許している」状態が
# 残り、保証が指示文に依存する。ここで機構として拒否する。
#
# 判定は Actions が必ず設定する GITHUB_ACTIONS で行う。この変数を手で偽装すれば
# 越えられるが、それは故意の迂回であり、事故としてのローカル実行は必ず止まる。
# 実行環境の同一性を担保する仕組みであって、権限の境界ではない。
#
# 呼び出しは preflight より前に置く。DCB 機能テストに 4 分かけてから拒否しても
# 実行できないことに変わりはなく、早く止まるほうが手戻りが小さい。
# dry-run（`--execute` なし）と `--audit` は副作用を持たないため、ローカルでも
# 従来どおり実行できる。
require_actions_runtime() {
  if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
    echo "error: --execute は GitHub Actions 上でのみ実行できます。" >&2
    echo "       ローカルからのリリース実行は廃止しました。" >&2
    echo "       release workflow を workflow_dispatch から起動してください" >&2
    echo "       （手順: docs/release/RELEASE_EXECUTION_RUNBOOK.md）。" >&2
    echo "       ローカルで実行できるのは --execute なしの dry-run と --audit です。" >&2
    exit 1
  fi
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
    echo "       ローカル実行なら .env（雛形: .env.example）、Actions ならワークフローの env で渡してください。" >&2
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

# 公開配布物のファイル一覧。開発リポジトリ内のパスと、配布先ルートでの名前を
# "src:dst" の対で持つ。macOS の bash 3.2 互換を保つため連想配列は使わない。
#
# 配布先には docs/release/ という階層が存在しない（ai-playbook は .ai-playbook/ の
# 中身がルートへ展開され、DCB はごく少数のファイルがルートへ並ぶ）。そのため
# リリースノートは配布先ルートで解決できる CHANGELOG.md という名前へ移して配る。
# 変更履歴の正本は開発リポジトリの docs/release/ 側のままで、配布はその写しになる。
DCB_DISTRIBUTED_FILES=(
  "packages/devcontainer-bootstrap/bootstrap.sh:bootstrap.sh"
  "packages/devcontainer-bootstrap/doctor.sh:doctor.sh"
  "packages/devcontainer-bootstrap/README.md:README.md"
  "LICENSE:LICENSE"
  "docs/release/release-notes-devcontainer-bootstrap.md:CHANGELOG.md"
)

# ai-playbook はツリー全体（.ai-playbook/.）を展開したうえで、開発リポジトリの
# 別階層にある共通ファイルを追加で載せる。
PLAYBOOK_DISTRIBUTED_FILES=(
  "LICENSE:LICENSE"
  "docs/release/release-notes-ai-playbook.md:CHANGELOG.md"
)

# 一覧に載っているのに実体が無い場合は落とす。黙って欠けたまま公開すると、
# 配布先のルートからライセンスや変更履歴が消えたことに誰も気づかない。
copy_distributed_files() {
  local dir="$1"
  shift
  local entry src dst
  for entry in "$@"; do
    src="${entry%%:*}"
    dst="${entry#*:}"
    [[ -f "$src" ]] || {
      echo "error: distribution source not found: $src" >&2
      exit 1
    }
    cp "$src" "$dir/$dst"
  done
}

# dry-run で「何が配布先へ載るか」を見えるようにする。実行しないと分からない
# 状態だと、配布経路へ載せたつもりのファイルが載っていないことを確認できない。
print_distribution_plan() {
  local label="$1"
  shift
  local entry
  echo "[plan] $label distributed files:"
  for entry in "$@"; do
    echo "[plan]   ${entry%%:*} -> ${entry#*:}"
  done
}

prepare_dcb_release_repo() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"

  copy_distributed_files "$dir" "${DCB_DISTRIBUTED_FILES[@]}"
}

prepare_playbook_release_repo() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  # 配布リポジトリのルート = .ai-playbook の中身。ドット始まりの正本を展開する。
  cp -R .ai-playbook/. "$dir/"
  copy_distributed_files "$dir" "${PLAYBOOK_DISTRIBUTED_FILES[@]}"
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

# 監査で検査する直近リリースの既定件数。
#
# 全件走査にしない理由: 監査は資産を実際にダウンロードして再計算するため、
# 実行時間がリリース数に比例して伸びる。ただし打ち切った事実を黙って隠すと
# 「全部見た」と読めてしまうため、検査した件数と範囲外の件数を必ず出力する。
# 件数は環境変数 AUDIT_RELEASE_LIMIT で変更できる（定期実行の workflow が渡す）。
AUDIT_RELEASE_LIMIT_DEFAULT=10

# リリース一覧を引くときに gh へ渡す上限。総数の算出はこの一覧を数えて行うため、
# 上限に達した場合は総数が実際より少なく見える。切り捨てた範囲は必ず出力へ明示する
# 方針（#193）に合わせ、達したときは警告を出して件数が不完全であることを示す。
AUDIT_RELEASE_LIST_LIMIT=1000

# 資産名が「リリース直下の単一ファイル名」であることを検証する。
# 使い方: is_plain_asset_name <name>
#
# SHA256SUMS / RELEASE-MANIFEST.json に載る名前は監査対象（＝外部）の入力であり、
# そのまま "$dir/$name" へ連結すると `/` や `..` で監査ディレクトリの外を参照できて
# しまう。リリース資産は Release 直下のフラットなファイルしか無い前提なので、
# 区切りや相対参照を含む名前は「監査対象が壊れている／悪意がある」ことの徴候その
# もので、黙って読み飛ばさず呼び出し側で FAIL として報告する。
#
# 戻り値: 0 = 単一ファイル名 / 1 = それ以外
is_plain_asset_name() {
  local name="$1"
  [[ -n "$name" ]] || return 1
  # パス区切りを含むものは、相対・絶対を問わず対象外。`../x` もここで落ちる。
  [[ "$name" != */* ]] || return 1
  # 区切りが無くてもディレクトリ自身を指す名前は資産ではない。
  [[ "$name" != "." && "$name" != ".." ]] || return 1
  return 0
}

# ダウンロード済みのリリース資産 1 件分を検証する。
# 使い方: verify_release_assets_dir <dir> <label>
#
# ネットワークへ出ず <dir> の中身だけで完結させる。取得（gh）と検証を分けることで、
# 意図的に壊した入力で落ちることをテストから直接固定できる。
#
# 検証内容:
#   1. SHA256SUMS の各行と、実ファイルを再計算したハッシュが一致すること
#   2. RELEASE-MANIFEST.json の記載と SHA256SUMS が矛盾しないこと
#
# 戻り値: 0 = 整合 / 1 = 不整合（どのファイルのどの値が食い違ったかを出力する）
verify_release_assets_dir() {
  local dir="$1"
  local label="$2"
  local failed=0
  local asset name expected actual declared

  # 必須資産の存在。ここが欠けるとハッシュ照合そのものが成立しない。
  for asset in "${REQUIRED_RELEASE_ASSETS[@]}"; do
    if [[ ! -f "$dir/$asset" ]]; then
      echo "[audit] FAIL  $label  $asset — 必須資産が無い"
      failed=1
    fi
  done
  if [[ ! -f "$dir/SHA256SUMS" || ! -f "$dir/RELEASE-MANIFEST.json" ]]; then
    # 照合の起点そのものが無い。欠落は上で報告済みなので、ここで打ち切る。
    return 1
  fi

  # ── 1. SHA256SUMS の各行 vs 実ファイルの再計算値 ────────────────────────────
  #
  # 利用者が documented な手順（sha256sum -c SHA256SUMS）で実行するのと同じ照合を、
  # 公開されている実体に対して行う。存在確認では、資産が差し替わっても素通りする。
  local sums_lines=0
  while read -r expected name || [[ -n "$expected" ]]; do
    [[ -n "$expected" && -n "$name" ]] || continue
    # sha256sum のバイナリモード印を落とす（"<hash>  *<name>" 形式）。
    name="${name#\*}"
    sums_lines=$((sums_lines + 1))
    if ! is_plain_asset_name "$name"; then
      echo "[audit] FAIL  $label  $name — SHA256SUMS の項目名が単一ファイル名でない"
      failed=1
      continue
    fi
    if [[ ! -f "$dir/$name" ]]; then
      echo "[audit] FAIL  $label  $name — SHA256SUMS が列挙するファイルが資産に無い"
      failed=1
      continue
    fi
    actual="$(sha256sum "$dir/$name" | awk '{print $1}')"
    if [[ "$actual" == "$expected" ]]; then
      echo "[audit] OK    $label  $name  (SHA256SUMS)"
    else
      echo "[audit] FAIL  $label  $name — SHA256SUMS の記載と実ファイルが不一致"
      echo "[audit]         SHA256SUMS 記載: $expected"
      echo "[audit]         実ファイル再計算: $actual"
      failed=1
    fi
  done < "$dir/SHA256SUMS"

  if [[ $sums_lines -eq 0 ]]; then
    # 空の SHA256SUMS は sha256sum -c を無条件に通す。検証手順が素通りする状態は
    # 「検証していないのに緑」なので、不整合として扱う。
    echo "[audit] FAIL  $label  SHA256SUMS が 1 行も列挙していない"
    failed=1
  fi

  # ── 2. RELEASE-MANIFEST.json の記載 vs SHA256SUMS ───────────────────────────
  local manifest="$dir/RELEASE-MANIFEST.json"
  if ! jq -e 'type == "object"' "$manifest" >/dev/null 2>&1; then
    echo "[audit] FAIL  $label  RELEASE-MANIFEST.json を JSON として読めない"
    return 1
  fi

  # checksums / assets の型も明示的に検査する。壊れた入力でこれらが期待と違う型に
  # なると、後続の `to_entries[]` / `.[]` が jq のエラーで何も出力せず、照合ループが
  # 空入力のまま素通りする。「検査対象が壊れているのに緑」になる経路なので、型不正
  # そのものを FAIL として扱う。未定義（null）は既定値で補うため許容する。
  if ! jq -e '(.checksums == null) or ((.checksums | type) == "object")' "$manifest" >/dev/null 2>&1; then
    echo "[audit] FAIL  $label  RELEASE-MANIFEST.json の checksums が object でない"
    return 1
  fi
  if ! jq -e '(.assets == null) or ((.assets | type) == "array")' "$manifest" >/dev/null 2>&1; then
    echo "[audit] FAIL  $label  RELEASE-MANIFEST.json の assets が array でない"
    return 1
  fi

  # マニフェストは SHA256SUMS 自身のハッシュを記録しており、これが検証チェーンの根に
  # なる。ここが合っていれば「SHA256SUMS ごと差し替えられていない」ことをマニフェスト
  # 側からも言える。SHA256SUMS の自己照合だけでは、両方を同時に書き換えられた場合に
  # 何も検出できない。
  while IFS=$'\t' read -r name expected; do
    [[ -n "$name" ]] || continue
    if ! is_plain_asset_name "$name"; then
      echo "[audit] FAIL  $label  $name — RELEASE-MANIFEST.json の checksums のキーが単一ファイル名でない"
      failed=1
      continue
    fi
    if [[ ! -f "$dir/$name" ]]; then
      echo "[audit] FAIL  $label  $name — RELEASE-MANIFEST.json が記録するファイルが資産に無い"
      failed=1
      continue
    fi
    actual="$(sha256sum "$dir/$name" | awk '{print $1}')"
    if [[ "$actual" == "$expected" ]]; then
      echo "[audit] OK    $label  $name  (RELEASE-MANIFEST.json)"
    else
      echo "[audit] FAIL  $label  $name — RELEASE-MANIFEST.json の記載と実ファイルが不一致"
      echo "[audit]         RELEASE-MANIFEST.json 記載: $expected"
      echo "[audit]         実ファイル再計算          : $actual"
      failed=1
    fi

    # 同じファイルが SHA256SUMS にも載っているなら、宣言どうしも直接突き合わせる。
    # 実ファイルとの比較だけでも不一致は捕まるが、「どちらの宣言が食い違ったか」を
    # 出力に残さないと、公開物のどこを直せばよいか読み取れない。
    declared="$(awk -v f="$name" '$2 == f || $2 == "*" f {print $1; exit}' "$dir/SHA256SUMS")"
    if [[ -n "$declared" && "$declared" != "$expected" ]]; then
      echo "[audit] FAIL  $label  $name — RELEASE-MANIFEST.json と SHA256SUMS の記載が矛盾"
      echo "[audit]         RELEASE-MANIFEST.json 記載: $expected"
      echo "[audit]         SHA256SUMS 記載           : $declared"
      failed=1
    fi
  done < <(jq -r '.checksums // {} | to_entries[] | [.key, .value] | @tsv' "$manifest")

  # assets は「この Release に添付されるファイル」の宣言。宣言されているのに無い
  # ものは、マニフェストだけを見た利用者が入手手順どおりに取得できない状態を指す。
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if ! is_plain_asset_name "$name"; then
      echo "[audit] FAIL  $label  $name — RELEASE-MANIFEST.json の assets の要素が単一ファイル名でない"
      failed=1
      continue
    fi
    if [[ ! -f "$dir/$name" ]]; then
      echo "[audit] FAIL  $label  $name — RELEASE-MANIFEST.json の assets にあるが資産として存在しない"
      failed=1
    fi
  done < <(jq -r '.assets // [] | .[]' "$manifest")

  # 逆向き（SHA256SUMS にあるのに assets へ載っていない）は NOTE に留める。
  # 公開済みリリースは不変で、過去分は直せない（v0.7.3 より前の 12 件は assets が
  # 標準 3 資産のみで bootstrap.sh / doctor.sh を載せていない）。以後のリリースで
  # この欠落を防ぐ検査は tests/test-release-contract.sh が持つため、ここで落とすと
  # 直せない過去のせいで監査が恒久的に赤になり、新しい異常が埋もれる。
  while read -r expected name || [[ -n "$expected" ]]; do
    [[ -n "$name" ]] || continue
    name="${name#\*}"
    if ! jq -e --arg n "$name" '(.assets // []) | index($n)' "$manifest" >/dev/null 2>&1; then
      echo "[audit] NOTE  $label  $name — SHA256SUMS にあるが RELEASE-MANIFEST.json の assets に無い"
    fi
  done < "$dir/SHA256SUMS"

  return "$failed"
}

# 指定 owner の公開リリース資産を監査する。
#
# 存在確認ではなく SHA256 の再計算で整合性を検証する（#193）。存在するだけの検査は
# 「実質を検査できず、儀式のみを検査できるもの」（`.ai-playbook/shared-ai-rules.md`
# 12 章）に当たり、資産が差し替わっても素通りしていた。
#
# 検査範囲は直近 AUDIT_RELEASE_LIMIT 件（既定 10）。範囲外として見ていない件数を
# 必ず出力する。黙って打ち切ると「全部見た」と読めてしまうため。
#
# 副作用: 読み取りのみ。資産のダウンロード以外に公開状態へ触れない。
audit_release_assets() {
  local owner="$1"
  local limit="${AUDIT_RELEASE_LIMIT:-$AUDIT_RELEASE_LIMIT_DEFAULT}"

  if ! [[ "$limit" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: AUDIT_RELEASE_LIMIT must be a positive integer, got: $limit" >&2
    return 1
  fi

  # 呼び出し元（--audit 経路 / リリース末尾）のどちらから来ても同じ前提を要求する。
  require_cmd gh
  require_cmd jq
  require_cmd sha256sum

  # ai-playbook は Release 資産を持たない（タグのみ配布）ため監査対象外。
  local repos=("$owner/devcontainer-bootstrap")
  local failed=0
  local repo tag tags total inspected skipped dir workroot
  local grand_inspected=0 grand_skipped=0
  local taglist

  workroot="$(mktemp -d)"

  echo "[audit] verifying release asset integrity by recomputing SHA256 (limit: $limit)"

  for repo in "${repos[@]}"; do
    if ! tags="$(gh release list --repo "$repo" --limit "$AUDIT_RELEASE_LIST_LIMIT" --json tagName --jq '.[].tagName' 2>/dev/null)"; then
      echo "[audit] FAIL  $repo — リリース一覧を取得できない"
      failed=1
      continue
    fi

    total=0
    inspected=0
    taglist=()
    while IFS= read -r tag; do
      [[ -n "$tag" ]] || continue
      total=$((total + 1))
      if [[ $inspected -lt $limit ]]; then
        taglist+=("$tag")
        inspected=$((inspected + 1))
      fi
    done <<< "$tags"

    if [[ $total -eq 0 ]]; then
      echo "[audit] WARN  $repo — no releases found"
      continue
    fi

    skipped=$((total - inspected))
    grand_inspected=$((grand_inspected + inspected))
    grand_skipped=$((grand_skipped + skipped))
    echo "[audit] scope $repo — 公開 $total 件中 $inspected 件を検査（範囲外・未検査: $skipped 件）"

    # 一覧そのものが上限で切れている場合、$total は「公開されている全件」ではなく
    # 「取得できた件数」でしかない。範囲外の件数が実際より少なく見えるため、
    # 数字が不完全であることを出力に明示する（黙って過少報告しない）。
    if [[ $total -ge $AUDIT_RELEASE_LIST_LIMIT ]]; then
      echo "[audit] WARN  $repo — リリース一覧が取得上限 $AUDIT_RELEASE_LIST_LIMIT 件に達した。公開件数・範囲外件数は実際より少ない可能性がある"
    fi

    for tag in "${taglist[@]}"; do
      # 作業ディレクトリ名にタグやリポジトリ名を埋め込まない。タグは公開リポジトリ
      # 側が決める外部入力で、`../` を含む値がそのままパスへ入ると mkdir -p / rm -rf
      # が想定外の場所へ作用し得る。どのリリースを見ているかは出力の label が持つ
      # ので、パスは mktemp -d に任せて安全な名前だけを使う。
      dir="$(mktemp -d "$workroot/asset.XXXXXXXX")"
      if ! gh release download "$tag" --repo "$repo" --dir "$dir" >/dev/null 2>&1; then
        echo "[audit] FAIL  $repo@$tag — 資産を取得できない"
        failed=1
        continue
      fi
      if ! verify_release_assets_dir "$dir" "$repo@$tag"; then
        failed=1
      fi
      # 検証の済んだ資産はその場で捨てる。件数に比例して一時領域を食わせない。
      rm -rf "$dir"
    done
  done

  rm -rf "$workroot"

  # 合否にかかわらず、見た件数と見ていない件数を同じ行で示す。「成功」だけを
  # 出力すると、範囲外の分まで検証済みと読まれる。
  if [[ $failed -eq 0 ]]; then
    echo "[audit] integrity verified — 検査 $grand_inspected 件 / 範囲外・未検査 $grand_skipped 件"
  else
    echo "[audit] integrity check failed — 検査 $grand_inspected 件 / 範囲外・未検査 $grand_skipped 件" >&2
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

# 副作用を伴う実行は、他の検査より先に実行環境を確かめる。
# --audit は読み取りのみでここへ到達しないため、ローカルでも従来どおり使える。
if [[ "$EXECUTE" == "true" ]]; then
  require_actions_runtime
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

if [[ -n "$DCB_TAG" ]]; then
  print_distribution_plan "devcontainer-bootstrap" "${DCB_DISTRIBUTED_FILES[@]}"
fi

if [[ -n "$PLAYBOOK_TAG" ]]; then
  echo "[plan] ai-playbook distributed files:"
  echo "[plan]   .ai-playbook/. -> (repository root)"
  print_distribution_plan "ai-playbook (additional)" "${PLAYBOOK_DISTRIBUTED_FILES[@]}"
fi

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

