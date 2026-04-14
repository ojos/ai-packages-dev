#!/usr/bin/env bash
set -euo pipefail

require_bash_version() {
  local major="${BASH_VERSINFO[0]:-0}"
  local minor="${BASH_VERSINFO[1]:-0}"
  if (( major < 3 || (major == 3 && minor < 2) )); then
    echo "error: bash 3.2+ is required (current: ${BASH_VERSION:-unknown})" >&2
    exit 1
  fi
}

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
SCHEMA_FILE="$PACKAGE_ROOT/config.schema.json"
DEFAULT_BOOTSTRAP_FROM="https://github.com/ojos/agent-swarm-framework/archive/refs/heads/main.tar.gz"
DEFAULT_TARGET_DIR="$PWD"
NON_INTERACTIVE="false"
CONFIG_FILE=""
TARGET_DIR="$DEFAULT_TARGET_DIR"
PREVIEW_DIR=""
SKIP_GITHUB="false"
BOOTSTRAP_FROM=""
RETROFIT_SAFE="false"
ORIGINAL_ARGS=("$@")

usage() {
  cat <<'EOF'
usage: bash packages/agent-swarm-framework/install.sh [options]

options:
  --target-dir <path>        Apply to target repository directory (default: current directory)
  --preview-dir <path>       Preview output directory (default: packages/agent-swarm-framework/.preview/<projectSlug>)
  --config <json-file>       Use a JSON config file
  --bootstrap-from <url>     Package archive URL for standalone mode (default: main branch archive)
  --retrofit-safe            Apply safe preset for existing project retrofit
  --non-interactive          Do not ask questions; requires --config
  --skip-github              Skip milestone/issue creation step
  -h, --help                 Show help
EOF
}

package_layout_ready() {
  [[ -f "$PACKAGE_ROOT/config.schema.json" ]] &&
  [[ -d "$PACKAGE_ROOT/runtime-core" ]] &&
  [[ -d "$PACKAGE_ROOT/agent-skills" ]] &&
  [[ -d "$PACKAGE_ROOT/executors" ]] &&
  [[ -d "$PACKAGE_ROOT/template-project" ]]
}

bootstrap_standalone_mode() {
  local archive_url="${BOOTSTRAP_FROM:-${AGENT_SWARM_FRAMEWORK_ARCHIVE_URL:-$DEFAULT_BOOTSTRAP_FROM}}"
  local tmp_root archive_file extracted_root candidate_install candidate_root

  if [[ "${AGENT_SWARM_FRAMEWORK_BOOTSTRAPPED:-}" == "1" ]]; then
    echo "error: standalone bootstrap failed to locate package layout after extraction" >&2
    exit 1
  fi

  command -v curl >/dev/null 2>&1 || { echo "error: required command not found: curl" >&2; exit 1; }
  command -v tar >/dev/null 2>&1 || { echo "error: required command not found: tar" >&2; exit 1; }

  tmp_root="$(mktemp -d)"
  archive_file="$tmp_root/package.tar.gz"

  echo "[bootstrap] package layout not found next to install.sh"
  echo "[bootstrap] downloading package archive: $archive_url"
  curl -fsSL "$archive_url" -o "$archive_file"
  tar -xzf "$archive_file" -C "$tmp_root"

  candidate_install="$(find "$tmp_root" -type f -path '*/packages/agent-swarm-framework/install.sh' | head -n 1 || true)"
  if [[ -z "$candidate_install" ]]; then
    candidate_install="$(find "$tmp_root" -type f -path '*/agent-swarm-framework/install.sh' | head -n 1 || true)"
  fi
  [[ -n "$candidate_install" ]] || { echo "error: install.sh not found in downloaded archive" >&2; exit 1; }

  candidate_root="$(cd "$(dirname "$candidate_install")" && pwd)"
  extracted_root="$candidate_root"

  if [[ ! -f "$extracted_root/config.schema.json" ]] || [[ ! -d "$extracted_root/runtime-core" ]]; then
    echo "error: downloaded archive does not contain a valid agent-swarm-framework package" >&2
    exit 1
  fi

  echo "[bootstrap] re-executing installer from extracted package"
  AGENT_SWARM_FRAMEWORK_BOOTSTRAPPED=1 exec bash "$extracted_root/install.sh" "${ORIGINAL_ARGS[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir)
      TARGET_DIR="$2"
      shift 2
      ;;
    --preview-dir)
      PREVIEW_DIR="$2"
      shift 2
      ;;
    --config)
      CONFIG_FILE="$2"
      shift 2
      ;;
    --bootstrap-from)
      BOOTSTRAP_FROM="$2"
      shift 2
      ;;
    --retrofit-safe)
      RETROFIT_SAFE="true"
      shift
      ;;
    --non-interactive)
      NON_INTERACTIVE="true"
      shift
      ;;
    --skip-github)
      SKIP_GITHUB="true"
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

