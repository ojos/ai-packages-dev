#!/usr/bin/env bash
# session-coord-hook.sh — 並行セッションの共有台帳を、操作の直前に確かめるフック（Claude Code 用）。
#
# 規範は .ai-playbook/shared-ai-rules.md「セッション間の協調」。台帳の読み書きと衝突の判定は
# scripts/session-ledger.sh が担い、このフックは「いつ確かめるか」と「Claude Code へどう返すか」
# だけを持つ。判定基準（止める強さ）をここへ複製しない。
#
# ── 配線（.claude/settings.json）─────────────────────────────────────────────
#
#   SessionStart                      他セッションの登録を要約して表示する。
#   PreToolUse   (Bash)               マージ・リリース、作業ツリーでの git 操作、重いゲートの
#                                     起動を見つけたら、台帳へ登録しながら確かめる。他のセッション
#                                     と衝突すれば拒否（deny）する。issue への着手（ブランチ作成）
#                                     は重複を警告する。
#   PreToolUse   (Edit|Write)         他セッションが登録している文書なら警告する（通す）。
#   PostToolUse / PostToolUseFailure  (Bash)
#                                     PreToolUse で登録した「実行のあいだだけ」の登録を解放する。
#                                     失敗した呼び出し（終了コード 0 以外・中断）は PostToolUse では
#                                     なく PostToolUseFailure が来るため、両方へ配線する。
#   SessionEnd                        自分の登録をすべて解放する。
#
# ── 判定 ──────────────────────────────────────────────────────────────────────
#
#   コマンド                                                  登録の種類・対象        強さ
#   gh pr merge / gh release create|edit|delete|upload /      merge                   拒否
#     gh api の merge エンドポイントへの PUT / mergePullRequest
#   git checkout|switch|rebase|reset|fetch|pull|merge|        git（作業ツリー）       拒否
#     cherry-pick|revert|stash|restore|clean|am
#   verify.sh / loop-gate.sh                                  gate                    拒否
#   git checkout -b / git switch -c / git worktree add -b     issue（ブランチ名の     警告
#     / gh issue develop（ブランチ名が番号で始まる場合）       先頭の番号）
#   Edit / Write の対象ファイル                               doc（確かめるだけ）     警告
#
# 拒否は permissionDecision の deny、警告は additionalContext（モデルへ）と systemMessage
# （利用者へ）で返す。相手の識別子・登録の種類・調整の手順は、台帳の出力をそのまま添える。
#
# ── 自分で登録する時点 ────────────────────────────────────────────────────────
#
#   - merge / git / gate: 実行の直前（PreToolUse）に登録し、実行が終わったら（PostToolUse）
#     解放する（失敗した呼び出しは PostToolUseFailure で解放する）。「実行する間は登録する」
#     （規範）を、実行のあいだに限って機構が担う。拒否したときは、その呼び出しで登録した
#     ものを解放してから拒否する（issue は、拒否しないと決まってから登録する）。
#     限界: 利用者が確認（ask）を断った場合は、どちらも来ないため、次に同じ種類の操作を
#     通すか、セッションが終わる（SessionEnd）か、持ち主が消えるまで登録が残る。
#     同じセッションで同じ種類の Bash 呼び出しが並行すると、先に終わった方が解放する
#     （台帳の対象は git では作業ツリーの等値比較、merge / gate では無視されるため、
#     呼び出しごとの tool_use_id を対象へ入れて区別することはできない）。
#     バックグラウンドで起動したゲートは、起動の呼び出しが返った時点で解放される。
#   - issue: ブランチ作成の時点で登録し、SessionEnd まで持つ。
#   - doc: フックは登録しない（確かめるだけ）。長く触る文書は、セッション自身が
#     `session-ledger.sh claim doc <パス>` で登録する。編集のたびに登録すると警告が常時出る。
#
# 長いセッションの失効を避けるため、PreToolUse（Bash・Edit|Write）のたびに
# `session-ledger.sh refresh` を呼ぶ（前回の更新から一定時間たっていなければ何もしない）。
#
# ── セッションの識別子 ────────────────────────────────────────────────────────
#
# 台帳の既定（祖先で最初のシェル以外のプロセス）に任せる。フックも Bash ツールのコマンドも
# Claude Code 本体の子として動くため、同じ識別子になる。環境変数 SESSION_LEDGER_ID /
# SESSION_LEDGER_PID を渡せば、台帳と同じくそれが優先される。
#
# ── fail-open ────────────────────────────────────────────────────────────────
#
# 台帳そのものの読み書きに失敗したとき（台帳が見つからない・置き場所を作れない・出力が読めない）
# は、警告（systemMessage）を出して通す。台帳の不具合で、すべての操作を止めない。
# 確認フック（confirm-merge-hook.sh）が空のペイロードを fail-closed にするのとは逆である。
# あちらは承認の記録が目的で、こちらは合図だからである。
#
# ── コマンドの見分け方 ────────────────────────────────────────────────────────
#
# confirm-merge-hook.sh と同じ考え方で、クォートを認識して ; & | ( ) ` と改行でコマンド節に
# 分け、節の先頭（環境変数の代入と制御語を読み飛ばした位置）のコマンドで判定する。文字列に
# 含まれるだけ（echo / grep の引数・コミットメッセージ）では反応しない。ヒアドキュメントの本体は
# 読み飛ばす。cd で動いた先は、同じコマンド内の続く節に反映する。
# 部分実装であり、取りこぼしうる（bash -c "..." の中身、変数展開・コマンド置換の結果など）。
# 意図的な迂回を防ぐ境界ではなく、うっかりの衝突に合図を出す機構である。
#
# 終了コード: 常に 0。判定は標準出力の JSON で伝える。
#
# bash 3.2 互換（連想配列・mapfile を使わない）。
set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LEDGER="$HOOK_DIR/session-ledger.sh"
US=$'\x1f'

