#!/usr/bin/env bash
# bootstrap.sh — devcontainer bootstrap one-shot generator (standalone)
# 目的: 新規作業ディレクトリに1コマンドで devcontainer 雛形を生成する
# 使用方法:
#   curl -sSL https://github.com/ojos/devcontainer-bootstrap/releases/latest/download/bootstrap.sh \
#     -o bootstrap.sh && bash bootstrap.sh --project-name myapp --languages node,go --mode standard
set -euo pipefail

# Resolved for locating a sibling dotfiles checkout. When this script is fetched
# standalone (curl), no sibling exists and --dotfiles-from is required.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_NAME=""
MODE="standard"
OUTPUT_DIR=""
LANGUAGES=()
FORCE="false"
DRY_RUN="false"
MANAGE_GITIGNORE="true"
GITIGNORE_TARGETS=""

GITHUB_PROFILES="primary,secondary"
CLAUDE_TOKEN_ENV="CLAUDE_CODE_OAUTH_TOKEN"
GEMINI_KEY_ENV="GEMINI_API_KEY"
BASE_IMAGE_OVERRIDE=""
BASE_IMAGE=""
GITIGNORE_BEGIN="# >>> devcontainer-bootstrap managed section >>>"
GITIGNORE_END="# <<< devcontainer-bootstrap managed section <<<"
GITIGNORE_REPO_RAW_BASE="https://raw.githubusercontent.com/github/gitignore/main"

WITH_DOTFILES=""
DOTFILES_FROM=""
DOTFILES_CONFLICT_POLICY="skip"
DOTFILES_REL_ROOT="dotfiles/ai/common"
DOTFILES_COMMON_DIR=""
DOTFILES_TMP_ROOT=""

usage() {
  cat <<'EOF'
usage: bash bootstrap.sh [options]

options:
  --project-name <name>       Project name for devcontainer display name (required)
  --mode <minimal|standard|full>
                              Template variant (default: standard)
  --languages <csv>           Language runtimes (CSV: node,go,python,php) (required)
  --output-dir <path>         Output directory (default: $PWD/<project-name>)
  --github-profiles <csv>     GitHub profiles for multi-account env injection
                              (default: primary,secondary)
  --claude-token-env <name>   Local env var name for Claude token (default: CLAUDE_CODE_OAUTH_TOKEN)
  --gemini-key-env <name>     Local env var name for Gemini key (default: GEMINI_API_KEY)
  --base-image <image>        Override auto-selected devcontainer base image
  --dry-run                   Show planned outputs without writing files
  --force                     Overwrite existing files
  --no-gitignore              管理対象の .gitignore セクションを更新しない
  --gitignore-targets <csv>   Additional template names to use (e.g. VisualStudioCode,JetBrains)
  --with-dotfiles             Install shared AI rules (dotfiles) and entry files
  --without-dotfiles          Do not install shared AI rules
  --dotfiles-from <path|url>  Dotfiles source (directory path or archive URL)
  --dotfiles-conflict-policy <skip|overwrite|prompt>
                              Policy when a rules file already exists (default: skip)
  -h, --help                  Show help

notes:
  Shared AI rules are maintained in a separate repository. This script places
  them into the generated project; it is a distribution mechanism, not the
  source of truth.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-name)     PROJECT_NAME="$2"; shift 2 ;;
    --mode)             MODE="$2"; shift 2 ;;
    --languages)        IFS=',' read -ra LANGUAGES <<< "$2"; shift 2 ;;
    --output-dir)       OUTPUT_DIR="$2"; shift 2 ;;
    --github-profiles)  GITHUB_PROFILES="$2"; shift 2 ;;
    --claude-token-env) CLAUDE_TOKEN_ENV="$2"; shift 2 ;;
    --gemini-key-env)   GEMINI_KEY_ENV="$2"; shift 2 ;;
    --base-image)       BASE_IMAGE_OVERRIDE="$2"; shift 2 ;;
    --dry-run)          DRY_RUN="true"; shift ;;
    --force)            FORCE="true"; shift ;;
    --no-gitignore)     MANAGE_GITIGNORE="false"; shift ;;
    --gitignore-targets)   GITIGNORE_TARGETS="$2"; shift 2 ;;
    --with-dotfiles)    WITH_DOTFILES="true"; shift ;;
    --without-dotfiles) WITH_DOTFILES="false"; shift ;;
    --dotfiles-from)    DOTFILES_FROM="$2"; shift 2 ;;
    --dotfiles-conflict-policy) DOTFILES_CONFLICT_POLICY="$2"; shift 2 ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# ── Validation ───────────────────────────────────────────────────────────────

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: required command not found: $1" >&2; exit 1; }
}
require_cmd jq
require_cmd perl
require_cmd awk
require_cmd sed
require_cmd curl

[[ -n "$PROJECT_NAME" ]] || { echo "error: --project-name is required" >&2; usage; exit 1; }
[[ ${#LANGUAGES[@]} -gt 0 ]] || { echo "error: --languages is required" >&2; usage; exit 1; }

for i in "${!LANGUAGES[@]}"; do
  LANGUAGES[i]=$(echo "${LANGUAGES[i]}" | xargs)
done
for lang in "${LANGUAGES[@]}"; do
  case "$lang" in
    node|go|python|php) ;;
    *) echo "error: unsupported language: $lang (supported: node, go, python, php)" >&2; exit 1 ;;
  esac
done
case "$MODE" in
  minimal|standard|full) ;;
  *) echo "error: invalid --mode: $MODE" >&2; exit 1 ;;
esac
case "$DOTFILES_CONFLICT_POLICY" in
  skip|overwrite|prompt) ;;
  *) echo "error: --dotfiles-conflict-policy must be one of: skip, overwrite, prompt" >&2; exit 1 ;;