require_bash_version

if ! package_layout_ready; then
  bootstrap_standalone_mode
fi

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "error: required command not found: $cmd" >&2
    exit 1
  }
}

require_cmd jq

ask_text() {
  local prompt="$1"
  local default="$2"
  local answer
  read -r -p "$prompt [$default]: " answer
  printf '%s' "${answer:-$default}"
}

ask_choice() {
  local prompt="$1"
  local default="$2"
  shift 2
  local options=("$@")
  local answer

  while true; do
    echo "$prompt"
    printf '  options: %s\n' "$(IFS=', '; echo "${options[*]}")"
    read -r -p "  > [${default}]: " answer
    answer="${answer:-$default}"
    for option in "${options[@]}"; do
      if [[ "$answer" == "$option" ]]; then
        printf '%s' "$answer"
        return
      fi
    done
    echo "  invalid value: $answer"
  done
}

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g'
}

confirm() {
  local prompt="$1"
  local default="${2:-y}"
  local answer
  local suffix="[Y/n]"
  if [[ "$default" == "n" ]]; then
    suffix="[y/N]"
  fi

  read -r -p "$prompt $suffix: " answer
  answer="${answer:-$default}"
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

default_apply_for_category() {
  local category="$1"
  if [[ "$RETROFIT_SAFE" == "true" ]]; then
    if [[ "$category" == "runtime-core" || "$category" == "agent-skills" ]]; then
      printf 'y'
      return
    fi
    printf 'n'
    return
  fi
  printf 'y'
}

should_apply_category() {
  local category="$1"
  local default_answer
  default_answer="$(default_apply_for_category "$category")"

  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    [[ "$default_answer" == "y" ]]
    return
  fi

  confirm "Apply category '${category}' to target repository?" "$default_answer"
}

collect_interactive_config() {
  local display_name project_slug execution_mode remote_provider automation_stage merge_policy line_strategy orchestrator_mode state_backend

  echo "=== Agent Swarm Framework Installer ==="
  echo "目的: package の初期構成をプレビューし、カテゴリ単位で target repo に適用します。"
  echo

  display_name="$(ask_text "Display name" "My Multi-Agent Project")"
  project_slug="$(ask_text "Project slug" "$(slugify "$display_name")")"
  execution_mode="$(ask_choice "Execution mode" "hybrid" "local" "remote" "hybrid")"

  if [[ "$execution_mode" == "local" ]]; then
    remote_provider="none"
  else
    remote_provider="$(ask_choice "Remote provider" "github-actions" "github-actions")"
  fi

  automation_stage="$(ask_choice "Automation stage" "implement" "plan" "implement" "review" "merge")"
  merge_policy="$(ask_choice "Merge policy" "manual" "manual" "conditional" "auto")"
  line_strategy="$(ask_choice "Line strategy" "fixed2" "fixed2" "dynamic")"
  orchestrator_mode="$(ask_choice "Orchestrator mode" "remote" "local" "remote" "hybrid")"
  state_backend="$(ask_choice "State backend" "hybrid" "github" "file" "hybrid")"

  jq -n \
    --arg version "1.0" \
    --arg displayName "$display_name" \
    --arg projectSlug "$project_slug" \
    --arg executionMode "$execution_mode" \
    --arg remoteProvider "$remote_provider" \
    --arg automationStage "$automation_stage" \
    --arg mergePolicy "$merge_policy" \
    --arg lineStrategy "$line_strategy" \
    --arg orchestratorMode "$orchestrator_mode" \
    --arg stateBackend "$state_backend" \
    '{
      version: $version,
      displayName: $displayName,
      projectSlug: $projectSlug,
      executionMode: $executionMode,
      remoteProvider: $remoteProvider,
      automationStage: $automationStage,
      mergePolicy: $mergePolicy,
      lineStrategy: $lineStrategy,
      orchestratorMode: $orchestratorMode,
      stateBackend: $stateBackend
    }'
}

