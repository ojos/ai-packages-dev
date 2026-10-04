#!/usr/bin/env bash
# session-ledger.sh — 同じホストで並行して動く AI セッションの共有台帳。
#
# 規範は .ai-playbook/shared-ai-rules.md「セッション間の協調」。この文書へ判定基準を
# 複製しない。ここは台帳の読み書きだけを担い、実行環境（フック・メッセージ）には依存しない。
#
# 使い方:
#   session-ledger.sh claim   <kind> [target]   登録する（同じ登録は更新時刻を更新する）
#   session-ledger.sh release [<kind> [target]] 自分の登録を解放する（引数なしは全部）
#   session-ledger.sh list    [--others|--all]  登録を表示する（既定は生きている登録すべて）
#   session-ledger.sh check   <kind> [target]   他セッションの登録と衝突するかを調べる
#
# kind（登録の種類）と衝突の判定・強さ:
#   issue  target = issue 番号（# は付けても付けなくてもよい）。同じ番号で衝突。警告。
#   doc    target = 文書のパス（作業ツリーの絶対パスは相対へ直す。末尾 / はその配下すべて）。
#          同じパスで衝突。警告。
#   merge  マージ・リリース。target は任意。種類が同じなら衝突。拒否。
#   git    作業ツリーでの git 操作（checkout / rebase / reset / fetch など）。target 省略時は
#          現在の作業ツリー。同じ作業ツリーで衝突。拒否。
#   gate   重いゲート（verify / loop-gate など）。種類が同じなら衝突。拒否。
#   台帳は排他制御ではなく合図である。2 つのセッションがほぼ同時に登録すると、両方が
#   通ることがある。止める強さは「拒否」でも、確実な排他を保証しない。
#
# 置き場所と書式:
#   $(git rev-parse --git-common-dir)/session-ledger/<セッション識別子>.tsv
#   作業ツリーをまたいで共有され、セッションごとに別ファイルへ追記する（追記のみ。
#   既存の行を書き換えない。解放も「解放の行」を足す）。1 行 = タブ区切り 6 列:
#     時刻(epoch 秒)  claim|release  kind  target  PID  作業ツリー
#   release の kind が * なら全部、target が * ならその種類すべてを解放する。
#
# セッションの識別子と持ち主の PID:
#   SESSION_LEDGER_ID があればそれを使う（英数字と ._- 以外は _ になる）。無ければ
#   pid-<持ち主の PID>。持ち主の PID は SESSION_LEDGER_PID があればそれ、無ければ祖先の
#   プロセスをたどって、最初に現れるシェル以外のプロセス（セッションを動かしている
#   本体）。見つからなければ親プロセス。識別子は pid-<PID>-<開始時刻の cksum> で、
#   PID が再利用されても別のセッションとして扱う。
#   人がシェルから直接使うときは、同じ端末から起動した複数のシェルが同じ持ち主に
#   なりうるので、SESSION_LEDGER_ID を明示する。
#
# 失効:
#   次のどちらかなら、その登録は失効したものとして無視する。
#     - 持ち主の PID のプロセスが存在しない
#     - そのセッションの最後の更新から SESSION_LEDGER_TTL 秒（既定 28800）を超えた
#
# 出力と終了コード（check / claim）:
#   標準出力の 1 行目が判定。LEDGER_OK（衝突なし）/ LEDGER_WARN（警告して通す）/
#   LEDGER_DENY（拒否）/ LEDGER_SKIP（台帳を読み書きできなかった。警告を出して通す）。
#   衝突があれば続けて、衝突ごとに 1 行
#     conflict: session=… kind=… target=… pid=… worktree=… age=…s
#   と、調整の手順を `coordinate` で始まる行で出す。
#   終了コードは LEDGER_DENY のときだけ 3。それ以外は 0（台帳の不具合は fail-open）。
#   使い方の誤りは 2。
#
# 環境変数: SESSION_LEDGER_ID / SESSION_LEDGER_PID / SESSION_LEDGER_TTL /
#           SESSION_LEDGER_DIR（置き場所を差し替える。試験用）
#
# bash 3.2 互換（連想配列・mapfile を使わない）。
set -u

warn() { echo "[session-ledger] WARN: $*" >&2; }

usage() {
  cat >&2 <<'USAGE'
usage: session-ledger.sh claim   <issue|doc|merge|git|gate> [target]
       session-ledger.sh release [<kind> [target]]
       session-ledger.sh list    [--others|--all]
       session-ledger.sh check   <issue|doc|merge|git|gate> [target]
USAGE
}

