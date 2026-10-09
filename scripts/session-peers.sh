#!/usr/bin/env bash
# session-peers.sh — 同じプロジェクトで動くほかの Claude Code セッションの一覧と、宛先の解決。
#
# 実行環境に依存しない台帳（session-ledger.sh）とは分けた、Claude Code に固有の部分。
# Claude Code が動いているセッションごとに書く ~/.claude/sessions/<PID>.json を読む。
# SendMessage の宛先名（json の name）を、番号・名前・#issue・作業ツリー名から引く。
# 規範は .ai-playbook/shared-ai-rules.md「セッション間の協調」。
#
# 使い方:
#   session-peers.sh list [--names] [--others]
#       同じプロジェクトのセッションを、番号 / 宛先名 / 作業ツリー / 台帳の issue / 状態 で表示する。
#       --names は宛先名だけを 1 行ずつ出す（一斉送信の宛先に使う）。--others は自分を除く。
#   session-peers.sh resolve <指定>
#       番号・名前（完全一致、前方一致）・#issue・作業ツリー名を、宛先名 1 件へ解決して出す。
#       0 件なら終了コード 1、複数件なら 3 で、候補を標準エラーへ出す。
#   session-peers.sh whoami
#       送り元の署名の行（宛先名・場所・作業ツリー・issue）を出す。
#
# 一覧に出す条件（すべて満たすもの）:
#   - json の pidDomain が自分と同じ（~/.claude は named volume で、前のコンテナの json が
#     残る。別のコンテナの PID は無関係なので、必須にする）
#   - その PID のプロセスが生きていて、開始時刻が json の procStart と一致する
#     （PID が再利用された別のプロセスを除く）
#   - json の cwd の git-common-dir が自分と同じ（別の作業ツリーでも同じリポジトリなら出る）
#
# 制約と fail-open:
#   - ~/.claude/sessions/*.json は公開された仕様ではない（Claude Code 2.1.296 で実測）。
#     読めない・形が違うときは警告を出して、ListAgents を使うよう案内する。終了コードは 0。
#   - -p（非対話）のセッションは json に登録されないため出ない。
#
# 環境変数: SESSION_PEERS_SESSIONS_DIR（json の置き場所。既定 ~/.claude/sessions）/
#           SESSION_PEERS_PID_DOMAIN（自分の pidDomain。既定は /proc/self/ns/pid から）/
#           SESSION_PEERS_SELF_PID（自分のセッションの PID。既定は祖先をたどって特定）/
#           SESSION_HOST_LABEL（署名に入れる場所。.env にもある。値は固有なのでここには書かない）
#
# bash 3.2 互換（連想配列・mapfile を使わない）。
set -u

TAB="$(printf '\t')"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
LEDGER="$SCRIPT_DIR/session-ledger.sh"
SESSIONS_DIR="${SESSION_PEERS_SESSIONS_DIR:-$HOME/.claude/sessions}"

warn() { echo "[session-peers] WARN: $*" >&2; }

usage() {
  cat >&2 <<'USAGE'
usage: session-peers.sh list [--names] [--others]
       session-peers.sh resolve <番号|名前|#issue|作業ツリー名>
       session-peers.sh whoami
USAGE
}

fallback_hint() {
  warn "$1。ListAgents で動いているセッションを確かめてください。"
}

# /proc/<PID>/stat の 22 列目（起動からの経過のクロック数）。取れなければ空。
proc_start() { # pid
  local stat
  case "$1" in '' | *[!0-9]*) return 0 ;; esac
  [ -r "/proc/$1/stat" ] || return 0
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 0
  case "$stat" in
    *')'*) stat="${stat##*\)}" ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$stat" | awk '{ print $20 }'
}

# 自分の pidDomain。取れなければ空（その場合は pidDomain を検査しない）。
self_domain() {
  local link
  if [ -n "${SESSION_PEERS_PID_DOMAIN:-}" ]; then
    printf '%s' "$SESSION_PEERS_PID_DOMAIN"
    return 0
  fi
  link="$(readlink /proc/self/ns/pid 2>/dev/null)" || link=""
  [ -n "$link" ] && printf 'linux::%s' "$link"
  return 0
}

# git-common-dir を実体のパスで返す。取れなければ空。
common_dir_of() { # ディレクトリ
  local common
  [ -d "$1" ] || return 0
  common="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 0
  [ -n "$common" ] || return 0
  case "$common" in /*) ;; *) common="$1/$common" ;; esac
  (cd -P "$common" 2>/dev/null && pwd -P)
}

# 作業ツリーの名前（ルートのディレクトリ名）。git でなければ cwd の名前。
worktree_name_of() { # ディレクトリ
  local top
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || top=""
  [ -n "$top" ] || top="$1"
  printf '%s' "${top##*/}"
}