esac
[[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$PWD/$PROJECT_NAME"

# Select base image based on Docker server platform (with safe fallback)
detect_server_platform() {
  local platform
  if command -v docker >/dev/null 2>&1; then
    platform="$(docker version --format '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null || true)"
    if [[ -n "$platform" && "$platform" == */* ]]; then
      printf '%s\n' "$platform"
      return 0
    fi
  fi
  # Fallback for environments without docker access during bootstrap.
  printf '%s\n' "linux/amd64"
}

image_supports_platform() {
  local image="$1"
  local os="$2"
  local arch="$3"
  local manifest

  manifest="$(docker manifest inspect "$image" 2>/dev/null || true)"
  [[ -n "$manifest" ]] || return 1

  printf '%s' "$manifest" | grep -q "\"os\": \"$os\"" || return 1
  printf '%s' "$manifest" | grep -q "\"architecture\": \"$arch\"" || return 1
  return 0
}

select_base_image() {
  local platform os arch
  local candidates
  local image

  if [[ -n "$BASE_IMAGE_OVERRIDE" ]]; then
    BASE_IMAGE="$BASE_IMAGE_OVERRIDE"
    echo "[bootstrap] base-image=override:$BASE_IMAGE"
    return 0
  fi

  platform="$(detect_server_platform)"
  os="${platform%/*}"
  arch="${platform#*/}"

  candidates="mcr.microsoft.com/devcontainers/base:ubuntu mcr.microsoft.com/devcontainers/base:debian"

  if command -v docker >/dev/null 2>&1; then
    for image in $candidates; do
      if image_supports_platform "$image" "$os" "$arch"; then
        BASE_IMAGE="$image"
        echo "[bootstrap] base-image=auto:$BASE_IMAGE ($os/$arch)"
        return 0
      fi
    done
  fi

  BASE_IMAGE="mcr.microsoft.com/devcontainers/base:ubuntu"
  echo "[bootstrap] WARN: no compatible manifest check result; fallback base-image=$BASE_IMAGE ($os/$arch)" >&2
}

select_base_image

# ── Embedded templates (bash 3 compatible) ─────────────────────────────────

mode_rel_paths() {
  case "$1" in
    minimal|standard|full)
      printf '%s\n' \
        '.devcontainer/devcontainer.json' \
        'scripts/github-account-switch.sh' \
        'scripts/install-ai-tools.sh' \
        'scripts/on-attach.sh' \
        'scripts/post-rebuild-check.sh'
      ;;
    *)
      echo "error: unsupported mode in mode_rel_paths: $1" >&2
      exit 1
      ;;
  esac
}

get_template_content() {
  local mode="$1"
  local rel="$2"
  case "$mode:$rel" in
    'minimal:.devcontainer/devcontainer.json')
      cat <<'TMPL'
{
  "name": "__PROJECT_NAME__ (minimal)",
  "image": "__BASE_IMAGE__",
  "features": {
    "ghcr.io/devcontainers/features/common-utils:1": {
      "configureZsh": true
    },
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {
      "version": "latest",
      "moby": false
    },
    "ghcr.io/devcontainers-extra/features/ripgrep:1": {},
    "ghcr.io/devcontainers/features/github-cli:1": {},
    "__IF_RUNTIME_NODE__": "ghcr.io/devcontainers/features/node:1",
    "__IF_RUNTIME_GO__": "ghcr.io/devcontainers/features/go:1",
    "__IF_RUNTIME_PYTHON__": "ghcr.io/devcontainers/features/python:1",
    "__IF_RUNTIME_PHP__": "ghcr.io/devcontainers/features/php:1"
  },
  "remoteEnv": {
__GITHUB_PROFILE_ENV_BLOCK__
    "GEMINI_API_KEY": "${localEnv:__GEMINI_KEY_ENV__}",
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:__CLAUDE_TOKEN_ENV__}",
    "LOCAL_WORKSPACE_FOLDER": "${localWorkspaceFolder}"
  },
  "postCreateCommand": "bash scripts/install-ai-tools.sh",
  "postAttachCommand": "bash scripts/on-attach.sh",
  "customizations": {
    "vscode": {
      "extensions": ["ms-azuretools.vscode-containers"]
    }
  }
}
TMPL
      ;;
    'minimal:scripts/github-account-switch.sh'|'standard:scripts/github-account-switch.sh'|'full:scripts/github-account-switch.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  bash scripts/github-account-switch.sh list
  bash scripts/github-account-switch.sh status
  bash scripts/github-account-switch.sh use <profile> [--git-scope local|global]

profiles:
  GITHUB_TOKEN_<PROFILE_UPPER> を設定した profile を自動検出
  任意で以下も profile ごとに設定可:
    GITHUB_OWNER_<PROFILE_UPPER>
    GIT_AUTHOR_NAME_<PROFILE_UPPER>
    GIT_AUTHOR_EMAIL_<PROFILE_UPPER>
EOF
}