# 台帳の警告などを集め、最後に systemMessage として 1 回で返す。
WARNS=""
add_warn() {
  case "$WARNS" in *"$1"*) return 0 ;; esac
  WARNS="${WARNS:+$WARNS$'\n'}$1"
}

# ── JSON の読み書き（jq が無くても動く）──────────────────────────────────────

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

json_get() { # key（payload の中の文字列値。入れ子は区別しない）
  local key="$1" v
  if [[ "$HAVE_JQ" -eq 1 ]]; then
    case "$key" in
      command | file_path | notebook_path) v="$(printf '%s' "$payload" | jq -r ".tool_input.$key // empty" 2>/dev/null)" ;;
      *) v="$(printf '%s' "$payload" | jq -r ".$key // empty" 2>/dev/null)" ;;
    esac
    printf '%s' "$v"
    return 0
  fi
  v="$(printf '%s\n' "$payload" | sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\".*/\\1/p" | sed -n 1p)"
  v="${v//\\\\/$'\x01'}"
  v="${v//\\\"/\"}"
  v="${v//\\n/$'\n'}"
  v="${v//\\t/ }"
  v="${v//$'\x01'/\\}"
  printf '%s' "$v"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

# emit <event> <decision> <reason> <context> <systemMessage>。出すものが無ければ何も出さない。
# hookSpecificOutput は、決定か追加の文脈があるときだけ付ける。
emit() {
  local ev="$1" dec="$2" reason="$3" ctx="$4" sys="$5" hs="" out=""
  [[ -n "$dec$ctx$sys" ]] || return 0
  if [[ "$HAVE_JQ" -eq 1 ]]; then
    jq -n --arg ev "$ev" --arg dec "$dec" --arg reason "$reason" --arg ctx "$ctx" --arg sys "$sys" '
      (if $dec != "" or $ctx != "" then
         {hookSpecificOutput: ({hookEventName: $ev}
           + (if $dec != "" then {permissionDecision: $dec, permissionDecisionReason: $reason} else {} end)
           + (if $ctx != "" then {additionalContext: $ctx} else {} end))}
       else {} end)
      + (if $sys != "" then {systemMessage: $sys} else {} end)'
    return 0
  fi
  if [[ -n "$dec" || -n "$ctx" ]]; then
    hs="\"hookEventName\":\"$ev\""
    [[ -z "$dec" ]] || hs="$hs,\"permissionDecision\":\"$dec\",\"permissionDecisionReason\":\"$(json_escape "$reason")\""
    [[ -z "$ctx" ]] || hs="$hs,\"additionalContext\":\"$(json_escape "$ctx")\""
    out="\"hookSpecificOutput\":{$hs}"
  fi
  if [[ -n "$sys" ]]; then
    out="${out:+$out,}\"systemMessage\":\"$(json_escape "$sys")\""
  fi
  printf '{%s}\n' "$out"
}

