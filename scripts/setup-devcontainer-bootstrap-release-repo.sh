#!/usr/bin/env bash
set -euo pipefail

# setup-devcontainer-bootstrap-release-repo.sh
# packages/devcontainer-bootstrap の配布成果物を、公開用リポジトリ向けに初期化する。
#
# 使い方:
#   bash scripts/setup-devcontainer-bootstrap-release-repo.sh \
#     --target-dir /tmp/devcontainer-bootstrap-release \
#     --repo-name devcontainer-bootstrap \
#     --create-remote
#
# 前提:
# - コンテナ内で gh auth login 済み（認証状態は gh-storage volume に残る）
# - 対象オーナーへ書き込める権限を持つアカウントでログインしていること
#   bash -c 'gh auth status'

usage() {
  cat <<'EOF'
usage:
  bash scripts/setup-devcontainer-bootstrap-release-repo.sh \
    --target-dir <path> \
    [--repo-name <name>] \
    [--owner <owner>] \
    [--repo <owner/repo>] \
    [--source-dir <path>] \
    [--default-branch <name>] \
    [--create-remote] \
    [--force]

options:
  --target-dir <path>       作業ディレクトリ（必須）
  --repo-name <name>        リポジトリ名（default: devcontainer-bootstrap）
  --owner <owner>           GitHub owner（未指定時は github.owner or gh api user）
  --repo <owner/repo>       owner/repo を直接指定（--owner/--repo-name より優先）
  --source-dir <path>       ソースディレクトリ（default: packages/devcontainer-bootstrap）
  --default-branch <name>   デフォルトブランチ名（default: main）
  --create-remote           GitHub 公開リポジトリを作成し push する
  --force                   target-dir が空でなくても続行する

examples:
  bash scripts/setup-devcontainer-bootstrap-release-repo.sh \
    --target-dir /tmp/devcontainer-bootstrap-release \
    --repo-name devcontainer-bootstrap \
    --create-remote

  bash scripts/setup-devcontainer-bootstrap-release-repo.sh \
    --target-dir /tmp/devcontainer-bootstrap-release \
    --repo ojos/devcontainer-bootstrap \
    --create-remote
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

resolve_owner() {
  local explicit_owner="$1"
  if [[ -n "$explicit_owner" ]]; then
    printf '%s' "$explicit_owner"
    return
  fi

  local owner_from_git
  owner_from_git="$(git config --local github.owner 2>/dev/null || true)"
  if [[ -n "$owner_from_git" ]]; then
    printf '%s' "$owner_from_git"
    return
  fi

  gh api user --jq .login
}

copy_release_files() {
  local src="$1"
  local dst="$2"

  mkdir -p "$dst/.github/workflows"

  cp "$src/bootstrap.sh" "$dst/bootstrap.sh"
  cp "$src/doctor.sh" "$dst/doctor.sh"

  if [[ -f "$src/README.md" ]]; then
    cp "$src/README.md" "$dst/README.md"
  fi

  cp "$src/.github/workflows/release.yml" "$dst/.github/workflows/release.yml"
}

main() {
  local target_dir=""
  local repo_name="devcontainer-bootstrap"
  local explicit_owner=""
  local repo_full=""
  local source_dir="packages/devcontainer-bootstrap"
  local create_remote="false"
  local force="false"
  local default_branch="main"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target-dir)
        target_dir="$2"
        shift 2
        ;;
      --repo-name)
        repo_name="$2"
        shift 2
        ;;
      --owner)
        explicit_owner="$2"
        shift 2
        ;;
      --repo)
        repo_full="$2"
        shift 2
        ;;
      --source-dir)
        source_dir="$2"
        shift 2
        ;;
      --default-branch)
        default_branch="$2"
        shift 2
        ;;
      --create-remote)
        create_remote="true"
        shift
        ;;
      --force)
        force="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "error: unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$target_dir" ]]; then
    echo "error: --target-dir is required" >&2
    usage
    exit 1
  fi

  require_cmd git
  require_cmd gh

  if [[ ! -d "$source_dir" ]]; then
    echo "error: source dir not found: $source_dir" >&2
    exit 1
  fi

  if [[ ! -f "$source_dir/bootstrap.sh" || ! -f "$source_dir/doctor.sh" || ! -f "$source_dir/.github/workflows/release.yml" ]]; then
    echo "error: source dir is missing required files" >&2
    echo "       required: bootstrap.sh, doctor.sh, .github/workflows/release.yml" >&2
    exit 1
  fi

  if [[ -d "$target_dir" ]]; then
    if [[ "$force" != "true" ]] && [[ -n "$(ls -A "$target_dir" 2>/dev/null || true)" ]]; then
      echo "error: target dir is not empty: $target_dir" >&2
      echo "       use --force to continue" >&2
      exit 1
    fi
  fi
  mkdir -p "$target_dir"

  copy_release_files "$source_dir" "$target_dir"

  bash -n "$target_dir/bootstrap.sh"
  bash -n "$target_dir/doctor.sh"

  pushd "$target_dir" >/dev/null

  if [[ ! -d .git ]]; then
    git init -b "$default_branch"
  fi

  git add bootstrap.sh doctor.sh .github/workflows/release.yml
  if [[ -f README.md ]]; then
    git add README.md
  fi

  if ! git diff --cached --quiet; then
    git commit -m "chore: initialize devcontainer-bootstrap release repo"
  fi

  if [[ -z "$repo_full" ]]; then
    local owner
    owner="$(resolve_owner "$explicit_owner")"
    repo_full="$owner/$repo_name"
  fi

  if [[ "$create_remote" == "true" ]]; then
    if gh repo view "$repo_full" >/dev/null 2>&1; then
      echo "[info] remote repository already exists: $repo_full"
      if ! git remote get-url origin >/dev/null 2>&1; then
        git remote add origin "https://github.com/$repo_full.git"
      fi
      git push -u origin "$default_branch"
    else
      gh repo create "$repo_full" --public --source . --remote origin --push
    fi
  fi

  popd >/dev/null

  echo "[ok] prepared: $target_dir"
  echo "[ok] release repo: $repo_full"
  if [[ "$create_remote" == "true" ]]; then
    echo "[ok] remote push: completed"
  else
    echo "[info] remote push: skipped (run with --create-remote)"
  fi
}

main "$@"