profile_to_upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

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

  [[ "$profile" =~ ^[a-zA-Z0-9_]+$ ]] || {
    echo "error: invalid profile" >&2
    exit 1
  }

  local git_scope="local"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --git-scope)
        git_scope="$2"
        shift 2
        ;;
      *)
        echo "error: unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  local upper token_env name_env email_env owner_env
  upper="$(profile_to_upper "$profile")"
  token_env="GITHUB_TOKEN_${upper}"
  name_env="GIT_AUTHOR_NAME_${upper}"
  email_env="GIT_AUTHOR_EMAIL_${upper}"
  owner_env="GITHUB_OWNER_${upper}"

  local token="${!token_env:-}"
  [[ -n "$token" ]] || {
    echo "error: $token_env is not set" >&2
    exit 1
  }

  local login
  login="$(GH_TOKEN="$token" gh api user --jq .login)"
  printf '%s' "$token" | gh auth login --hostname github.com --with-token >/dev/null
  if gh auth switch --help >/dev/null 2>&1; then
    gh auth switch --hostname github.com --user "$login" >/dev/null
  fi

  local owner="${!owner_env:-$login}"
  local git_name="${!name_env:-}"
  local git_email="${!email_env:-}"

  [[ -n "$git_name" ]] && git config --"$git_scope" user.name "$git_name"
  [[ -n "$git_email" ]] && git config --"$git_scope" user.email "$git_email"
  git config --"$git_scope" github.owner "$owner"
  git config --"$git_scope" github.account "$login"

  echo "[github-account] active profile: $profile"
  echo "[github-account] active login:   $login"
  echo "[github-account] owner:          $owner"
  echo "[github-account] git scope:      $git_scope"
  echo "[github-account] git user.name:  $(git config --"$git_scope" user.name 2>/dev/null || echo '<unchanged>')"
  echo "[github-account] git user.email: $(git config --"$git_scope" user.email 2>/dev/null || echo '<unchanged>')"
}

main() {
  [[ $# -ge 1 ]] || {
    usage
    exit 1
  }

  case "$1" in
    list) cmd_list ;;
    status) cmd_status ;;
    use)
      shift
      [[ $# -ge 1 ]] || {
        echo "error: missing profile" >&2
        exit 1
      }
      cmd_use "$@"
      ;;
    -h|--help|help) usage ;;
    *)
      echo "error: unknown subcommand: $1" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
TMPL
      ;;
    'minimal:scripts/install-ai-tools.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
# Install AI CLI tools (claude, gemini) if API credentials are available.
set -euo pipefail

CLAUDE_PKG="@anthropic-ai/claude-code"
GEMINI_PKG="@google/gemini-cli"

install_if_missing() {
  local cmd="$1"
  local pkg="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "[install-ai-tools] $cmd already installed, skipping"
    return 0
  fi
  echo "[install-ai-tools] installing $pkg ..."
  npm install -g "$pkg"
  echo "[install-ai-tools] $cmd installed: $(command -v "$cmd")"
}

if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  install_if_missing claude "$CLAUDE_PKG"
else
  echo "[install-ai-tools] SKIP claude (CLAUDE_CODE_OAUTH_TOKEN not set)"
fi

if [[ -n "${GEMINI_API_KEY:-}" ]]; then
  install_if_missing gemini "$GEMINI_PKG"
else
  echo "[install-ai-tools] SKIP gemini (GEMINI_API_KEY not set)"
fi
TMPL
      ;;
    'minimal:scripts/on-attach.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[on-attach] minimal bootstrap active"
if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 && echo "[on-attach] gh auth OK" || echo "[on-attach] WARN: gh auth missing"
fi
echo "[on-attach] profile list: bash scripts/github-account-switch.sh list"
TMPL
      ;;
    'minimal:scripts/post-rebuild-check.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[check] minimal bootstrap checks"
command -v bash >/dev/null 2>&1 && echo "[check] bash OK"
command -v gh   >/dev/null 2>&1 && echo "[check] gh OK" || echo "[check] gh missing"
command -v rg   >/dev/null 2>&1 && echo "[check] rg OK" || echo "[check] rg missing"
__IF_RUNTIME_PHP_CHECK__command -v php  >/dev/null 2>&1 && echo "[check] php OK" || echo "[check] php missing"
TMPL
      ;;
    'standard:.devcontainer/devcontainer.json')
      cat <<'TMPL'
{
  "name": "__PROJECT_NAME__ (standard)",
  "image": "__BASE_IMAGE__",
  "features": {
    "ghcr.io/devcontainers/features/common-utils:1": {
      "configureZsh": true
    },
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {
      "version": "latest",
      "moby": false,
      "dockerDashComposeVersion": "latest",
      "installDockerComposeSwitch": true,
      "installDockerBuildx": true
    },
    "ghcr.io/devcontainers-extra/features/ripgrep:1": {},
    "ghcr.io/devcontainers/features/github-cli:1": {},
    "ghcr.io/devcontainers/features/aws-cli:1": {},
    "ghcr.io/devcontainers/features/terraform:1": {},
    "__IF_RUNTIME_NODE__": "ghcr.io/devcontainers/features/node:1",
    "__IF_RUNTIME_GO__": "ghcr.io/devcontainers/features/go:1",
    "__IF_RUNTIME_PYTHON__": "ghcr.io/devcontainers/features/python:1",
    "__IF_RUNTIME_PHP__": "ghcr.io/devcontainers/features/php:1"
  },
  "remoteEnv": {
__GITHUB_PROFILE_ENV_BLOCK__
    "GEMINI_API_KEY": "${localEnv:__GEMINI_KEY_ENV__}",
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:__CLAUDE_TOKEN_ENV__}",
    "LOCAL_WORKSPACE_FOLDER": "${localWorkspaceFolder}"
  },
  "postCreateCommand": "bash scripts/install-ai-tools.sh",
  "postAttachCommand": "bash scripts/on-attach.sh",
  "customizations": {
    "vscode": {
      "extensions": [
        "github.copilot",
        "github.copilot-chat",
        "ms-azuretools.vscode-containers",
        "amazonwebservices.aws-toolkit-vscode",
        "hashicorp.terraform"
      ]
    }
  }
}
TMPL
      ;;
    'standard:scripts/on-attach.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[on-attach] standard bootstrap active"