# ── 台帳の呼び出し ────────────────────────────────────────────────────────────

LEDGER_OUT=""
LEDGER_VERDICT=""
LEDGER_DETAIL=""

# run_ledger <作業ディレクトリ> <台帳の引数...>。判定は LEDGER_VERDICT（LEDGER_OK / WARN / DENY /
# SKIP）、2 行目以降は LEDGER_DETAIL。台帳が読めない・壊れているときは SKIP にして、警告を足す。
run_ledger() {
  local dir="$1" errf="" err="" rc
  shift
  LEDGER_OUT=""
  LEDGER_VERDICT="LEDGER_SKIP"
  LEDGER_DETAIL=""
  if [[ ! -f "$LEDGER" ]]; then
    add_warn "[session-coord] 台帳のスクリプトが見つかりません（$LEDGER）。台帳を確かめずに通します。"
    return 0
  fi
  errf="$(mktemp "${TMPDIR:-/tmp}/session-coord.XXXXXX" 2>/dev/null)" || errf=""
  if [[ -n "$errf" ]]; then
    LEDGER_OUT="$( (cd "$dir" 2>/dev/null || cd "$cwd" 2>/dev/null || true; bash "$LEDGER" "$@") 2>"$errf")"
    rc=$?
    err="$(cat "$errf" 2>/dev/null)"
    rm -f "$errf"
  else
    LEDGER_OUT="$( (cd "$dir" 2>/dev/null || cd "$cwd" 2>/dev/null || true; bash "$LEDGER" "$@") 2>/dev/null)"
    rc=$?
  fi
  [[ -z "$err" ]] || add_warn "$err"
  # 解放の行を書けなかったとき、台帳は終了コード 0 で「release-failed: …（登録は残っています）」
  # を出す。実行は止めないが、登録が残ったことを利用者へ知らせる（systemMessage）。
  case "$LEDGER_OUT" in
    *release-failed*)
      add_warn "[session-coord] 登録を解放できませんでした。登録は残っています（持ち主が消える、または一定時間更新が無いと失効します）。"
      ;;
  esac
  LEDGER_VERDICT="${LEDGER_OUT%%$'\n'*}"
  case "$LEDGER_VERDICT" in
    LEDGER_OK | LEDGER_WARN | LEDGER_DENY | LEDGER_SKIP) ;;
    *)
      # refresh / release / list は判定の行を持たない。出力があれば、そのまま詳細として返す。
      if [[ "$rc" -ne 0 && "$rc" -ne 3 ]]; then
        add_warn "[session-coord] 台帳の出力を読めませんでした（終了コード $rc）。台帳を確かめずに通します。"
        LEDGER_VERDICT="LEDGER_SKIP"
      else
        LEDGER_VERDICT="LEDGER_OK"
      fi
      LEDGER_DETAIL="$LEDGER_OUT"
      return 0
      ;;
  esac
  if [[ "$LEDGER_OUT" == *$'\n'* ]]; then
    LEDGER_DETAIL="${LEDGER_OUT#*$'\n'}"
  fi
  if [[ "$LEDGER_VERDICT" == "LEDGER_SKIP" ]]; then
    add_warn "[session-coord] 台帳を読み書きできませんでした。台帳を確かめずに通します。"
  fi
  return 0
}

# 失効を避けるための更新。台帳が使えなくても警告は出さない（実際の登録・確認の時点で出る）。
refresh_ledger() {
  local saved="$WARNS"
  run_ledger "$1" refresh
  WARNS="$saved"
}

# ── コマンドの字句解析（confirm-merge-hook.sh と同じ考え方の縮小版）──────────

CLAUSES=()

# ヒアドキュメントの本体を取り除く。
strip_heredocs() {
  local text="$1" line delim="" t out="" re
  re="(^|[^<])<<-?[[:space:]]*['\"]?([A-Za-z_][A-Za-z0-9_]*)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -n "$delim" ]]; then
      t="${line#"${line%%[!$'\t']*}"}"
      [[ "$t" == "$delim" ]] && delim=""
      continue
    fi
    out="$out$line"$'\n'
    if [[ "$line" =~ $re ]]; then
      delim="${BASH_REMATCH[2]}"
    fi
  done <<<"$text"
  printf '%s' "$out"
}

