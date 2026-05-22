#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/.github/ai-directory-policy.json"

NON_INTERACTIVE="false"
MODE=""
CODE_DIR=""
DOCS_DIR=""
TESTS_DIR=""
SUBDIR_PROFILE=""
ENFORCEMENT=""

usage() {
  cat <<'EOF'
usage: bash scripts/setup-ai-directory-policy.sh [options]

options:
  --non-interactive                 非対話モード
  --mode <recommended|reference-only>
  --code-dir <name>                 既定: src
  --docs-dir <name>                 既定: docs
  --tests-dir <name>                既定: tests
  --subdir-profile <none|recommended>
  --enforcement <warning|strict>
  --config-file <path>              出力先（既定: .github/ai-directory-policy.json）
  -h, --help                        ヘルプ表示

notes:
  - このウィザードはトップレベル構造の推奨設定を作成する。
  - 既存プロジェクトの構造を強制変更しない。
EOF
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "error: required command not found: $cmd" >&2
    exit 1
  }
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

ask_text() {
  local prompt="$1"
  local default="$2"
  local answer
  read -r -p "$prompt [$default]: " answer
  printf '%s' "${answer:-$default}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive)
      NON_INTERACTIVE="true"
      shift
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --code-dir)
      CODE_DIR="$2"
      shift 2
      ;;
    --docs-dir)
      DOCS_DIR="$2"
      shift 2
      ;;
    --tests-dir)
      TESTS_DIR="$2"
      shift 2
      ;;
    --subdir-profile)
      SUBDIR_PROFILE="$2"
      shift 2
      ;;
    --enforcement)
      ENFORCEMENT="$2"
      shift 2
      ;;
    --config-file)
      CONFIG_FILE="$2"
      shift 2
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

require_cmd jq

if [[ "$NON_INTERACTIVE" == "false" ]]; then
  echo "=== AI ディレクトリ構造ポリシー設定ウィザード ==="
  echo "目的: 生成時の推奨トップレベル構造を設定し、既存構造の尊重方針を明確化する。"
  echo

  MODE="${MODE:-$(ask_choice "トップレベル推奨を適用しますか？" "reference-only" "recommended" "reference-only")}" 
  CODE_DIR="${CODE_DIR:-$(ask_text "ソースコードの既定ディレクトリ" "src")}" 
  DOCS_DIR="${DOCS_DIR:-$(ask_text "ドキュメントの既定ディレクトリ" "docs")}" 
  TESTS_DIR="${TESTS_DIR:-$(ask_text "テストの既定ディレクトリ" "tests")}" 
  SUBDIR_PROFILE="${SUBDIR_PROFILE:-$(ask_choice "サブディレクトリ推奨を有効化しますか？" "none" "none" "recommended")}" 
  ENFORCEMENT="${ENFORCEMENT:-$(ask_choice "違反時の扱い" "warning" "warning" "strict")}" 
else
  MODE="${MODE:-reference-only}"
  CODE_DIR="${CODE_DIR:-src}"
  DOCS_DIR="${DOCS_DIR:-docs}"
  TESTS_DIR="${TESTS_DIR:-tests}"
  SUBDIR_PROFILE="${SUBDIR_PROFILE:-none}"
  ENFORCEMENT="${ENFORCEMENT:-warning}"
fi

if [[ "$MODE" != "recommended" && "$MODE" != "reference-only" ]]; then
  echo "error: --mode must be recommended or reference-only" >&2
  exit 1
fi

if [[ "$SUBDIR_PROFILE" != "none" && "$SUBDIR_PROFILE" != "recommended" ]]; then
  echo "error: --subdir-profile must be none or recommended" >&2
  exit 1
fi

if [[ "$ENFORCEMENT" != "warning" && "$ENFORCEMENT" != "strict" ]]; then
  echo "error: --enforcement must be warning or strict" >&2
  exit 1
fi

mkdir -p "$(dirname "$CONFIG_FILE")"

jq -n \
  --arg mode "$MODE" \
  --arg codeDir "$CODE_DIR" \
  --arg docsDir "$DOCS_DIR" \
  --arg testsDir "$TESTS_DIR" \
  --arg subdirProfile "$SUBDIR_PROFILE" \
  --arg enforcement "$ENFORCEMENT" \
  '{
    version: "1.0",
    policy: {
      generatedLayoutMode: $mode,
      existingProjectPolicy: "respect-existing",
      topLevelDefaults: {
        source: $codeDir,
        docs: $docsDir,
        tests: $testsDir
      },
      subdirectoryProfile: $subdirProfile,
      enforcement: $enforcement
    }
  }' > "$CONFIG_FILE"

echo
echo "[ok] ディレクトリポリシーを作成しました: $CONFIG_FILE"
echo
echo "要約:"
echo "- generatedLayoutMode: $MODE"
echo "- topLevelDefaults: source=$CODE_DIR docs=$DOCS_DIR tests=$TESTS_DIR"
echo "- subdirectoryProfile: $SUBDIR_PROFILE"
echo "- enforcement: $ENFORCEMENT"
echo
echo "次の推奨手順:"
echo "1) .github/project-ai-rules.md でこの設定ファイルを参照する"
echo "2) 生成系スクリプトで本設定を読み、既存構造を尊重して適用する"