if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 && echo "[on-attach] gh auth OK" || echo "[on-attach] WARN: gh auth missing"
fi
echo "[on-attach] profile list: bash scripts/github-account-switch.sh list"
command -v go   >/dev/null 2>&1 && echo "[on-attach] go OK"   || true
command -v node >/dev/null 2>&1 && echo "[on-attach] node OK" || true
TMPL
      ;;
    'standard:scripts/install-ai-tools.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
# Install AI CLI tools (claude, gemini) if API credentials are available.
set -euo pipefail

CLAUDE_PKG="@anthropic-ai/claude-code"
GEMINI_PKG="@google/gemini-cli"

install_if_missing() {
  local cmd="$1"
  local pkg="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "[install-ai-tools] $cmd already installed, skipping"
    return 0
  fi
  echo "[install-ai-tools] installing $pkg ..."
  npm install -g "$pkg"
  echo "[install-ai-tools] $cmd installed: $(command -v "$cmd")"
}

if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  install_if_missing claude "$CLAUDE_PKG"
else
  echo "[install-ai-tools] SKIP claude (CLAUDE_CODE_OAUTH_TOKEN not set)"
fi

if [[ -n "${GEMINI_API_KEY:-}" ]]; then
  install_if_missing gemini "$GEMINI_PKG"
else
  echo "[install-ai-tools] SKIP gemini (GEMINI_API_KEY not set)"
fi
TMPL
      ;;
    'standard:scripts/post-rebuild-check.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[check] standard bootstrap checks"
for cmd in bash jq gh node go docker rg; do
  command -v "$cmd" >/dev/null 2>&1 && echo "[check] $cmd OK" || echo "[check] $cmd missing"
done
__IF_RUNTIME_PHP_CHECK__command -v php >/dev/null 2>&1 && echo "[check] php OK" || echo "[check] php missing"
TMPL
      ;;
    'full:.devcontainer/devcontainer.json')
      cat <<'TMPL'
{
  "name": "__PROJECT_NAME__ (full)",
  "image": "__BASE_IMAGE__",
  "features": {
    "ghcr.io/devcontainers/features/common-utils:1": {
      "configureZsh": true
    },
    "ghcr.io/devcontainers/features/docker-outside-of-docker:1": {
      "version": "latest",
      "moby": false,
      "dockerDashComposeVersion": "latest",
      "installDockerComposeSwitch": true,
      "installDockerBuildx": true
    },
    "ghcr.io/devcontainers-extra/features/ripgrep:1": {},
    "ghcr.io/devcontainers/features/github-cli:1": {},
    "__IF_RUNTIME_NODE__": "ghcr.io/devcontainers/features/node:1",
    "__IF_RUNTIME_GO__": "ghcr.io/devcontainers/features/go:1",
    "__IF_RUNTIME_PYTHON__": "ghcr.io/devcontainers/features/python:1",
    "__IF_RUNTIME_PHP__": "ghcr.io/devcontainers/features/php:1",
    "ghcr.io/devcontainers/features/aws-cli:1": {},
    "ghcr.io/devcontainers/features/terraform:1": {},
    "ghcr.io/dhoeric/features/google-cloud-cli:1": {
      "version": "latest"
    }
  },
  "remoteEnv": {
__GITHUB_PROFILE_ENV_BLOCK__
    "GEMINI_API_KEY": "${localEnv:__GEMINI_KEY_ENV__}",
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:__CLAUDE_TOKEN_ENV__}",
    "LOCAL_WORKSPACE_FOLDER": "${localWorkspaceFolder}"
  },
  "mounts": [
    "source=claude-storage,target=/home/node/.claude,type=volume",
    "source=gemini-storage,target=/home/node/.gemini,type=volume"
  ],
  "postCreateCommand": "bash scripts/install-ai-tools.sh && bash scripts/post-rebuild-check.sh",
  "postAttachCommand": "bash scripts/on-attach.sh",
  "customizations": {
    "vscode": {
      "extensions": [
        "github.copilot",
        "github.copilot-chat",
        "ms-azuretools.vscode-containers",
        "amazonwebservices.aws-toolkit-vscode",
        "hashicorp.terraform",
        "GoogleCloudTools.cloudcode"
      ]
    }
  }
}
TMPL
      ;;
    'full:scripts/on-attach.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[on-attach] full bootstrap active"
for cmd in gh claude gemini go node docker; do
  command -v "$cmd" >/dev/null 2>&1 && echo "[on-attach] $cmd OK" || echo "[on-attach] WARN: $cmd missing"
done
echo "[on-attach] profile list: bash scripts/github-account-switch.sh list"
TMPL
      ;;
    'full:scripts/install-ai-tools.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
# Install AI CLI tools (claude, gemini) if API credentials are available.
set -euo pipefail

CLAUDE_PKG="@anthropic-ai/claude-code"
GEMINI_PKG="@google/gemini-cli"

install_if_missing() {
  local cmd="$1"
  local pkg="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "[install-ai-tools] $cmd already installed, skipping"
    return 0
  fi
  echo "[install-ai-tools] installing $pkg ..."
  npm install -g "$pkg"
  echo "[install-ai-tools] $cmd installed: $(command -v "$cmd")"
}

if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  install_if_missing claude "$CLAUDE_PKG"
else
  echo "[install-ai-tools] SKIP claude (CLAUDE_CODE_OAUTH_TOKEN not set)"
fi

if [[ -n "${GEMINI_API_KEY:-}" ]]; then
  install_if_missing gemini "$GEMINI_PKG"
else
  echo "[install-ai-tools] SKIP gemini (GEMINI_API_KEY not set)"
fi
TMPL
      ;;
    'full:scripts/post-rebuild-check.sh')
      cat <<'TMPL'