load_config() {
  if [[ "$NON_INTERACTIVE" == "true" ]]; then
    [[ -n "$CONFIG_FILE" ]] || { echo "error: --non-interactive requires --config" >&2; exit 1; }
    [[ -f "$CONFIG_FILE" ]] || { echo "error: config file not found: $CONFIG_FILE" >&2; exit 1; }
    cat "$CONFIG_FILE"
    return
  fi

  if [[ -n "$CONFIG_FILE" ]]; then
    [[ -f "$CONFIG_FILE" ]] || { echo "error: config file not found: $CONFIG_FILE" >&2; exit 1; }
    cat "$CONFIG_FILE"
    return
  fi

  collect_interactive_config
}

normalize_config() {
  local config_json="$1"
  printf '%s' "$config_json" | jq '
    .agentEngines = (.agentEngines // {}) |
    .agentEngines.roles = (
      {
        orchestrator: "copilot",
        planner: "copilot",
        implementer: "claude",
        reviewer: "gemini",
        closer: "copilot"
      } + (.agentEngines.roles // {})
    ) |
    .taskEngineOverrides = (.taskEngineOverrides // {})
  '
}

apply_retrofit_safe_preset() {
  local config_json="$1"
  printf '%s' "$config_json" | jq '
    .executionMode = "local" |
    .remoteProvider = "none" |
    .automationStage = "plan" |
    .mergePolicy = "manual" |
    .orchestratorMode = "local"
  '
}

validate_config() {
  local config_json="$1"
  printf '%s' "$config_json" | jq -e '
    .version == "1.0" and
    (.displayName | type == "string") and
    (.projectSlug | test("^[a-z0-9]+([a-z0-9-]*[a-z0-9])?$") ) and
    (.executionMode | IN("local", "remote", "hybrid")) and
    (.remoteProvider | IN("none", "github-actions", "aws", "both")) and
    (.automationStage | IN("plan", "implement", "review", "merge")) and
    (.mergePolicy | IN("manual", "conditional", "auto")) and
    (.lineStrategy | IN("fixed2", "dynamic")) and
    (.orchestratorMode | IN("local", "remote", "hybrid")) and
    (.stateBackend | IN("github", "file", "hybrid")) and
    ((.agentEngines // {} ) | type == "object") and
    ((.agentEngines.roles // {} ) | type == "object") and
    ((.agentEngines.roles.orchestrator // "copilot") | IN("copilot", "claude", "gemini", "codex")) and
    ((.agentEngines.roles.planner // "copilot") | IN("copilot", "claude", "gemini", "codex")) and
    ((.agentEngines.roles.implementer // "claude") | IN("claude", "gemini", "codex")) and
    ((.agentEngines.roles.reviewer // "gemini") | IN("claude", "gemini", "codex")) and
    ((.agentEngines.roles.closer // "copilot") | IN("copilot", "claude", "gemini", "codex")) and
    ((.taskEngineOverrides // {} ) | type == "object") and
    (([.taskEngineOverrides[]? | .orchestrator?, .planner?, .closer?] | map(select(. != null) | IN("copilot", "claude", "gemini", "codex")) | all) // true) and
    (([.taskEngineOverrides[]? | .implementer?, .reviewer?] | map(select(. != null) | IN("claude", "gemini", "codex")) | all) // true)
  ' >/dev/null

  if [[ -f "$SCHEMA_FILE" ]]; then
    jq -e . "$SCHEMA_FILE" >/dev/null
  fi
}

write_engine_routing_file() {
  local stage_root="$1"
  local config_json="$2"
  mkdir -p "$stage_root/.multi-agent"
  printf '%s\n' "$config_json" | jq '{
    version: .version,
    roleEngines: (.agentEngines.roles // {}),
    taskEngineOverrides: (.taskEngineOverrides // {})
  }' > "$stage_root/.multi-agent/engine-routing.json"
}

copy_category_preview() {
  local category="$1"
  local preview_root="$2"
  mkdir -p "$preview_root"
  case "$category" in
    runtime-core)
      cp -R "$PACKAGE_ROOT/runtime-core/files/." "$preview_root/"
      ;;
    agent-skills)
      cp -R "$PACKAGE_ROOT/agent-skills/files/." "$preview_root/"
      ;;
    executors)
      cp -R "$PACKAGE_ROOT/executors/github-actions/files/." "$preview_root/"
      ;;
    template-project)
      cp -R "$PACKAGE_ROOT/template-project/files/." "$preview_root/"
      ;;
  esac
}

build_preview() {
  local config_json="$1"
  local preview_root="$2"
  rm -rf "$preview_root"
  mkdir -p "$preview_root"

  printf '%s\n' "$config_json" > "$preview_root/.agent-swarm-framework.config.json"
  jq -n --argjson cfg "$config_json" '{generatedAt:(now|todateiso8601), config:$cfg}' > "$preview_root/.agent-swarm-framework.manifest.json"
  for category in runtime-core agent-skills executors template-project; do
    if [[ "$category" == "executors" ]]; then
      local remote_provider
      remote_provider="$(printf '%s' "$config_json" | jq -r '.remoteProvider')"
      [[ "$remote_provider" == "github-actions" || "$remote_provider" == "both" ]] || continue
    fi
    copy_category_preview "$category" "$preview_root"
  done
}

apply_category() {
  local category="$1"
  local target_root="$2"
  local config_json="$3"
  local stage_root
  stage_root="$(mktemp -d)"
  copy_category_preview "$category" "$stage_root"
  if [[ "$category" == "runtime-core" ]]; then
    write_engine_routing_file "$stage_root" "$config_json"
  fi
  mkdir -p "$target_root"
  cp -R "$stage_root/." "$target_root/"
  rm -rf "$stage_root"
}

create_github_bootstrap() {
  local target_root="$1"
  local preview_root="$2"
  local script_path="$PACKAGE_ROOT/template-project/github/create-bootstrap-items.sh"
  if [[ "$SKIP_GITHUB" == "true" ]]; then
    echo "Skipped GitHub milestone/issue creation (--skip-github)"
    return
  fi
  if ! command -v gh >/dev/null 2>&1; then
    echo "Skipped GitHub milestone/issue creation (gh not installed)"
    return
  fi
  if ! git -C "$target_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Skipped GitHub milestone/issue creation (target is not a git repository)"
    return
  fi
  if ! confirm "Create bootstrap milestone and issues on GitHub?" y; then
    echo "Skipped GitHub milestone/issue creation"
    return
  fi
  bash "$script_path" --repo-root "$target_root" --definitions-dir "$PACKAGE_ROOT/template-project/github"
}

category_enabled() {
  local category="$1"
  local config_json="$2"
  if [[ "$category" != "executors" ]]; then
    return 0
  fi
  local remote_provider
  remote_provider="$(printf '%s' "$config_json" | jq -r '.remoteProvider')"
  [[ "$remote_provider" == "github-actions" || "$remote_provider" == "both" ]]
}

CONFIG_JSON="$(load_config)"
CONFIG_JSON="$(normalize_config "$CONFIG_JSON")"
if [[ "$RETROFIT_SAFE" == "true" ]]; then
  SKIP_GITHUB="true"
  CONFIG_JSON="$(apply_retrofit_safe_preset "$CONFIG_JSON")"
  echo "[preset] retrofit-safe enabled: executionMode=local, remoteProvider=none, automationStage=plan, mergePolicy=manual, orchestratorMode=local"
  echo "[preset] GitHub bootstrap disabled: --skip-github"
fi
validate_config "$CONFIG_JSON"

PROJECT_SLUG="$(printf '%s' "$CONFIG_JSON" | jq -r '.projectSlug')"
if [[ -z "$PREVIEW_DIR" ]]; then
  PREVIEW_DIR="$PACKAGE_ROOT/.preview/$PROJECT_SLUG"
fi

build_preview "$CONFIG_JSON" "$PREVIEW_DIR"

echo
echo "Preview generated: $PREVIEW_DIR"
echo "Target repository: $TARGET_DIR"
echo "Categories available: runtime-core, agent-skills, executors, template-project"
if [[ "$RETROFIT_SAFE" == "true" ]]; then
  echo "Apply policy (retrofit-safe): runtime-core/agent-skills=default apply, executors/template-project=default skip"
elif [[ "$NON_INTERACTIVE" == "true" ]]; then
  echo "Apply policy (non-interactive): enabled categories are auto-applied"
fi
echo

for category in runtime-core agent-skills executors template-project; do
  if ! category_enabled "$category" "$CONFIG_JSON"; then
    echo "Skipped unavailable category: $category"
    echo
    continue
  fi
  category_stage_root="$(mktemp -d)"
  copy_category_preview "$category" "$category_stage_root"
  if [[ "$category" == "runtime-core" ]]; then
    write_engine_routing_file "$category_stage_root" "$CONFIG_JSON"
  fi

  echo "=================================================="
  echo "--- ${category} プレビュー ---"
  echo "[新規追加]"
  find "$category_stage_root" -type f | sed "s#^$category_stage_root/##" | while read -r f; do
    if [[ ! -e "$TARGET_DIR/$f" ]]; then
      echo "  + $f"
    fi
  done
  echo "[上書き予定]"
  find "$category_stage_root" -type f | sed "s#^$category_stage_root/##" | while read -r f; do
    if [[ -e "$TARGET_DIR/$f" ]]; then
      echo "  * $f"
    fi
  done
  echo "[スキップ対象なし]"
  # スキップ対象は現状なし（将来拡張用）
  echo
  if should_apply_category "$category"; then
    apply_category "$category" "$TARGET_DIR" "$CONFIG_JSON"
    echo "Applied: $category"
  else
    echo "Skipped: $category"
  fi
  rm -rf "$category_stage_root"
  echo
 done


# GitHubラベル適用
LABELS_SCRIPT="$PACKAGE_ROOT/template-project/github/apply-labels.sh"
LABELS_FILE="$PACKAGE_ROOT/template-project/files/.multi-agent/labels.json"
if [[ "$SKIP_GITHUB" == "true" ]]; then
  echo "Skipped GitHub label application (--skip-github)"
else
  if ! command -v gh >/dev/null 2>&1; then
    echo "Skipped GitHub label application (gh not installed)"
  elif ! git -C "$TARGET_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Skipped GitHub label application (target is not a git repository)"
  else
    if bash "$LABELS_SCRIPT" --repo-root "$TARGET_DIR" --labels-file "$LABELS_FILE"; then
      echo "GitHub labels applied."
    else
      echo "GitHub label application failed."
    fi
  fi
fi

create_github_bootstrap "$TARGET_DIR" "$PREVIEW_DIR"

echo "Install flow completed."