TAB="$(printf '\t')"

valid_kind() {
  case "$1" in
    issue | doc | merge | git | gate) return 0 ;;
    *) return 1 ;;
  esac
}

# 止める強さ。種類ごとに固定する（規範の表と同じ）。
level_of() {
  case "$1" in
    issue | doc) echo "WARN" ;;
    *) echo "DENY" ;;
  esac
}

# ファイル名として安全な形へ直す。置き換えが起きたときは、元の識別子の cksum を足して、
# 別の識別子（a/b と a_b など）が同じファイルにならないようにする。置き換えが起きない
# 識別子は変えない。
sanitize() {
  local s sum
  s="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
  # 先頭の . は隠しファイルになり、台帳の読み出し（*.tsv）から漏れるので置き換える。
  case "$s" in .*) s="_${s#.}" ;; esac
  if [ "$s" != "$1" ]; then
    sum="$(printf '%s' "$1" | cksum | cut -d' ' -f1)"
    s="$s-$sum"
  fi
  printf '%s' "$s"
}

# ── 持ち主の PID とセッション識別子 ──────────────────────────────────────────

owner_pid() {
  local p pp comm base i
  if [ -n "${SESSION_LEDGER_PID:-}" ]; then
    echo "$SESSION_LEDGER_PID"
    return 0
  fi
  p=$$
  i=0
  while [ "$i" -lt 32 ]; do
    pp="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    case "$pp" in '' | *[!0-9]*) break ;; esac
    [ "$pp" -gt 1 ] || break
    comm="$(ps -o comm= -p "$pp" 2>/dev/null)"
    base="${comm##*/}"
    base="${base#-}"
    case "$base" in
      bash | sh | zsh | dash | ksh | fish | env | timeout | sudo | xargs)
        p="$pp"
        i=$((i + 1))
        continue
        ;;
    esac
    echo "$pp"
    return 0
  done
  # 持ち主を特定できない。PID 1 などは別のセッションと共有してしまうので使わない。
  case "$PPID" in '' | *[!0-9]*) return 0 ;; esac
  [ "$PPID" -gt 1 ] && echo "$PPID"
  return 0
}

# 持ち主を特定できないときは SELF_ID を空にし、登録・確認を警告して通す（fail-open）。
# SESSION_LEDGER_ID を明示した場合は、PID を特定できなくても親プロセスを使う。
# プロセスの開始時刻の cksum。PID が再利用されたとき、別のプロセスと見分けるために使う。
# 取れないときは - を返す（従来の PID だけの判定に落ちる）。
proc_start_key() { # pid
  local lstart sum
  lstart="$(ps -o lstart= -p "$1" 2>/dev/null)"
  [ -n "$lstart" ] || { printf '%s' "-"; return 0; }
  sum="$(printf '%s' "$lstart" | cksum | cut -d' ' -f1)"
  printf '%s' "${sum:--}"
}

SELF_PID="$(owner_pid)"
SELF_ID=""
SELF_KEY="-"
if [ -n "${SESSION_LEDGER_ID:-}" ]; then
  SELF_ID="$(sanitize "$SESSION_LEDGER_ID")"
  [ -n "$SELF_PID" ] || SELF_PID="$PPID"
  SELF_KEY="$(proc_start_key "$SELF_PID")"
elif [ -n "$SELF_PID" ]; then
  SELF_KEY="$(proc_start_key "$SELF_PID")"
  SELF_ID="pid-$SELF_PID"
  [ "$SELF_KEY" = "-" ] || SELF_ID="$SELF_ID-$SELF_KEY"
fi

# 持ち主を特定できないとき 0 を返す（呼び出し側が警告して通す）。
owner_unknown() {
  [ -n "$SELF_ID" ] && return 1
  warn "セッションの持ち主を特定できません。SESSION_LEDGER_ID と SESSION_LEDGER_PID を指定してください。台帳を使わず通します。"
  return 0
}

# 持ち主が生きているか。登録時の開始時刻が分かっていて、いまのプロセスの開始時刻と
# 違えば、PID が再利用された別のプロセスなので、生きていないものとして扱う。
pid_alive() { # pid [開始時刻の cksum]
  local now_key
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  if ! kill -0 "$1" 2>/dev/null; then
    # 他ユーザーのプロセスは kill -0 が EPERM で失敗する。存在だけを ps で確かめる。
    ps -p "$1" >/dev/null 2>&1 || return 1
  fi
  case "${2:--}" in
    - | '') return 0 ;;
  esac
  now_key="$(proc_start_key "$1")"
  [ "$now_key" = "-" ] || [ "$now_key" = "$2" ]
}

