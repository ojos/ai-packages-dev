#!/usr/bin/env bash
# claude-session-wrapper.sh — Claude Code のセッションの宛先名へ、場所と作業ツリーを自動で含める起動ラッパー。
#
# VS Code 拡張の設定 claudeCode.claudeProcessWrapper に指定する（--with-claude の構成では
# .devcontainer/devcontainer.json が配線する）。拡張はこのラッパーを
#   <ラッパー> <Claude Code 本体のパス> <引数…>
# の形で呼ぶ。セッション以外の内部の操作にも使われる。
#
# やること:
#   .env の SESSION_HOST_LABEL（無ければ環境変数）があれば、環境変数
#   CLAUDE_CODE_SESSION_NAME を <ラベル>-<作業ツリー名>-<2桁の16進> にして exec する。
#   この値が SendMessage の宛先名になり、ListAgents にも出る。16進は起動ごとに変わる
#   （同じ作業ツリーで複数のセッションを動かしても宛先名が重ならないようにするため）。
#
# 何も変えずに exec "$@" するとき（起動を妨げないことが最優先）:
#   - ラベルが無い
#   - CLAUDE_CODE_SESSION_NAME が設定済み（利用者の指定を上書きしない）
#   - 名前の計算に失敗した
#   どんな失敗でも、最後は必ず exec "$@" まで進む。
#
# 場所のラベルは固有の値なので .env にだけ置く（既定は空）。起動したあとの名前の変更は
# 利用者の /rename だけで、このラッパーは扱わない。
#
# bash 3.2 互換。set -e は使わない（途中の失敗で止めない）。
set -u

# 名前の部品を、宛先名として安全な文字（英数字と ._-）だけにする。
sanitize_part() { # 文字列
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# .env から SESSION_HOST_LABEL の値を読む。source はしない（任意のコードを実行しない）。
# 最後の定義を採用し、前後の空白と、全体を囲む引用符を外す。
read_label_from_env_file() { # .env のパス
  local line value
  [ -r "$1" ] || return 0
  line="$(command grep -E '^[[:space:]]*(export[[:space:]]+)?SESSION_HOST_LABEL=' "$1" 2>/dev/null | tail -n 1)" || return 0
  value="${line#*SESSION_HOST_LABEL=}"
  value="${value%%#*}"
  value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "$value" in
    \"*\") value="${value#\"}"; value="${value%\"}" ;;
    \'*\') value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s' "$value"
}

# 宛先名を計算して標準出力へ出す。失敗したら何も出さず 1 を返す。
compute_name() {
  local script_dir root label top wt hex name
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || return 1
  root="$(dirname "$script_dir")"
  label="$(read_label_from_env_file "$root/.env")"
  [ -n "$label" ] || label="${SESSION_HOST_LABEL:-}"
  [ -n "$label" ] || return 1

  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
  [ -n "$top" ] || top="$(pwd)"
  wt="${top##*/}"
  [ -n "$wt" ] || return 1

  hex="$(od -An -N1 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')" || return 1
  case "$hex" in
    [0-9a-f][0-9a-f]) ;;
    *) return 1 ;;
  esac

  name="$(sanitize_part "$label")-$(sanitize_part "$wt")-$hex"
  [ -n "$name" ] || return 1
  printf '%s' "$name"
}

if [ -z "${CLAUDE_CODE_SESSION_NAME:-}" ]; then
  if session_name="$(compute_name 2>/dev/null)" && [ -n "$session_name" ]; then
    export CLAUDE_CODE_SESSION_NAME="$session_name"
  fi
fi

[ "$#" -gt 0 ] || exit 0
exec "$@"