#!/usr/bin/env bash
set -euo pipefail
echo "[check] full bootstrap checks"
for cmd in bash jq gh node go docker rg claude gemini; do
  command -v "$cmd" >/dev/null 2>&1 && echo "[check] $cmd OK" || echo "[check] $cmd missing"
done
__IF_RUNTIME_PHP_CHECK__command -v php >/dev/null 2>&1 && echo "[check] php OK" || echo "[check] php missing"
TMPL
      ;;
    *)
      echo "error: unknown template key: $mode:$rel" >&2
      exit 1
      ;;
  esac
}

# ── Rendering ─────────────────────────────────────────────────────────────────

has_language() {
  local target="$1" l
  for l in "${LANGUAGES[@]}"; do [[ "$l" == "$target" ]] && return 0; done
  return 1
}

build_default_gitignore_targets() {
  local targets=()
  targets+=("macOS")
  if has_language "node"; then
    targets+=("Node")
  fi
  if has_language "go"; then
    targets+=("Go")
  fi
  if has_language "python"; then
    targets+=("Python")
  fi
  if has_language "php"; then
    targets+=("PHP")
  fi
  printf '%s\n' "${targets[@]}" | awk '!seen[$0]++'
}

build_effective_gitignore_targets() {
  local extra_csv="$GITIGNORE_TARGETS"
  local item
  local extra_targets

  build_default_gitignore_targets

  if [[ -n "$extra_csv" ]]; then
    extra_targets="$(printf '%s' "$extra_csv" | tr ',' ' ')"
    for item in $extra_targets; do
      item="$(echo "$item" | xargs)"
      [[ -n "$item" ]] && printf '%s\n' "$item"
    done
  fi
}

fetch_gitignore_template() {
  local name="$1"
  local url

  url="$GITIGNORE_REPO_RAW_BASE/${name}.gitignore"
  if curl -fsL "$url" 2>/dev/null; then
    return 0
  fi

  url="$GITIGNORE_REPO_RAW_BASE/Global/${name}.gitignore"
  curl -fsL "$url" 2>/dev/null
}

build_remote_gitignore_block() {
  local resolved_targets
  local target
  local tmp

  resolved_targets="$(build_effective_gitignore_targets | awk '!seen[$0]++' | paste -sd' ' -)"

  if [[ -z "$resolved_targets" ]]; then
    return 0
  fi

  {
    printf '%s\n' ""
    printf '%s\n' "# github/gitignore generated ignores"
    printf '%s\n' "# templates: $resolved_targets"

    for target in $resolved_targets; do
      printf '%s\n' ""
      printf '%s\n' "# template: $target"
      tmp="$(mktemp)"
      if fetch_gitignore_template "$target" > "$tmp"; then
        cat "$tmp"
      else
        echo "[bootstrap] WARN: gitignore template not found: $target" >&2
      fi
      rm -f "$tmp"
    done
  } | sed '/^$/N;/^\n$/D'
}

build_github_profile_env_block() {
  local csv="$GITHUB_PROFILES"
  local item profile upper out=""
  local line

  IFS=',' read -ra items <<< "$csv"
  for item in "${items[@]}"; do
    profile="$(echo "$item" | xargs)"
    [[ -n "$profile" ]] || continue
    if [[ ! "$profile" =~ ^[a-zA-Z0-9_]+$ ]]; then
      echo "error: invalid github profile name: $profile" >&2
      exit 1
    fi
    upper="$(printf '%s' "$profile" | tr '[:lower:]' '[:upper:]')"
    # shellcheck disable=SC2016
    printf -v line '    "GITHUB_TOKEN_%s": "${localEnv:GITHUB_TOKEN_%s}",\n' "$upper" "$upper"
    out+="$line"
    # shellcheck disable=SC2016
    printf -v line '    "GITHUB_OWNER_%s": "${localEnv:GITHUB_OWNER_%s}",\n' "$upper" "$upper"
    out+="$line"
    # shellcheck disable=SC2016
    printf -v line '    "GIT_AUTHOR_NAME_%s": "${localEnv:GIT_AUTHOR_NAME_%s}",\n' "$upper" "$upper"
    out+="$line"
    # shellcheck disable=SC2016
    printf -v line '    "GIT_AUTHOR_EMAIL_%s": "${localEnv:GIT_AUTHOR_EMAIL_%s}",\n' "$upper" "$upper"
    out+="$line"
  done

  printf '%b' "$out"
}

render_content() {
  local content="$1"
  local sed_args=()
  local escaped_base_image
  local github_env_block

  github_env_block="$(build_github_profile_env_block)"
  content="${content//__GITHUB_PROFILE_ENV_BLOCK__/$github_env_block}"

  escaped_base_image="$BASE_IMAGE"
  escaped_base_image="${escaped_base_image//&/\\&}"

  sed_args+=(-e "s|__PROJECT_NAME__|$PROJECT_NAME|g")
  sed_args+=(-e "s|__CLAUDE_TOKEN_ENV__|$CLAUDE_TOKEN_ENV|g")
  sed_args+=(-e "s|__GEMINI_KEY_ENV__|$GEMINI_KEY_ENV|g")
  sed_args+=(-e "s|__BASE_IMAGE__|$escaped_base_image|g")
  for lang in node go python php; do
    local lang_upper
    lang_upper=$(printf '%s' "$lang" | tr '[:lower:]' '[:upper:]')
    if has_language "$lang"; then
      sed_args+=(-e "s|\"__IF_RUNTIME_${lang_upper}__\": \"ghcr.io/devcontainers/features/$lang:1\"|\"ghcr.io/devcontainers/features/$lang:1\": {}|g")
    else
      sed_args+=(-e "/\"__IF_RUNTIME_${lang_upper}__\"/d")
    fi
  done
  if has_language "php"; then
    sed_args+=(-e "s|__IF_RUNTIME_PHP_CHECK__||g")
  else
    sed_args+=(-e "/__IF_RUNTIME_PHP_CHECK__/d")
  fi
  printf '%s' "$content" | sed "${sed_args[@]}"
}