# ── 置き場所 ──────────────────────────────────────────────────────────────────

LEDGER_DIR=""
resolve_dir() {
  local common
  if [ -n "${SESSION_LEDGER_DIR:-}" ]; then
    LEDGER_DIR="$SESSION_LEDGER_DIR"
    return 0
  fi
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  common="$(cd "$common" 2>/dev/null && pwd)" || return 1
  LEDGER_DIR="$common/session-ledger"
}

TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$TOPLEVEL" ] || TOPLEVEL="$(pwd)"
# シンボリックリンクをたどった実体のパスに揃える（同じ作業ツリーが別の表記で現れても一致させる）。
TOPLEVEL="$(cd -P "$TOPLEVEL" 2>/dev/null && pwd -P || printf '%s' "$TOPLEVEL")"

# 台帳の置き場所を使える状態にする。失敗したら呼び出し側が警告して通す。
ensure_dir() {
  resolve_dir || { warn "git リポジトリの共通ディレクトリを解決できません。台帳を使わず通します。"; return 1; }
  mkdir -p "$LEDGER_DIR" 2>/dev/null && [ -d "$LEDGER_DIR" ] && [ -w "$LEDGER_DIR" ] || {
    warn "台帳の置き場所を作れない、または書けません: $LEDGER_DIR。台帳を使わず通します。"
    return 1
  }
}

# ── 対象の正規化 ──────────────────────────────────────────────────────────────

# パスを絶対パスにし、. と .. を畳む。存在しない部分は、存在する親ディレクトリの実体
# から先を字句だけで畳む。末尾の / は保つ。
normalize_path() {
  local p="$1" trail="" abs out seg d rest real
  case "$p" in */) trail="/" ;; esac
  case "$p" in
    /*) abs="$p" ;;
    *) abs="$(pwd -P)/$p" ;;
  esac
  out=""
  set -f
  local IFS=/
  for seg in $abs; do
    case "$seg" in
      '' | .) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  unset IFS
  set +f
  abs="${out:-/}"
  d="$abs"
  rest=""
  while [ ! -d "$d" ] && [ "$d" != "/" ]; do
    rest="/${d##*/}$rest"
    d="${d%/*}"
    [ -n "$d" ] || d="/"
  done
  real="$(cd -P "$d" 2>/dev/null && pwd -P)" || real="$d"
  abs="${real%/}$rest"
  [ -n "$abs" ] || abs="/"
  if [ "$abs" = "/" ]; then trail=""; fi
  printf '%s%s' "$abs" "$trail"
}