# 自分のセッションの PID。祖先をたどり、json のあるプロセスを最初に見つけたもの。
self_pid() {
  local p pp i
  if [ -n "${SESSION_PEERS_SELF_PID:-}" ]; then
    printf '%s' "$SESSION_PEERS_SELF_PID"
    return 0
  fi
  p=$$
  i=0
  while [ "$i" -lt 32 ]; do
    pp="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    case "$pp" in '' | *[!0-9]*) return 0 ;; esac
    [ "$pp" -gt 1 ] || return 0
    if [ -f "$SESSIONS_DIR/$pp.json" ]; then
      printf '%s' "$pp"
      return 0
    fi
    p="$pp"
    i=$((i + 1))
  done
  return 0
}

# 台帳から、セッション識別子ごとの issue（#番号のカンマ区切り）を TSV で出す。
#   <識別子>\t#1,#2
ledger_issues() {
  [ -f "$LEDGER" ] || return 0
  bash "$LEDGER" list --all 2>/dev/null | awk '
    {
      sid = ""; kind = ""; tgt = ""; state = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^session=/) sid = substr($i, 9)
        else if ($i ~ /^kind=/) kind = substr($i, 6)
        else if ($i ~ /^target=/) tgt = substr($i, 8)
        else if ($i ~ /^state=/) state = substr($i, 7)
      }
      if (kind == "issue" && state == "live" && tgt != "") {
        if (acc[sid] == "") acc[sid] = "#" tgt
        else acc[sid] = acc[sid] ",#" tgt
      }
    }
    END { for (s in acc) printf "%s\t%s\n", s, acc[s] }
  '
}