# クォートを認識して、コマンド節（語を $US でつないだ文字列）の配列 CLAUSES を作る。
scan_clauses() {
  local text="$1" i n c word="" have=0 sq=0 dq=0 cur="" nx
  CLAUSES=()
  n=${#text}
  for ((i = 0; i < n; i++)); do
    c="${text:i:1}"
    if [[ $sq -eq 1 ]]; then
      if [[ "$c" == "'" ]]; then sq=0; else word+="$c"; fi
      continue
    fi
    if [[ $dq -eq 1 ]]; then
      if [[ "$c" == '"' ]]; then
        dq=0
      elif [[ "$c" == $'\\' ]]; then
        i=$((i + 1))
        word+="${text:i:1}"
      else
        word+="$c"
      fi
      continue
    fi
    case "$c" in
      "'") sq=1; have=1 ;;
      '"') dq=1; have=1 ;;
      $'\\')
        nx="${text:i+1:1}"
        if [[ "$nx" == $'\n' ]]; then
          i=$((i + 1))
        else
          i=$((i + 1))
          word+="$nx"
          have=1
        fi
        ;;
      ' ' | $'\t')
        if [[ $have -eq 1 ]]; then cur="${cur:+$cur$US}$word"; word=""; have=0; fi
        ;;
      ';' | '&' | '|' | '(' | ')' | '`' | $'\n')
        if [[ $have -eq 1 ]]; then cur="${cur:+$cur$US}$word"; word=""; have=0; fi
        if [[ -n "$cur" ]]; then CLAUSES[${#CLAUSES[@]}]="$cur"; cur=""; fi
        ;;
      *) word+="$c"; have=1 ;;
    esac
  done
  if [[ $have -eq 1 ]]; then cur="${cur:+$cur$US}$word"; fi
  if [[ -n "$cur" ]]; then CLAUSES[${#CLAUSES[@]}]="$cur"; fi
}

# 分類の結果。
HIT_MERGE=0
HIT_GATE=0
HIT_GIT_DIRS=""   # 改行区切り。作業ツリーのパス
HIT_ISSUES=""     # 空白区切り。issue 番号

toplevel_of() { # 基準ディレクトリ 相対ディレクトリ
  local base="$1" rel="$2" top=""
  top="$( (cd "$base" 2>/dev/null && { [[ -z "$rel" ]] || cd "$rel" 2>/dev/null; } && git rev-parse --show-toplevel 2>/dev/null) || true)"
  [[ -n "$top" ]] || top="$base"
  printf '%s' "$top"
}

add_git_dir() {
  # 行単位の完全一致で重複を除く（/repo2 を見ているときに /repo を落とさない）。
  case $'\n'"$HIT_GIT_DIRS"$'\n' in
    *$'\n'"$1"$'\n'*) ;;
    *) HIT_GIT_DIRS="${HIT_GIT_DIRS:+$HIT_GIT_DIRS$'\n'}$1" ;;
  esac
}

add_issue() {
  case " $HIT_ISSUES " in
    *" $1 "*) ;;
    *) HIT_ISSUES="${HIT_ISSUES:+$HIT_ISSUES }$1" ;;
  esac
}

# ブランチ名の先頭の番号（feat/395-x・395-x・fix/issue-12-x）を issue 番号とみなす。
issue_from_branch() {
  local b="$1" re
  re='(^|/)(issue-|gh-)?([1-9][0-9]{0,5})([-_]|$)'
  if [[ "$b" =~ $re ]]; then
    add_issue "${BASH_REMATCH[3]}"
  fi
}

# W 配列の k 番目以降から、オプションを読み飛ばして最初の位置引数を返す（番号で）。
first_positional() { # 開始位置。結果は POS_IDX
  local j="$1" n=${#W[@]} w
  POS_IDX=-1
  while [[ $j -lt $n ]]; do
    w="${W[$j]}"
    case "$w" in
      -R | --repo | --hostname | -C | -c) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) POS_IDX=$j; return 0 ;;
    esac
  done
  return 0
}

