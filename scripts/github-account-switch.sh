#!/usr/bin/env bash
set -euo pipefail

# github-account-switch.sh
# N個のGitHubプロファイルを環境変数で定義し、任意のプロファイルへ切替える。
#
# プロファイル名は任意の英数字・アンダースコア（例: primary, secondary, work, personal）。
# 環境変数命名規則:
#   GITHUB_TOKEN_<PROFILE_UPPER>      (必須) 認証トークン
#   GITHUB_OWNER_<PROFILE_UPPER>      (任意) 操作対象オーナー（個人またはOrg）
#   GIT_AUTHOR_NAME_<PROFILE_UPPER>   (任意) git user.name
#   GIT_AUTHOR_EMAIL_<PROFILE_UPPER>  (任意) git user.email
#
# GITHUB_OWNER はトークン発行者と異なる場合に設定する。
# 例: individual-user のトークンで my-org 組織のリポジトリを操作する場合:
#   GITHUB_TOKEN_PRIMARY=ghp_individual_user_token
#   GITHUB_OWNER_PRIMARY=my-org
#
# use 実行後、解決された owner は git config (github.owner) に保存される。
# 必要に応じて次で参照できる:
#   git config --local github.owner

usage() {
  cat <<'EOF'
usage:
  bash scripts/github-account-switch.sh status
  bash scripts/github-account-switch.sh list
  bash scripts/github-account-switch.sh auto [--git-scope local|global]
  bash scripts/github-account-switch.sh use <profile> [--git-scope local|global]

subcommands:
  status   現在の gh auth 状態・git identity・owner 情報を表示
  list     設定済みプロファイル（GITHUB_TOKEN_* が存在するもの）を列挙
  auto     環境変数と既存 git config からプロファイルを自動選択して切替
  use      指定プロファイルへ切替

profile:
  任意の英数字・アンダースコア文字列（例: primary, secondary, work, personal）
  対応する GITHUB_TOKEN_<PROFILE_UPPER> が必須

options:
  --git-scope local|global   git config の適用スコープ（default: local）

environment variables (per profile):
  GITHUB_TOKEN_<PROFILE_UPPER>      (required) GitHub personal access token
  GITHUB_OWNER_<PROFILE_UPPER>      (optional) 操作対象オーナー（個人 or Org）
                                               トークン発行者と異なる場合に設定
  GIT_AUTHOR_NAME_<PROFILE_UPPER>   (optional) git user.name for this profile
  GIT_AUTHOR_EMAIL_<PROFILE_UPPER>  (optional) git user.email for this profile

examples:
  # individual-user のトークンで my-org を操作する場合
  export GITHUB_TOKEN_PRIMARY=ghp_individual_user_token
  export GITHUB_OWNER_PRIMARY=my-org
  export GIT_AUTHOR_NAME_PRIMARY=individual-user
  export GIT_AUTHOR_EMAIL_PRIMARY=user@example.com

  # ojos 個人アカウント（owner はログイン名と一致するため GITHUB_OWNER 省略可）
  export GITHUB_TOKEN_SECONDARY=ghp_ojos_token

  bash scripts/github-account-switch.sh list
  bash scripts/github-account-switch.sh use primary
  gh repo create "$(git config --local github.owner)/myrepo" --public

notes:
  - Tokens are never written to repository files.
  - GH_TOKEN in the environment takes precedence over stored accounts.
    Do NOT set GH_TOKEN permanently if using multi-profile switching.
  - Resolved owner is stored in git config key `github.owner` after "use".
    If profile-specific owner is unset, authenticated login is used.
EOF
}