build_gitignore_block() {
  local remote_block=""

  remote_block="$(build_remote_gitignore_block)"
  if [[ -n "$remote_block" ]]; then
    printf '%s\n' "$remote_block"
  fi
}

upsert_gitignore() {
  local gitignore_path="$OUTPUT_DIR/.gitignore"
  local tmp block prev_mode=""

  block="$(build_gitignore_block)"
  tmp="$(mktemp)"

  [[ -f "$gitignore_path" ]] && prev_mode="$(file_mode_octal "$gitignore_path")"

  if [[ -f "$gitignore_path" ]]; then
    awk -v start="$GITIGNORE_BEGIN" -v end="$GITIGNORE_END" '
      $0 == start {skip=1; next}
      $0 == end {skip=0; next}
      !skip {print}
    ' "$gitignore_path" > "$tmp"
    if [[ -s "$tmp" ]]; then
      printf '\n' >> "$tmp"
    fi
  fi

  {
    printf '%s\n' "$GITIGNORE_BEGIN"
    printf '%s\n' "$block"
    printf '%s\n' "$GITIGNORE_END"
  } >> "$tmp"

  # mktemp creates 0600 and mv preserves it, which would clobber the mode of an existing
  # .gitignore. Restore what was there; use 644 only for a file we created.
  mv "$tmp" "$gitignore_path"
  chmod "${prev_mode:-644}" "$gitignore_path"
  echo "write: $gitignore_path (managed section)"
}

# ── Shared AI rules (dotfiles) distribution ───────────────────────────────────
# This script distributes the rules; the separate dotfiles repository owns them.

# Octal permission bits of a file, or empty when they cannot be determined.
# GNU coreutils uses -c; BSD/macOS uses -f. GNU also accepts -f, but as
# --file-system, which prints unrelated text — so each result is validated to be
# octal digits before it is accepted.
file_mode_octal() {
  local mode
  for mode in \
    "$(stat -c %a "$1" 2>/dev/null || true)" \
    "$(stat -f %Lp "$1" 2>/dev/null || true)"; do
    case "$mode" in
      '' | *[!0-7]* ) ;;
      * ) printf '%s' "$mode"; return 0 ;;
    esac
  done
  printf ''
}

should_install_dotfiles() {
  [[ "$WITH_DOTFILES" == "true" ]]
}

# Resolve the directory that contains ai/common, from a path, URL, or sibling checkout.
detect_dotfiles_common_dir() {
  local source_hint="$1"
  local tmp_root archive_file found candidate

  if [[ -n "$source_hint" ]]; then
    if [[ "$source_hint" =~ ^https?:// ]]; then
      require_cmd curl
      require_cmd tar
      tmp_root="$(mktemp -d)"
      # The resolved path lives inside tmp_root, so it can only be removed on exit.
      DOTFILES_TMP_ROOT="$tmp_root"
      trap 'rm -rf "$DOTFILES_TMP_ROOT"' EXIT
      archive_file="$tmp_root/dotfiles.tar.gz"
      curl -fsSL "$source_hint" -o "$archive_file"
      tar -xzf "$archive_file" -C "$tmp_root"
      found="$(find "$tmp_root" -type d -path '*/ai/common' | head -n 1 || true)"
      [[ -n "$found" ]] || {
        echo "error: ai/common not found in dotfiles archive: $source_hint" >&2
        exit 1
      }
      printf '%s' "$found"
      return
    fi

    if [[ -d "$source_hint" ]]; then
      found="$(find "$source_hint" -type d -path '*/ai/common' | head -n 1 || true)"
      [[ -n "$found" ]] || {
        echo "error: ai/common not found under directory: $source_hint" >&2
        exit 1
      }
      printf '%s' "$found"
      return
    fi

    echo "error: --dotfiles-from not found: $source_hint" >&2
    exit 1
  fi

  for candidate in \
    "$SCRIPT_DIR/../../dotfiles/ai/common" \
    "$SCRIPT_DIR/../../../dotfiles/ai/common"; do
    if [[ -d "$candidate" ]]; then
      printf '%s' "$candidate"
      return
    fi
  done

  printf ''
}

apply_file_with_policy() {
  local src="$1" dest="$2" answer prev_mode

  mkdir -p "$(dirname "$dest")"

  if [[ ! -f "$dest" ]]; then
    cp "$src" "$dest"
    # Sources come from mktemp (0600); a file we create should be readable like the rest.
    chmod 644 "$dest"
    echo "write: $dest"
    return 0
  fi

  # Overwriting an existing file must not change its mode.
  prev_mode="$(file_mode_octal "$dest")"
  prev_mode="${prev_mode:-644}"

  case "$DOTFILES_CONFLICT_POLICY" in
    skip)
      echo "skip (exists): $dest"
      ;;
    overwrite)
      cp "$src" "$dest"
      chmod "$prev_mode" "$dest"
      echo "write: $dest (overwrite)"
      ;;
    prompt)
      read -r -p "File exists: $dest. Overwrite? [y/N]: " answer
      if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
        cp "$src" "$dest"
        chmod "$prev_mode" "$dest"
        echo "write: $dest (overwrite)"
      else
        echo "skip (declined): $dest"
      fi
      ;;
  esac
}