classify_gh() { # k（gh の位置）
  local k="$1" j n=${#W[@]} w p1="" p2="" joined put_re
  j=$((k + 1))
  while [[ $j -lt $n ]]; do
    w="${W[$j]}"
    case "$w" in
      -R | --repo | --hostname) j=$((j + 2)); continue ;;
      -*) j=$((j + 1)); continue ;;
    esac
    if [[ -z "$p1" ]]; then p1="$w"; elif [[ -z "$p2" ]]; then p2="$w"; j=$((j + 1)); break; fi
    j=$((j + 1))
  done
  case "$p1:$p2" in
    pr:merge) HIT_MERGE=1 ;;
    release:create | release:edit | release:delete | release:upload | release:delete-asset) HIT_MERGE=1 ;;
    issue:develop)
      # 次の位置引数が issue 番号。
      first_positional "$j"
      if [[ $POS_IDX -ge 0 && "${W[$POS_IDX]}" =~ ^[1-9][0-9]*$ ]]; then add_issue "${W[$POS_IDX]}"; fi
      ;;
    api:*)
      joined="${W[*]}"
      put_re='(--method(=|[[:space:]]+)|-X[[:space:]]*)[Pp][Uu][Tt]([^A-Za-z0-9_-]|$)'
      if [[ "$joined" =~ pulls/[^[:space:]]*/merge ]] && [[ "$joined" =~ $put_re ]]; then
        HIT_MERGE=1
      elif [[ "$joined" == *graphql* && "$CMD_TEXT" == *mergePullRequest* ]]; then
        HIT_MERGE=1
      fi
      ;;
  esac
}

classify_git() { # k（git の位置）
  local k="$1" j n=${#W[@]} w dir="" sub="" next
  j=$((k + 1))
  while [[ $j -lt $n ]]; do
    w="${W[$j]}"
    case "$w" in
      -C) dir="${W[$((j + 1))]:-}"; j=$((j + 2)) ;;
      -c | --git-dir | --work-tree | --namespace | --exec-path) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) sub="$w"; break ;;
    esac
  done
  [[ -n "$sub" ]] || return 0
  case "$sub" in
    checkout | switch | rebase | reset | fetch | pull | merge | cherry-pick | revert | restore | clean | am)
      add_git_dir "$(toplevel_of "$CUR_DIR" "$dir")"
      ;;
    stash)
      next="${W[$((j + 1))]:-}"
      case "$next" in list | show) ;; *) add_git_dir "$(toplevel_of "$CUR_DIR" "$dir")" ;; esac
      ;;
  esac
  # ブランチの作成から、着手した issue を読む。
  j=$((j + 1))
  while [[ $j -lt $n ]]; do
    w="${W[$j]}"
    case "$sub:$w" in
      checkout:-b | checkout:-B | switch:-c | switch:-C | switch:--create | switch:--force-create | worktree:-b | worktree:-B)
        issue_from_branch "${W[$((j + 1))]:-}"
        ;;
    esac
    j=$((j + 1))
  done
}

CUR_DIR=""

classify_clause() {
  local clause="$1" k=0 n w base
  IFS="$US" read -r -a W <<<"$clause"
  n=${#W[@]}
  while [[ $k -lt $n ]]; do
    w="${W[$k]}"
    if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      k=$((k + 1))
      continue
    fi
    case "$w" in
      if | then | do | else | elif | while | until | '!' | '{' | time | env | command | exec | nohup | sudo) k=$((k + 1)) ;;
      *) break ;;
    esac
  done
  [[ $k -lt $n ]] || return 0
  base="${W[$k]##*/}"
  case "$base" in
    cd)
      first_positional $((k + 1))
      if [[ $POS_IDX -ge 0 ]]; then
        case "${W[$POS_IDX]}" in
          /*) CUR_DIR="${W[$POS_IDX]}" ;;
          -) ;;
          *) CUR_DIR="$CUR_DIR/${W[$POS_IDX]}" ;;
        esac
      fi
      ;;
    gh) classify_gh "$k" ;;
    git) classify_git "$k" ;;
    verify.sh | loop-gate.sh) HIT_GATE=1 ;;
    bash | sh)
      first_positional $((k + 1))
      if [[ $POS_IDX -ge 0 ]]; then
        case "${W[$POS_IDX]##*/}" in verify.sh | loop-gate.sh) HIT_GATE=1 ;; esac
      fi
      ;;
  esac
}