normalize_target() { # kind target
  local kind="$1" t="$2" top
  # タブと改行は書式を壊すので空白へ。
  t="$(printf '%s' "$t" | tr '\t\n\r' '   ')"
  case "$kind" in
    issue)
      t="${t#\#}"
      ;;
    doc)
      if [ -n "$t" ]; then
        t="$(normalize_path "$t")"
        case "$t" in
          "$TOPLEVEL"/*) t="${t#"$TOPLEVEL"/}" ;;
        esac
      fi
      ;;
    git)
      if [ -n "$t" ]; then t="$(normalize_path "$t")"; else t="$TOPLEVEL"; fi
      t="${t%/}"
      # 作業ツリーの下の階層を渡されても、その作業ツリーのルートへ揃える（cd した先や
      # git -C の先がサブディレクトリでも、同じ作業ツリーの登録と照合できるように）。
      if [ -d "$t" ]; then
        top="$(git -C "$t" rev-parse --show-toplevel 2>/dev/null)" || top=""
        if [ -n "$top" ]; then
          top="$(cd -P "$top" 2>/dev/null && pwd -P)" || top=""
          [ -n "$top" ] && t="$top"
        fi
      fi
      [ -n "$t" ] || t="/"
      ;;
  esac
  [ -n "$t" ] || t="-"
  printf '%s' "$t"
}

# ── 台帳の読み出し ────────────────────────────────────────────────────────────

# 1 セッションぶんのファイルを再生して、いま有効な登録を TSV で出す:
#   sid kind target pid worktree 最後の更新(epoch)
# 壊れた行は読み飛ばし、件数を警告する。
replay_file() { # file sid
  awk -v sid="$2" -v file="$1" '
    BEGIN { FS = "\t"; bad = 0; last = 0 }
    {
      if (NF < 6 || $1 !~ /^[0-9]+$/ || ($2 != "claim" && $2 != "release") || $5 !~ /^[0-9]+$/) { bad++; next }
      if ($1 + 0 > last) last = $1 + 0
      key = $3 "\034" $4
      if ($2 == "claim") {
        live[key] = 1; kind[key] = $3; tgt[key] = $4; pid[key] = $5; wt[key] = $6
        skey[key] = (NF >= 7 && $7 ~ /^[0-9]+$/) ? $7 : "-"
      } else if ($3 == "*") {
        for (x in live) delete live[x]
      } else if ($4 == "*") {
        for (x in live) if (kind[x] == $3) delete live[x]
      } else {
        delete live[key]
      }
    }
    END {
      for (x in live) printf "%s\t%s\t%s\t%s\t%s\t%d\t%s\n", sid, kind[x], tgt[x], pid[x], wt[x], last, skey[x]
      if (bad > 0) printf "[session-ledger] WARN: %s: 壊れた行を %d 件読み飛ばしました。\n", file, bad > "/dev/stderr"
    }
  ' "$1"
}

# 全セッションの有効な登録に、状態（live / expired）を付けて出す。
#   sid kind target pid worktree 最後の更新 age state
collect() {
  local f sid now ttl
  now="$(date +%s)"
  ttl="${SESSION_LEDGER_TTL:-28800}"
  case "$ttl" in '' | *[!0-9]*) ttl=28800 ;; esac
  for f in "$LEDGER_DIR"/*.tsv; do
    [ -e "$f" ] || continue
    sid="$(basename "$f" .tsv)"
    if [ ! -r "$f" ]; then
      warn "読めない台帳のファイルを読み飛ばします: $f"
      continue
    fi
    replay_file "$f" "$sid" | while IFS="$TAB" read -r a_sid a_kind a_tgt a_pid a_wt a_last a_key; do
      [ -n "$a_sid" ] || continue
      state="live"
      if ! pid_alive "$a_pid" "$a_key"; then
        state="expired"
      elif [ $((now - a_last)) -gt "$ttl" ]; then
        state="expired"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$a_sid" "$a_kind" "$a_tgt" "$a_pid" "$a_wt" "$a_last" "$((now - a_last))" "$state"
    done
  done
}

# ── 衝突の判定 ────────────────────────────────────────────────────────────────

target_matches() { # kind query claimed
  local kind="$1" q="$2" c="$3"
  case "$kind" in
    merge | gate) return 0 ;;
    doc)
      [ "$q" = "$c" ] && return 0
      # 末尾が / の登録は、その配下すべてを指す。どちらか一方がもう一方の配下なら
      # 衝突とする（登録の順序に依らない）。
      case "$c" in
        */)
          case "$q" in
            "$c"*) return 0 ;;
          esac
          ;;
      esac
      case "$q" in
        */)
          case "$c" in
            "$q"*) return 0 ;;
          esac
          ;;
      esac
      return 1
      ;;
    *) [ "$q" = "$c" ] ;;
  esac
}

print_coordinate() { # 自分の識別子を除いた相手の一覧を引数にとる
  echo "coordinate: 相手のセッション（$*）と調整してください。相手が release するか、登録が失効（持ち主の PID が消える、または一定時間更新が無い）するまで待ちます。どちらが譲るかは自動では決まりません。"
  echo "coordinate[claude-code]: ListAgents で相手のセッションを確かめ、SendMessage で連絡します。"
  echo "coordinate[other]: 上記以外の実行環境では、利用者へ相手のセッションと作業ツリーを伝え、調整を依頼します。"
}

# check の本体。標準出力へ判定を出し、DENY のとき 3 を返す。
do_check() { # kind target
  local kind="$1" target="$2" level out peers n rows
  level="$(level_of "$kind")"
  rows="$(collect)" || rows=""
  out=""
  peers=""
  n=0
  while IFS="$TAB" read -r r_sid r_kind r_tgt r_pid r_wt _ r_age r_state; do
    [ -n "$r_sid" ] || continue
    [ "$r_state" = "live" ] || continue
    [ "$r_sid" != "$SELF_ID" ] || continue
    [ "$r_kind" = "$kind" ] || continue
    target_matches "$kind" "$target" "$r_tgt" || continue
    n=$((n + 1))
    out="${out}conflict: session=$r_sid kind=$r_kind target=$r_tgt pid=$r_pid worktree=$r_wt age=${r_age}s"$'\n'
    peers="${peers:+$peers, }$r_sid"
  done <<EOF
$rows
EOF
  if [ "$n" -eq 0 ]; then
    echo "LEDGER_OK"
    return 0
  fi
  echo "LEDGER_$level"
  printf '%s' "$out"
  print_coordinate "$peers"
  [ "$level" = "DENY" ] && return 3
  return 0
}

