#!/usr/bin/env bash
# init.sh — agent-swarm-framework プロジェクト初期化 CLI
# 目的: 新規リポジトリへ1コマンドで雛形を適用する
# 要件: 冪等性 / dry-run / 失敗時ロールバック
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$PACKAGE_ROOT/install.sh"
MANIFEST_FILE=".agent-swarm-framework.manifest.json"

# ---- デフォルト値 ----
TARGET_DIR="$PWD"
CONFIG_FILE=""
DRY_RUN="false"
SKIP_GITHUB="false"
NON_INTERACTIVE="false"
FORCE="false"

usage() {
  cat <<'EOF'
usage: bash packages/agent-swarm-framework/init.sh [options]

  1コマンドで新規リポジトリにマルチエージェント開発基盤を適用します。
  冪等性: 既に適用済みの場合は --force 未指定時にスキップします。
  dry-run: --dry-run 指定時は変更を行わずプレビューのみ表示します。
  ロールバック: 適用失敗時にバックアップから自動的に復元します。

options:
  --target-dir <path>     適用先リポジトリのパス (default: current directory)
  --config <json-file>    設定 JSON ファイルのパス
  --non-interactive       非インタラクティブモード (--config と併用必須)
  --dry-run               変更せずにプレビューのみ表示
  --force                 既に適用済みでも再適用する
  --skip-github           GitHub milestone/issue 作成をスキップ
  -h, --help              ヘルプを表示して終了
EOF
}

# ---- 引数解析 ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir)       TARGET_DIR="$2"; shift 2 ;;
    --config)           CONFIG_FILE="$2"; shift 2 ;;
    --non-interactive)  NON_INTERACTIVE="true"; shift ;;
    --dry-run)          DRY_RUN="true"; shift ;;
    --force)            FORCE="true"; shift ;;
    --skip-github)      SKIP_GITHUB="true"; shift ;;
    -h|--help)          usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

require_cmd jq

write_target_metadata() {
  local config_json="$1"
  mkdir -p "$TARGET_DIR"
  printf '%s\n' "$config_json" > "$TARGET_DIR/.agent-swarm-framework.config.json"
  jq -n --argjson cfg "$config_json" '{generatedAt:(now|todateiso8601), config:$cfg}' > "$TARGET_DIR/.agent-swarm-framework.manifest.json"
}

# ---- 冪等性チェック ----
if [[ "$FORCE" == "false" && -f "$TARGET_DIR/$MANIFEST_FILE" ]]; then
  echo "[init] 既に適用済みです: $TARGET_DIR/$MANIFEST_FILE"
  echo "[init] 再適用する場合は --force を指定してください。"
  APPLIED_AT="$(jq -r '.generatedAt // "unknown"' "$TARGET_DIR/$MANIFEST_FILE" 2>/dev/null || echo "unknown")"
  echo "[init] 前回適用日時: $APPLIED_AT"
  exit 0
fi

# ---- dry-run ----
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] 変更は行いません。プレビューのみ表示します。"
  echo "[dry-run] target-dir: $TARGET_DIR"
  [[ -n "$CONFIG_FILE" ]] && echo "[dry-run] config: $CONFIG_FILE"

  # dry-run は target 側に一切変更を加えない
  TMP_CONFIG=""
  if [[ -n "$CONFIG_FILE" ]]; then
    TMP_CONFIG="$CONFIG_FILE"
  elif [[ "$NON_INTERACTIVE" != "true" ]]; then
    echo "[dry-run] インタラクティブモードでは --config を指定して dry-run を使用してください。"
    exit 0
  fi

  SLUG="$(jq -r '.projectSlug' "$TMP_CONFIG" 2>/dev/null || echo "preview")"
  PREVIEW_DIR="$PACKAGE_ROOT/.preview/$SLUG"

  # 設定内容を表示するのみ（ファイルは生成しない）
  CONFIG_JSON="$(cat "$TMP_CONFIG")"
  echo "[dry-run] プレビュー先: $PREVIEW_DIR"
  echo "[dry-run] 設定内容:"
  printf '%s\n' "$CONFIG_JSON" | jq .
  exit 0
fi

# ---- ロールバック用バックアップ ----
BACKUP_DIR=""
cleanup_backup() {
  [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] && rm -rf "$BACKUP_DIR"
}

create_backup() {
  BACKUP_DIR="$(mktemp -d)"
  # 管理対象ファイルが存在する場合はバックアップ
  for f in \
    ".agent-swarm-framework.config.json" \
    ".agent-swarm-framework.manifest.json" \
    ".multi-agent" \
    "scripts/gate" \
    "scripts/monitor" \
    "scripts/worker" \
    ".github/workflows"; do
    if [[ -e "$TARGET_DIR/$f" ]]; then
      mkdir -p "$BACKUP_DIR/$(dirname "$f")"
      cp -R "$TARGET_DIR/$f" "$BACKUP_DIR/$f" 2>/dev/null || true
    fi
  done
  echo "$BACKUP_DIR"
}

restore_backup() {
  local backup="$1"
  [[ -d "$backup" ]] || return
  echo "[rollback] 適用失敗のためロールバックします: $backup"
  cp -R "$backup/." "$TARGET_DIR/" 2>/dev/null || true
  rm -rf "$backup"
  echo "[rollback] 完了"
}

BACKUP_DIR="$(create_backup)"
trap 'restore_backup "$BACKUP_DIR"' ERR

# ---- インストーラーへ委譲 ----
INSTALL_ARGS=("--target-dir" "$TARGET_DIR")
[[ -n "$CONFIG_FILE" ]] && INSTALL_ARGS+=("--config" "$CONFIG_FILE")
[[ "$NON_INTERACTIVE" == "true" ]] && INSTALL_ARGS+=("--non-interactive")
[[ "$SKIP_GITHUB" == "true" ]] && INSTALL_ARGS+=("--skip-github")

echo "[init] インストールを開始します: target=$TARGET_DIR"
if [[ "$NON_INTERACTIVE" == "true" ]]; then
  # install.sh 側のカテゴリ適用確認プロンプトに自動応答する
  bash "$INSTALLER" "${INSTALL_ARGS[@]}" < <(printf 'Y\n%.0s' {1..10})
else
  bash "$INSTALLER" "${INSTALL_ARGS[@]}"
fi

# 適用後メタデータを target に保存（冪等性チェックの基準にも使う）
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  CONFIG_JSON="$(cat "$CONFIG_FILE")"
  write_target_metadata "$CONFIG_JSON"
else
  # interactive 実行時は最新 preview から復元
  LATEST_CFG="$(find "$PACKAGE_ROOT/.preview" -type f -name '.agent-swarm-framework.config.json' -print 2>/dev/null | tail -n 1 || true)"
  if [[ -n "$LATEST_CFG" && -f "$LATEST_CFG" ]]; then
    CONFIG_JSON="$(cat "$LATEST_CFG")"
    write_target_metadata "$CONFIG_JSON"
  fi
fi

# 成功時はバックアップを削除
cleanup_backup
trap - ERR

echo "[init] 完了: $TARGET_DIR"