# 同じプロジェクトの生きているセッションを集めて TSV で出す（startedAt 昇順）:
#   宛先名 \t 作業ツリー名 \t issue \t 状態 \t PID \t 自分なら self、他は -
collect_rows() {
  local f raw domain mine_common me pid proc_start_json name cwd status started pdomain
  local alive_start wt issues key sid
  if ! command -v jq >/dev/null 2>&1; then
    fallback_hint "jq が無いため、セッションの json を読めません"
    return 0
  fi
  if [ ! -d "$SESSIONS_DIR" ]; then
    fallback_hint "セッションの json の置き場所が見つかりません（$SESSIONS_DIR）"
    return 0
  fi
  domain="$(self_domain)"
  mine_common="$(common_dir_of "$(pwd)")"
  if [ -z "$mine_common" ]; then
    fallback_hint "git リポジトリの共通ディレクトリを解決できないため、同じプロジェクトを判定できません"
    return 0
  fi
  me="$(self_pid)"
  issues="$(ledger_issues)"

  for f in "$SESSIONS_DIR"/*.json; do
    [ -e "$f" ] || continue
    raw="$(jq -r '[.pid, .procStart, .name, .cwd, (.status // "-"), (.startedAt // 0), (.pidDomain // "")] | map(tostring) | join("\u0001")' "$f" 2>/dev/null)" || raw=""
    if [ -z "$raw" ]; then
      warn "読めない、または形が違う json を読み飛ばします: $f"
      continue
    fi
    pid="${raw%%$'\001'*}"; raw="${raw#*$'\001'}"
    proc_start_json="${raw%%$'\001'*}"; raw="${raw#*$'\001'}"
    name="${raw%%$'\001'*}"; raw="${raw#*$'\001'}"
    cwd="${raw%%$'\001'*}"; raw="${raw#*$'\001'}"
    status="${raw%%$'\001'*}"; raw="${raw#*$'\001'}"
    started="${raw%%$'\001'*}"; raw="${raw#*$'\001'}"
    pdomain="$raw"
    case "$pid" in '' | *[!0-9]* | null) warn "pid が数字でない json を読み飛ばします: $f"; continue ;; esac
    case "$name" in '' | null) warn "name が無い json を読み飛ばします: $f"; continue ;; esac
    case "$started" in '' | *[!0-9]*) started=0 ;; esac

    # 別のコンテナの json は無関係。
    if [ -n "$domain" ] && [ "$pdomain" != "$domain" ]; then continue; fi
    # PID が生きていて、開始時刻が一致すること（再利用された PID を除く）。
    alive_start="$(proc_start "$pid")"
    [ -n "$alive_start" ] && [ "$alive_start" = "$proc_start_json" ] || continue
    # 同じリポジトリ（git-common-dir が同じ）であること。
    [ "$(common_dir_of "$cwd")" = "$mine_common" ] || continue

    wt="$(worktree_name_of "$cwd")"
    key="pid-$pid-$proc_start_json"
    sid="$(printf '%s\n' "$issues" | awk -F'\t' -v k="$key" '$1 == k { print $2; exit }')"
    [ -n "$sid" ] || sid="-"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$started" "$name" "$wt" "$sid" "$status" "$pid" \
      "$([ "$pid" = "$me" ] && echo self || echo -)"
  done | sort -t "$TAB" -k1,1n -k6,6n | cut -f2-
}

cmd_list() {
  local names=0 others=0 a rows n=0 name wt iss st pid self
  for a in "$@"; do
    case "$a" in
      --names) names=1 ;;
      --others) others=1 ;;
      *) usage; return 2 ;;
    esac
  done
  rows="$(collect_rows)"
  if [ -z "$rows" ]; then
    [ "$names" -eq 1 ] || echo "(同じプロジェクトで動いているセッションは見つかりませんでした)"
    return 0
  fi
  [ "$names" -eq 1 ] || printf '番号\t宛先名\t作業ツリー\t台帳の issue\t状態\n'
  while IFS="$TAB" read -r name wt iss st pid self; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    if [ "$others" -eq 1 ] && [ "$self" = "self" ]; then continue; fi
    if [ "$names" -eq 1 ]; then
      printf '%s\n' "$name"
    else
      if [ "$self" = "self" ]; then st="$st (自分)"; fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$n" "$name" "$wt" "$iss" "$st"
    fi
  done <<EOF
$rows
EOF
  return 0
}

# 候補を標準エラーへ出す。
print_candidates() { # 行（宛先名\t作業ツリー\tissue\t…）
  local name wt iss _rest
  while IFS="$TAB" read -r name wt iss _rest; do
    [ -n "$name" ] || continue
    printf '  %s\t%s\t%s\n' "$name" "$wt" "$iss" >&2
  done <<EOF
$1
EOF
}

cmd_resolve() {
  local spec="${1:-}" rows matched count
  if [ -z "$spec" ]; then usage; return 2; fi
  rows="$(collect_rows)"
  if [ -z "$rows" ]; then
    echo "[session-peers] 同じプロジェクトで動いているセッションが見つかりません。" >&2
    return 1
  fi

  # 段ごとに絞り、最初に 1 件以上あった段で決める（複数件ならそこで曖昧として止める）。
  matched=""
  case "$spec" in
    '' | *[!0-9]*) ;;
    *) matched="$(printf '%s\n' "$rows" | awk -F'\t' -v n="$spec" 'NR == n + 0 { print }')" ;;
  esac
  if [ -z "$matched" ]; then
    case "$spec" in
      \#*)
        matched="$(printf '%s\n' "$rows" | awk -F'\t' -v q="$spec" '
          { m = split($3, a, ","); for (i = 1; i <= m; i++) if (a[i] == q) { print; break } }')"
        ;;
    esac
  fi
  [ -n "$matched" ] || matched="$(printf '%s\n' "$rows" | awk -F'\t' -v q="$spec" '$1 == q')"
  [ -n "$matched" ] || matched="$(printf '%s\n' "$rows" | awk -F'\t' -v q="$spec" 'index($1, q) == 1')"
  [ -n "$matched" ] || matched="$(printf '%s\n' "$rows" | awk -F'\t' -v q="$spec" '$2 == q')"

  if [ -z "$matched" ]; then
    echo "[session-peers] 「$spec」に該当するセッションがありません。候補:" >&2
    print_candidates "$rows"
    return 1
  fi
  count="$(printf '%s\n' "$matched" | wc -l | tr -d ' ')"
  if [ "$count" -gt 1 ]; then
    echo "[session-peers] 「$spec」に該当するセッションが $count 件あります。絞り込んでください。候補:" >&2
    print_candidates "$matched"
    return 3
  fi
  printf '%s\n' "$matched" | cut -f1
  return 0
}

cmd_whoami() {
  local rows name="" wt iss label root line
  rows="$(collect_rows)"
  line="$(printf '%s\n' "$rows" | awk -F'\t' '$6 == "self" { print; exit }')"
  if [ -n "$line" ]; then
    name="$(printf '%s' "$line" | cut -f1)"
    wt="$(printf '%s' "$line" | cut -f2)"
    iss="$(printf '%s' "$line" | cut -f3)"
  else
    warn "自分のセッションの json を特定できません（-p の非対話セッションは登録されません）。"
    name="(宛先名不明)"
    wt="$(worktree_name_of "$(pwd)")"
    iss="-"
  fi
  root="$(dirname "$SCRIPT_DIR")"
  label="${SESSION_HOST_LABEL:-}"
  if [ -z "$label" ] && [ -r "$root/.env" ]; then
    label="$(command grep -E '^[[:space:]]*SESSION_HOST_LABEL=' "$root/.env" 2>/dev/null | tail -n 1 | sed -e 's/^[^=]*=//' -e 's/[[:space:]]*#.*$//' -e 's/^["'\'']//' -e 's/["'\'']$//')"
  fi
  [ -n "$label" ] || label="-"
  printf '[from: %s | 場所: %s | 作業ツリー: %s | issue: %s]\n' "$name" "$label" "$wt" "$iss"
}

main() {
  local sub="${1:-}"
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    list) cmd_list "$@" ;;
    resolve) cmd_resolve "$@" ;;
    whoami) cmd_whoami ;;
    *) usage; return 2 ;;
  esac
}

# source ガード。読み込まれただけのときは関数定義だけを提供する。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
  exit $?
fi