append_record() { # op kind target
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "$SELF_PID" "$TOPLEVEL" "$SELF_KEY" \
    >>"$LEDGER_DIR/$SELF_ID.tsv" 2>/dev/null
}

# ── サブコマンド ──────────────────────────────────────────────────────────────

cmd_check() {
  local kind="${1:-}" target
  valid_kind "$kind" || { usage; return 2; }
  target="$(normalize_target "$kind" "${2:-}")"
  if owner_unknown; then
    echo "LEDGER_SKIP"
    return 0
  fi
  if ! ensure_dir; then
    echo "LEDGER_SKIP"
    return 0
  fi
  do_check "$kind" "$target"
}

cmd_claim() {
  local kind="${1:-}" target res rc
  valid_kind "$kind" || { usage; return 2; }
  target="$(normalize_target "$kind" "${2:-}")"
  if owner_unknown; then
    echo "LEDGER_SKIP"
    return 0
  fi
  if ! ensure_dir; then
    echo "LEDGER_SKIP"
    return 0
  fi
  res="$(do_check "$kind" "$target")"
  rc=$?
  if [ "$rc" -eq 3 ]; then
    # 拒否の種類は、衝突しているあいだは登録しない。登録すると相手も拒否される。
    printf '%s\n' "$res"
    return 3
  fi
  if ! append_record claim "$kind" "$target"; then
    warn "台帳へ書き込めませんでした。登録せず通します。"
    echo "LEDGER_SKIP"
    return 0
  fi
  printf '%s\n' "$res"
  echo "claimed: session=$SELF_ID kind=$kind target=$target"
  return 0
}

cmd_release() {
  local kind="${1:-*}" target="${2:-*}"
  if [ "$kind" != "*" ]; then
    valid_kind "$kind" || { usage; return 2; }
    [ "$target" = "*" ] || target="$(normalize_target "$kind" "$target")"
  fi
  owner_unknown && return 0
  if ! ensure_dir; then
    return 0
  fi
  # 自分のファイルが無ければ解放するものも無い。
  [ -e "$LEDGER_DIR/$SELF_ID.tsv" ] || return 0
  if ! append_record release "$kind" "$target"; then
    # 解放の行を書けなかった。登録は残っている。fail-open の方針なので終了コードは 0 のまま
    # にし、残っていることが出力から分かるようにする（失効するか、書けるようになった後の
    # release で消える）。
    warn "台帳へ書き込めませんでした。解放できていません（登録が残っています）。"
    echo "release-failed: session=$SELF_ID kind=$kind target=$target（登録は残っています）"
    return 0
  fi
  echo "released: session=$SELF_ID kind=$kind target=$target"
  return 0
}

cmd_list() {
  local mode="${1:-}" rows
  case "$mode" in '' | --others | --all) ;; *) usage; return 2 ;; esac
  ensure_dir || return 0
  rows="$(collect)" || rows=""
  while IFS="$TAB" read -r r_sid r_kind r_tgt r_pid r_wt _ r_age r_state; do
    [ -n "$r_sid" ] || continue
    if [ "$mode" != "--all" ] && [ "$r_state" != "live" ]; then continue; fi
    if [ "$mode" = "--others" ] && [ "$r_sid" = "$SELF_ID" ]; then continue; fi
    echo "session=$r_sid kind=$r_kind target=$r_tgt pid=$r_pid worktree=$r_wt age=${r_age}s state=$r_state"
  done <<EOF
$rows
EOF
  return 0
}

main() {
  local sub="${1:-}"
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    claim) cmd_claim "$@" ;;
    release) cmd_release "$@" ;;
    list) cmd_list "$@" ;;
    check) cmd_check "$@" ;;
    *) usage; return 2 ;;
  esac
}

# source ガード。読み込まれただけのときは関数定義だけを提供する。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
  exit $?
fi