dotfiles_entry_content() {
  local runtime_label="$1"
  cat <<EOF
# ${runtime_label} 実行環境向け入口ファイル

次の順序でルールを適用します（下位から上位へ優先）。

1. \`${DOTFILES_REL_ROOT}/shared-ai-rules.md\`（全体共通ルール）
2. \`.github/project-ai-rules.md\`（プロジェクト共通ルール）
3. このファイル（実行環境固有の最小差分）

- このファイルは最小構成に保ち、実行環境固有の差分のみを扱います。
- このファイルでロール責務を再定義しません。ロール責務は \`${DOTFILES_REL_ROOT}/role-contracts/\` を参照します。
EOF
}

dotfiles_project_rules_content() {
  cat <<EOF
# プロジェクト共通 AI ルール

- このファイルはプロジェクト共通ルールの正本です。
- 全体共通ルールは \`${DOTFILES_REL_ROOT}/shared-ai-rules.md\` を参照します。
- ロール責務は \`${DOTFILES_REL_ROOT}/role-contracts/\` を参照します。
- タスク手順は \`${DOTFILES_REL_ROOT}/task-playbooks/\` を参照します。
- レビュー運用は \`${DOTFILES_REL_ROOT}/review-workflow.md\` を参照します。
- 実行環境入口ファイル（\`CLAUDE.md\` 等）はこのファイルを参照し、最小差分のみを記述します。

## このプロジェクト固有の値

（ここにプロジェクト固有の制約・検証手順を記述します）

## 機密の具体化

共通規範「機密の取り扱い」を、このプロジェクトで具体化します。

- 機密の読み取り元: （例: \`.env\` / シークレット管理サービス）
- 追跡除外の対象: （例: \`.env\`）
- 共有する雛形: （例: 値のない \`.env.example\`）

## 生成物の具体化

- コミットしない生成物: （例: ビルド成果物、メディアファイル）
- 再生成手順: （コマンドを記載）

## 作業状況の記録先

共通規範「作業状況の記録」を、このプロジェクトで具体化します。
単一ファイルへの集中更新は並列実行と衝突するため、追記のみの形式や作業単位ごとの分割を検討します。

- 未完了の作業: （記録先を記載）
- 完了した作業の履歴: （記録先を記載）
EOF
}

# Resolve once, before any file is written, so a bad source fails without side effects.
resolve_dotfiles_source_or_die() {
  DOTFILES_COMMON_DIR="$(detect_dotfiles_common_dir "$DOTFILES_FROM")"
  if [[ -z "$DOTFILES_COMMON_DIR" ]]; then
    echo "error: dotfiles source not found. specify --dotfiles-from <path|url>." >&2
    exit 1
  fi
}

# Second-opinion reviewer for the cross-model gate. The norm lives in the rules
# package (review-workflow.md); this is the executable side of it.
dotfiles_gemini_review_content() {
  cat <<'TMPL'
#!/usr/bin/env bash
# gemini-review.sh — 別ベンダーのモデルによる第二意見（クロスモデル二段ゲートの ②段目）
#
# 規範: dotfiles/ai/common/review-workflow.md
# 目的: 実装したモデル自身の自己レビューは盲点を共有するため、別ベンダーのモデルで
#       独立にクロスチェックする。push 前のローカル事前ゲートで使う。
#
# 使い方:
#   bash scripts/gemini-review.sh              # ステージ済み差分をレビュー
#   bash scripts/gemini-review.sh --range main..HEAD
#
# 終了コード:
#   0 = LGTM（重大な指摘なし。push 可）
#   1 = 重大な指摘あり、または実行不能
set -euo pipefail

RANGE=""
MODEL="${GEMINI_REVIEW_MODEL:-}"

usage() {
  cat <<'EOF'
usage: bash scripts/gemini-review.sh [options]

options:
  --range <git-range>   レビュー対象の差分範囲（既定: ステージ済み差分）
  --model <name>        使用モデル（既定: gemini CLI の既定。GEMINI_REVIEW_MODEL でも指定可）
  -h, --help            ヘルプ
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --range) RANGE="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

command -v gemini >/dev/null 2>&1 || {
  echo "error: gemini CLI not found. run scripts/install-ai-tools.sh" >&2
  exit 1
}
[[ -n "${GEMINI_API_KEY:-}" ]] || {
  echo "error: GEMINI_API_KEY is not set" >&2
  exit 1
}

if [[ -n "$RANGE" ]]; then
  diff_text="$(git diff "$RANGE")"
  scope="$RANGE"
else
  diff_text="$(git diff --cached)"
  scope="staged"
fi

if [[ -z "${diff_text//[[:space:]]/}" ]]; then
  echo "[gemini-review] no diff to review ($scope)"
  exit 0
fi

# ゲート対象は review-workflow.md の限定に合わせる。
read -r -d '' PROMPT <<'EOF' || true

上記は git の差分です。コードレビューを行ってください。

指摘対象は次の 4 点に限定します。それ以外は報告しないでください。
- 致命バグ
- 脆弱性
- 型エラー
- エッジケースの見落とし

報告しないもの:
- 好みのリファクタリング
- 命名や可読性の軽微な提案
- 差分の範囲外にある既存コードの問題

出力形式:
- 上記 4 点に該当する指摘が 1 件もなければ、`LGTM` とだけ出力してください。
- 指摘がある場合は、各指摘について「該当ファイルと行」「何が問題か」「なぜ問題か（再現条件や影響）」を簡潔に記述してください。
EOF

echo "[gemini-review] reviewing $scope"
# 差分を stdin で渡すだけで、モデルにツール実行は不要。信頼済みフォルダの確認は
# 対話を要求するため、非対話実行では明示的に読み取り専用として扱う。
args=(--skip-trust -p "$PROMPT")
[[ -n "$MODEL" ]] && args=(-m "$MODEL" "${args[@]}")

output="$(printf '%s' "$diff_text" | gemini "${args[@]}" 2>&1)" || {
  echo "error: gemini review failed" >&2
  printf '%s\n' "$output" >&2
  exit 1
}

printf '%s\n' "$output"

# 通過判定はモデルの出力ゆれに耐える必要がある。LGTM とだけ返すよう指示していても、
# **LGTM** / `LGTM` / LGTM. のように装飾されることがある。装飾・空白・句点を除いてから
# 行単位で厳密一致させる（文中の LGTM は通過させない）。
if printf '%s\n' "$output" \
  | sed 's/[`*_#]//g; s/[[:space:]]//g; s/[.。]$//' \
  | grep -qix 'LGTM'; then
  echo "[gemini-review] LGTM"
  exit 0
fi

echo "[gemini-review] findings reported. fix them in a single iteration before push." >&2
exit 1
TMPL
}