CMD_TEXT=""
classify_command() { # コマンド文字列、基準ディレクトリ
  local text="$1" clause
  HIT_MERGE=0
  HIT_GATE=0
  HIT_GIT_DIRS=""
  HIT_ISSUES=""
  CUR_DIR="$2"
  # 見るべき語が無ければ、解析しない。
  case "$text" in
    *git* | *gh* | *verify* | *loop-gate*) ;;
    *) return 0 ;;
  esac
  CMD_TEXT="$text"
  scan_clauses "$(strip_heredocs "$text")"
  for clause in ${CLAUSES[@]+"${CLAUSES[@]}"}; do
    classify_clause "$clause"
  done
}

# ── 判定の整形 ────────────────────────────────────────────────────────────────

# 拒否・警告の本文。台帳の出力（conflict: 行と coordinate 行）をそのまま添える。
deny_text() { # 操作の説明 詳細
  printf '%s\n%s\n%s' \
    "[session-coord] 拒否: ${1}は、他のセッションの登録と衝突します。実行しません。" \
    "$2" \
    "相手が release する、または登録が失効するまで待ってください。登録を消して迂回しないでください（調整の手順は上の coordinate の行）。"
}

warn_text() { # 内容 詳細
  printf '%s\n%s\n%s' \
    "[session-coord] 警告: ${1}" \
    "$2" \
    "連絡のうえで進めてください。拒否ではないため、このまま実行されます。"
}

DECISION=""
REASON=""
CONTEXT=""

# ── イベントごとの処理 ────────────────────────────────────────────────────────

on_session_start() {
  local rows n
  run_ledger "$cwd" list --others
  rows="$LEDGER_DETAIL"
  [[ "$LEDGER_VERDICT" != "LEDGER_SKIP" && -n "$rows" ]] || return 0
  n="$(printf '%s\n' "$rows" | grep -c .)"
  CONTEXT="$(printf '%s\n%s\n%s\n%s' \
    "[session-coord] 同じホストで動いている他のセッションの登録が ${n} 件あります。" \
    "$rows" \
    "同じ issue への着手・登録済みの文書の編集は警告、マージ・同じ作業ツリーでの git 操作・重いゲートの起動は、登録が残っている間は拒否されます。" \
    "調整は、Claude Code では ListAgents で相手を確かめて SendMessage で連絡します（他の実行環境では利用者を経由します）。着手する issue は scripts/session-ledger.sh claim issue <番号> で登録します。")"
}

on_session_end() {
  run_ledger "$cwd" release
}

pre_bash() {
  local d denies="" warns="" claimed_merge=0 claimed_gate=0 claimed_dirs="" n
  [[ -n "$cmd" ]] || return 0
  refresh_ledger "$cwd"
  classify_command "$cmd" "$cwd"
  # 衝突の確認に関係しないコマンドでは、これ以上台帳を呼ばない。
  [[ $HIT_MERGE -eq 1 || $HIT_GATE -eq 1 || -n "$HIT_GIT_DIRS" || -n "$HIT_ISSUES" ]] || return 0

  if [[ $HIT_MERGE -eq 1 ]]; then
    run_ledger "$cwd" claim merge
    case "$LEDGER_VERDICT" in
      LEDGER_DENY) denies="${denies:+$denies$'\n'}$(deny_text 'マージ・リリース' "$LEDGER_DETAIL")" ;;
      LEDGER_OK | LEDGER_WARN) claimed_merge=1 ;;
    esac
  fi
  if [[ $HIT_GATE -eq 1 ]]; then
    run_ledger "$cwd" claim gate
    case "$LEDGER_VERDICT" in
      LEDGER_DENY) denies="${denies:+$denies$'\n'}$(deny_text '重いゲート（verify / loop-gate）の起動' "$LEDGER_DETAIL")" ;;
      LEDGER_OK | LEDGER_WARN) claimed_gate=1 ;;
    esac
  fi
  if [[ -n "$HIT_GIT_DIRS" ]]; then
    while IFS= read -r d; do
      [[ -n "$d" ]] || continue
      run_ledger "$d" claim git "$d"
      case "$LEDGER_VERDICT" in
        LEDGER_DENY) denies="${denies:+$denies$'\n'}$(deny_text "作業ツリー（$d）での git 操作" "$LEDGER_DETAIL")" ;;
        LEDGER_OK | LEDGER_WARN) claimed_dirs="${claimed_dirs:+$claimed_dirs$'\n'}$d" ;;
      esac
    done <<EOF