# プロファイル名 -> 大文字環境変数サフィックス
profile_to_upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# GITHUB_TOKEN_* が設定済みのプロファイルを列挙
cmd_list() {
  local found=0
  while IFS='=' read -r key _; do
    if [[ "$key" =~ ^GITHUB_TOKEN_(.+)$ ]]; then
      local suffix="${BASH_REMATCH[1]}"
      local profile
      profile="$(printf '%s' "$suffix" | tr '[:upper:]' '[:lower:]')"
      echo "  $profile  (env: GITHUB_TOKEN_${suffix})"
      found=1
    fi
  done < <(env | sort)
  if [[ "$found" -eq 0 ]]; then
    echo "  (none — set GITHUB_TOKEN_<PROFILE> to register a profile)"
  fi
}

cmd_status() {
  echo "[github-account] gh auth status"
  gh auth status -h github.com || true
  echo
  echo "[github-account] git identity"
  echo "  scope=local  name=$(git config --local user.name 2>/dev/null || echo '<unset>')"
  echo "  scope=local  email=$(git config --local user.email 2>/dev/null || echo '<unset>')"
  echo "  scope=global name=$(git config --global user.name 2>/dev/null || echo '<unset>')"
  echo "  scope=global email=$(git config --global user.email 2>/dev/null || echo '<unset>')"
  echo "  github.owner(local)=$(git config --local github.owner 2>/dev/null || echo '<unset>')"
  echo "  github.owner(global)=$(git config --global github.owner 2>/dev/null || echo '<unset>')"
  echo
  echo "[github-account] registered profiles"
  cmd_list
}

cmd_use() {
  local profile="$1"
  shift

  # プロファイル名の検証（英数字・アンダースコアのみ）
  if [[ ! "$profile" =~ ^[a-zA-Z0-9_]+$ ]]; then
    echo "error: invalid profile name '$profile' (alphanumeric and underscore only)" >&2
    exit 1
  fi

  local git_scope="local"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --git-scope)
        git_scope="$2"
        shift 2
        ;;
      *)
        echo "error: unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ "$git_scope" != "local" && "$git_scope" != "global" ]]; then
    echo "error: --git-scope must be local or global" >&2
    exit 1
  fi

  local upper
  upper="$(profile_to_upper "$profile")"
  local token_env="GITHUB_TOKEN_${upper}"
  local name_env="GIT_AUTHOR_NAME_${upper}"
  local email_env="GIT_AUTHOR_EMAIL_${upper}"

  local token="${!token_env:-}"
  if [[ -z "$token" ]]; then
    echo "error: $token_env is not set" >&2
    echo "       run: export $token_env=<your_token>" >&2
    exit 1
  fi

  local login
  login="$(GH_TOKEN="$token" gh api user --jq .login)"
  if [[ -z "$login" || "$login" == "null" ]]; then
    echo "error: unable to resolve github login from token ($token_env)" >&2
    exit 1
  fi

  # Register the account for github.com using the selected token.
  printf '%s' "$token" | gh auth login --hostname github.com --with-token >/dev/null

  # If available, switch explicitly to the target user for deterministic behavior.
  if gh auth switch --help >/dev/null 2>&1; then
    gh auth switch --hostname github.com --user "$login" >/dev/null
  fi

  local git_name="${!name_env:-}"
  local git_email="${!email_env:-}"
  if [[ -n "$git_name" ]]; then
    git config --"$git_scope" user.name "$git_name"
  fi
  if [[ -n "$git_email" ]]; then
    git config --"$git_scope" user.email "$git_email"
  fi

  # Resolve GITHUB_OWNER: use profile-specific value if set, otherwise fall back to login.
  local owner_env="GITHUB_OWNER_${upper}"
  local resolved_owner="${!owner_env:-$login}"
  # Keep a lightweight marker in git config for diagnostics.
  git config --"$git_scope" github.account "$login"
  git config --"$git_scope" github.owner "$resolved_owner"

  echo "[github-account] active profile: $profile"
  echo "[github-account] active login:   $login"
  echo "[github-account] owner:          $resolved_owner"
  echo "[github-account] git scope:      $git_scope"
  echo "[github-account] git user.name:  $(git config --"$git_scope" user.name 2>/dev/null || echo '<unchanged>')"
  echo "[github-account] git user.email: $(git config --"$git_scope" user.email 2>/dev/null || echo '<unchanged>')"
}