install_dotfiles_rules() {
  local common_dir="$DOTFILES_COMMON_DIR" rel dest tmp count=0

  echo "[bootstrap] shared AI rules from: $common_dir"

  while IFS= read -r src; do
    [[ -n "$src" ]] || continue
    rel="${src#"$common_dir"/}"
    dest="$OUTPUT_DIR/$DOTFILES_REL_ROOT/$rel"
    apply_file_with_policy "$src" "$dest"
    count=$((count + 1))
  done < <(find "$common_dir" -type f -name '*.md' | sort)

  echo "[bootstrap] shared AI rules: $count file(s)"

  tmp="$(mktemp)"
  dotfiles_project_rules_content > "$tmp"
  apply_file_with_policy "$tmp" "$OUTPUT_DIR/.github/project-ai-rules.md"
  rm -f "$tmp"

  tmp="$(mktemp)"
  dotfiles_entry_content "Claude" > "$tmp"
  apply_file_with_policy "$tmp" "$OUTPUT_DIR/CLAUDE.md"
  rm -f "$tmp"

  tmp="$(mktemp)"
  dotfiles_entry_content "Copilot" > "$tmp"
  apply_file_with_policy "$tmp" "$OUTPUT_DIR/.github/copilot-instructions.md"
  rm -f "$tmp"

  tmp="$(mktemp)"
  dotfiles_gemini_review_content > "$tmp"
  apply_file_with_policy "$tmp" "$OUTPUT_DIR/scripts/gemini-review.sh"
  rm -f "$tmp"
  if [[ -f "$OUTPUT_DIR/scripts/gemini-review.sh" ]]; then
    chmod +x "$OUTPUT_DIR/scripts/gemini-review.sh"
  fi
}

write_file() {
  local rel="$1" content="$2" out tmp
  out="$OUTPUT_DIR/$rel"
  if [[ -e "$out" && "$FORCE" != "true" ]]; then
    echo "skip (exists): $out"
    return 0
  fi
  mkdir -p "$(dirname "$out")"
  tmp="$(mktemp)"
  render_content "$content" > "$tmp"
  if [[ "$out" == *.json ]]; then
    perl -0777 -i -pe 's/,\s*([}\]])/$1/g' "$tmp"
    jq . "$tmp" > "$out"
    rm -f "$tmp"
  else
    mv "$tmp" "$out"
  fi
  # mktemp creates 0600 and mv preserves it; normalize so generated files are readable.
  chmod 644 "$out"
  [[ "$out" == *.sh ]] && chmod +x "$out"
  echo "write: $out"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo "[bootstrap] mode=$MODE languages=${LANGUAGES[*]}"
echo "[bootstrap] output=$OUTPUT_DIR"

# Fail before writing anything if the rules source was requested but is unusable.
if should_install_dotfiles; then
  resolve_dotfiles_source_or_die
fi

# Collect and sort relative paths for the selected mode (bash 3 compatible)
sorted_rels="$(mode_rel_paths "$MODE" | sort)"

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[bootstrap] dry-run: no files will be written"
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    echo "plan: $OUTPUT_DIR/$rel"
  done <<EOF
$sorted_rels
EOF

  if [[ "$MANAGE_GITIGNORE" == "true" ]]; then
    echo "plan: $OUTPUT_DIR/.gitignore (managed section update)"
    if [[ -n "$GITIGNORE_TARGETS" ]]; then
      echo "plan: github/gitignore templates = implicit + $GITIGNORE_TARGETS"
    else
      echo "plan: github/gitignore templates = implicit (macOS + language-based)"
    fi
  fi

  if should_install_dotfiles; then
    echo "plan: shared AI rules from $DOTFILES_COMMON_DIR"
    while IFS= read -r src; do
      [[ -n "$src" ]] || continue
      echo "plan: $OUTPUT_DIR/$DOTFILES_REL_ROOT/${src#"$DOTFILES_COMMON_DIR"/}"
    done < <(find "$DOTFILES_COMMON_DIR" -type f -name '*.md' | sort)
    echo "plan: $OUTPUT_DIR/.github/project-ai-rules.md"
    echo "plan: $OUTPUT_DIR/CLAUDE.md"
    echo "plan: $OUTPUT_DIR/.github/copilot-instructions.md"
    echo "plan: $OUTPUT_DIR/scripts/gemini-review.sh"
  fi
  exit 0
fi

while IFS= read -r rel; do
  [[ -n "$rel" ]] || continue
  write_file "$rel" "$(get_template_content "$MODE" "$rel")"
done <<EOF
$sorted_rels
EOF

if [[ "$MANAGE_GITIGNORE" == "true" ]]; then
  upsert_gitignore
fi

if should_install_dotfiles; then
  install_dotfiles_rules
fi

echo "[bootstrap] completed"