$HIT_GIT_DIRS
EOF
  fi
  if [[ -n "$denies" ]]; then
    # 実行しないので、この呼び出しで登録したものを解放する（PostToolUse は来ない）。
    [[ $claimed_merge -eq 0 ]] || run_ledger "$cwd" release merge
    [[ $claimed_gate -eq 0 ]] || run_ledger "$cwd" release gate
    if [[ -n "$claimed_dirs" ]]; then
      while IFS= read -r d; do
        [[ -n "$d" ]] && run_ledger "$d" release git "$d"
      done <<EOF
$claimed_dirs
EOF
    fi
    DECISION="deny"
    REASON="$denies"
    return 0
  fi
  # issue は、実行を拒否しないと決まってから登録する（拒否した呼び出しで登録を残さない）。
  for n in $HIT_ISSUES; do
    run_ledger "$cwd" claim issue "$n"
    if [[ "$LEDGER_VERDICT" == "LEDGER_WARN" ]]; then
      warns="${warns:+$warns$'\n'}$(warn_text "issue #$n には、他のセッションが着手しています。" "$LEDGER_DETAIL")"
    fi
  done
  [[ -z "$warns" ]] || CONTEXT="$warns"
}

post_bash() {
  local d
  [[ -n "$cmd" ]] || return 0
  classify_command "$cmd" "$cwd"
  [[ $HIT_MERGE -eq 1 ]] && run_ledger "$cwd" release merge
  [[ $HIT_GATE -eq 1 ]] && run_ledger "$cwd" release gate
  if [[ -n "$HIT_GIT_DIRS" ]]; then
    while IFS= read -r d; do
      [[ -n "$d" ]] && run_ledger "$d" release git "$d"
    done <<EOF
$HIT_GIT_DIRS
EOF
  fi
  return 0
}

pre_edit() {
  local path dir
  path="$fpath"
  [[ -n "$path" ]] || return 0
  dir="$(dirname "$path")"
  refresh_ledger "$dir"
  run_ledger "$dir" check doc "$path"
  if [[ "$LEDGER_VERDICT" == "LEDGER_WARN" ]]; then
    CONTEXT="$(warn_text "他のセッションが登録している文書（$path）を編集しようとしています。" "$LEDGER_DETAIL")"
  fi
}

# ── 本体 ──────────────────────────────────────────────────────────────────────

payload="$(cat)"
if [[ -z "$payload" ]]; then
  add_warn "[session-coord] フックへ届いたペイロードが空でした。台帳を確かめずに通します。"
  emit "" "" "" "" "$WARNS"
  exit 0
fi

event="$(json_get hook_event_name)"
tool="$(json_get tool_name)"
cmd="$(json_get command)"
fpath="$(json_get file_path)"
[[ -n "$fpath" ]] || fpath="$(json_get notebook_path)"
cwd="$(json_get cwd)"
if [[ -z "$cwd" || ! -d "$cwd" ]]; then cwd="$(pwd)"; fi

case "$event" in
  SessionStart) on_session_start ;;
  SessionEnd) on_session_end ;;
  PreToolUse)
    case "$tool" in
      Bash) pre_bash ;;
      Edit | Write | MultiEdit | NotebookEdit) pre_edit ;;
    esac
    ;;
  PostToolUse | PostToolUseFailure)
    [[ "$tool" != "Bash" ]] || post_bash
    ;;
esac

SYS="$WARNS"
if [[ -n "$CONTEXT" && "$DECISION" != "deny" ]]; then
  SYS="${SYS:+$SYS$'\n'}$CONTEXT"
fi
case "$event" in
  SessionStart | PreToolUse | PostToolUse | PostToolUseFailure) emit "$event" "$DECISION" "$REASON" "$CONTEXT" "$SYS" ;;
  *) emit "$event" "" "" "" "$WARNS" ;;
esac
exit 0