list_profile_suffixes() {
  env | awk -F= '/^GITHUB_TOKEN_[A-Z0-9_]+=/ {sub(/^GITHUB_TOKEN_/,"",$1); print $1}' | sort -u
}

resolve_profile_for_repo() {
  if [[ -n "${GITHUB_ACTIVE_PROFILE:-}" ]]; then
    printf '%s' "$GITHUB_ACTIVE_PROFILE"
    return 0
  fi

  local expected_owner
  expected_owner="$(git config --local github.owner 2>/dev/null || true)"
  [[ -z "$expected_owner" ]] && expected_owner="$(git config --global github.owner 2>/dev/null || true)"

  local suffixes
  suffixes="$(list_profile_suffixes)"

  if [[ -n "$expected_owner" ]]; then
    local s owner_var owner_val
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      owner_var="GITHUB_OWNER_${s}"
      owner_val="${!owner_var:-}"
      if [[ -n "$owner_val" && "$owner_val" == "$expected_owner" ]]; then
        printf '%s' "$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
        return 0
      fi
    done <<< "$suffixes"
  fi

  local count
  count="$(printf '%s\n' "$suffixes" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$count" == "1" ]]; then
    printf '%s' "$(printf '%s\n' "$suffixes" | sed -n '1p' | tr '[:upper:]' '[:lower:]')"
    return 0
  fi

  return 1
}

apply_direct_env_identity() {
  local git_scope="$1"
  local token="${GITHUB_TOKEN:-}"
  [[ -n "$token" ]] || return 1

  local login
  login="$(GH_TOKEN="$token" gh api user --jq .login)"
  [[ -n "$login" && "$login" != "null" ]] || return 1

  printf '%s' "$token" | gh auth login --hostname github.com --with-token >/dev/null
  if gh auth switch --help >/dev/null 2>&1; then
    gh auth switch --hostname github.com --user "$login" >/dev/null
  fi

  if [[ -n "${GIT_AUTHOR_NAME:-}" ]]; then
    git config --"$git_scope" user.name "$GIT_AUTHOR_NAME"
  fi
  if [[ -n "${GIT_AUTHOR_EMAIL:-}" ]]; then
    git config --"$git_scope" user.email "$GIT_AUTHOR_EMAIL"
  fi

  local owner="${GITHUB_OWNER:-$login}"
  git config --"$git_scope" github.account "$login"
  git config --"$git_scope" github.owner "$owner"

  echo "[github-account] auto mode: direct env token selected"
  echo "[github-account] active login:   $login"
  echo "[github-account] owner:          $owner"
  echo "[github-account] git scope:      $git_scope"
  return 0
}

cmd_auto() {
  local git_scope="local"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --git-scope)
        git_scope="$2"
        shift 2
        ;;
      *)
        echo "error: unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ "$git_scope" != "local" && "$git_scope" != "global" ]]; then
    echo "error: --git-scope must be local or global" >&2
    exit 1
  fi

  if apply_direct_env_identity "$git_scope"; then
    return 0
  fi

  local profile
  if profile="$(resolve_profile_for_repo)"; then
    cmd_use "$profile" --git-scope "$git_scope"
    return 0
  fi

  echo "[github-account] WARN: auto profile resolution failed"
  echo "[github-account] hint: set GITHUB_ACTIVE_PROFILE or run use <profile> explicitly"
  return 0
}

main() {
  [[ $# -ge 1 ]] || {
    usage
    exit 1
  }

  local sub="$1"
  shift

  case "$sub" in
    status)
      cmd_status
      ;;
    list)
      cmd_list
      ;;
    auto)
      cmd_auto "$@"
      ;;
    use)
      [[ $# -ge 1 ]] || {
        echo "error: missing profile" >&2
        usage
        exit 1
      }
      cmd_use "$@"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "error: unknown subcommand: $sub" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
