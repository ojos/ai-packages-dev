#!/usr/bin/env bash
# dev — SSH で届く外部の機械に置く入口の道具。devcontainer を起こし、入る。
#
# 外部の機械へは `~/.local/bin/dev` として置く（導入の手順は README.md）。端末からは
# `ssh -t <ホスト> .local/bin/dev attach <名前>` の 1 行をショートカットにして叩く。
#
# ## 使い方
#
#   dev ls                     登録したプロジェクトの状態を並べる
#   dev up <名前>               devcontainer を起こす（在れば何もしない）
#   dev attach <名前>           コンテナの中の tmux に入る（無ければ作る）
#   dev supervise <名前>        起こして止まるまで待つ（systemd のユニットから使う）
#   dev rebuild <名前> [--pull] コンテナを作り直す（ユニットを止めて、作り直して、起こし直す）
#   dev doctor <名前>           「動いているのに入れない」を見分ける（exec・pids・ゾンビ・OOM・ユニット）
#   dev restart <名前>          作り直さずに再起動する（ユニットを止めて、docker restart して、起こし直す）
#   dev stop <名前>             意図して止める（ユニットを先に止めてから、コンテナを止める）
#   dev logs <名前> [-n <行数>]  ユニットのログの末尾（既定 50 行）
#   dev enable <名前>           ユニットを有効にして起こす（起動時から保つ）
#   dev disable <名前>          ユニットを無効にして止める（コンテナは止めない）
#   dev exec <名前> -- <コマンド...>  tmux を介さずにコンテナの中でコマンドを 1 つ実行する
#   dev self-update [--version <vX.Y.Z>]  dev 自身を DCB の公開リリースの版へ置き換える
#   dev help [サブコマンド]      サブコマンドごとの説明（正本はこのファイルの help_* 関数）
#
# ## プロジェクトの一覧
#
# **名前とパスはこの道具に書かない。** 外部の機械の設定ファイルから読む（既定は
# `${XDG_CONFIG_HOME:-$HOME/.config}/dev/projects`。`DEV_PROJECTS_FILE` で差し替えられる）。
# 書式は projects.example にある。1 行 1 プロジェクトで、空白区切りの
# `名前 絶対パス [キー=値 ...]`。キーは次の 1 つだけを受け付ける（綴りの誤りを黙って
# 無視しないため、知らないキーは設定の誤りとして止まる）。
#
#   tmux_session=<t>     `dev attach` が入る tmux のセッション名（既定 main）
#
# ## 起動の口を devcontainer CLI に揃える理由
#
# compose 方式でもイメージ方式でも `devcontainer up --workspace-folder` の 1 つの口で起こせ、
# VS Code の「Reopen in Container」と同じラベル（devcontainer.local_folder）でコンテナを
# 探すので、VS Code で作ったコンテナにもそのまま入れる。**各プロジェクトの compose や
# devcontainer.json は書き換えない**（同じ定義を使う別の端末の挙動を変えないため）。
#
# ## しないこと
#
# - **tmux と、その中のエージェントを自動で起こさない。** 自動で戻すのはコンテナまで
#   （systemd のユニット dev-up@.service）。tmux は `dev attach` が手で起こす。
# - **特定のクラウドへの認証を持たない。** 認証はコンテナの中で手で行う。`dev attach` で
#   入ったあとのシェルで、プロジェクトが使う CLI（aws / gcloud 等）を直接叩く。
#
# 終了コード: 0 = 成功 / 1 = 実行の失敗（コンテナが無い・下の道具が失敗した）/
#             2 = 使い方か設定ファイルの誤り（未登録の名前を含む）/
#             3 = dev doctor が警告だけを出した（doctor 以外は 3 で終わらない）
#             （dev exec だけは、コンテナの中のコマンドの終了コードをそのまま返す）
set -euo pipefail

PROG="dev"
DEFAULT_TMUX_SESSION="main"

# ssh の非対話のコマンド（`ssh <ホスト> .local/bin/dev ...`）と systemd のユーザーのユニットは
# ~/.profile を読まないので、~/.local/bin などが PATH に無い。devcontainer CLI の既定の置き場所
# （公式の install.sh は ~/.devcontainers/bin）と ~/.local/bin を**末尾へ**足す（先に在る PATH を優先する）。
PATH="$PATH:$HOME/.devcontainers/bin:$HOME/.local/bin"

# dev doctor が読む /proc と cgroup の根。既定は本物のパスで、自己試験が偽の木へ差し替える。
PROC_ROOT="${DEV_PROC_ROOT:-/proc}"
CGROUP_ROOT="${DEV_CGROUP_ROOT:-/sys/fs/cgroup}"

die() { echo "[$PROG] $*" >&2; exit 1; }
usage_error() { echo "[$PROG] $*" >&2; exit 2; }

usage() {
  cat <<'EOF'
使い方:
  dev ls
  dev up <名前>
  dev attach <名前>
  dev supervise <名前>      （systemd のユニット dev-up@.service から使う）
  dev rebuild <名前> [--pull]
  dev doctor <名前>
  dev restart <名前>
  dev stop <名前>
  dev logs <名前> [-n <行数>]
  dev enable <名前>
  dev disable <名前>
  dev exec <名前> -- <コマンド...>
  dev self-update [--version <vX.Y.Z>]
  dev help [サブコマンド]

サブコマンドごとの説明は dev help <サブコマンド>。
EOF
  # 設定ファイルのパスは機械ごとに変わるので、ここで展開して出す（説明文の正本 help_* には入れない）。
  printf 'プロジェクトの一覧は %s から読む。\n' "$(projects_file)"
}

projects_file() {
  if [[ -n "${DEV_PROJECTS_FILE:-}" ]]; then
    printf '%s\n' "$DEV_PROJECTS_FILE"
  else
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/dev/projects"
  fi
}

# ── 設定ファイル ──────────────────────────────────────────────────────────────
# 読んだ結果は並びの配列に置く（連想配列を使わないのは、macOS の bash 3.2 でも
# 自己試験が読めるようにするため）。
P_NAMES=()
P_PATHS=()
P_TMUX=()

load_projects() {
  local file lineno=0 line name path kv key val i
  local tmux_s
  file="$(projects_file)"
  if [[ ! -f "$file" ]]; then
    usage_error "設定ファイルがありません: $file
[$PROG] 雛形（projects.example）を写して、名前と絶対パスを 1 行ずつ書いてください。"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    # 行末の CR（Windows の改行で保存したとき）と、# 以降のコメントを外す。
    line="${line%$'\r'}"
    line="${line%%#*}"
    # 空白で語に分けるのが書式そのもの。glob の展開は set -f で止める。
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    [[ $# -gt 0 ]] || continue
    if [[ $# -lt 2 ]]; then
      usage_error "$file:$lineno: 「名前 絶対パス」の 2 つが要ります: $line"
    fi
    name="$1" path="$2"
    shift 2
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
      usage_error "$file:$lineno: 名前に使えるのは英数字と _ . - だけです（systemd のインスタンス名にもなるため）: $name"
    fi
    if [[ "$path" != /* ]]; then
      usage_error "$file:$lineno: パスは絶対パスで書きます（~ や \$HOME は展開しません）: $path"
    fi
    # 末尾の / を外す。devcontainer はラベル（devcontainer.local_folder）に / の無い形を
    # 書くので、/ 付きのまま照合すると、動いているコンテナを「無い」と取り違える。
    while [[ "$path" == */ && "$path" != / ]]; do path="${path%/}"; done
    for ((i = 0; i < ${#P_NAMES[@]}; i++)); do
      [[ "${P_NAMES[$i]}" == "$name" ]] && usage_error "$file:$lineno: 名前が重複しています: $name"
    done
    tmux_s="$DEFAULT_TMUX_SESSION"
    for kv in "$@"; do
      if [[ "$kv" != *=* ]]; then
        usage_error "$file:$lineno: 3 つ目以降は キー=値 で書きます: $kv"
      fi
      key="${kv%%=*}" val="${kv#*=}"
      [[ -n "$val" ]] || usage_error "$file:$lineno: 値が空です: $kv"
      case "$key" in
        tmux_session) tmux_s="$val" ;;
        *) usage_error "$file:$lineno: 知らないキーです（tmux_session）: $key" ;;
      esac
    done
    P_NAMES+=("$name")
    P_PATHS+=("$path")
    P_TMUX+=("$tmux_s")
  done <"$file"
  if [[ ${#P_NAMES[@]} -eq 0 ]]; then
    usage_error "設定ファイルにプロジェクトが 1 つもありません: $file"
  fi
}

# 名前から添字を引く。未登録なら登録済みの名前を添えて止まる（下の道具は 1 つも呼ばない）。
IDX=-1
find_project() {
  local name="$1" i
  for ((i = 0; i < ${#P_NAMES[@]}; i++)); do
    if [[ "${P_NAMES[$i]}" == "$name" ]]; then
      IDX=$i
      return 0
    fi
  done
  usage_error "登録されていないプロジェクトです: $name（登録済み: ${P_NAMES[*]}）"
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 が見つかりません。$2"
}

need_project_dir() {
  local path="${P_PATHS[$IDX]}"
  [[ -d "$path" ]] || die "プロジェクトのディレクトリがありません: $path（設定ファイルのパスを確かめてください）"
}

# devcontainer が付けるラベル（devcontainer.local_folder = 外部の機械のワークスペースの絶対パス）で
# コンテナを探す。VS Code が作ったコンテナも同じラベルを持つ。
# 出力: "<ID> <状態>"（状態は docker の State。running / exited など）。無ければ空。
container_of() {
  # head -n 1 ではなく sed -n 1p で受ける。head は 1 行読んだ時点でパイプを閉じ、
  # docker ps が SIGPIPE で死ぬ（pipefail 下では関数の終了コードが反転する）。
  # sed -n 1p は入力を最後まで読み切るので、生産側は正常終了する。
  docker ps -a --filter "label=devcontainer.local_folder=$1" --format '{{.ID}} {{.State}}' | sed -n '1p'
}

is_running() {
  local row
  row="$(container_of "$1")" || return 1
  [[ "${row#* }" == "running" ]]
}

dc_exec() {
  # devcontainer exec は最初の「オプションでない語」より後をそのままコマンドへ渡す
  # （CLI 0.89.0 の halt-at-non-option）。したがって CLI のオプションは必ずコマンドの前に置く。
  devcontainer exec --workspace-folder "${P_PATHS[$IDX]}" "$@"
}

# ── サブコマンド ──────────────────────────────────────────────────────────────

cmd_up() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev up <名前>"
  load_projects
  find_project "$1"
  need_project_dir
  need devcontainer "外部の機械への導入は README.md の「devcontainer CLI を入れる」。"
  devcontainer up --workspace-folder "${P_PATHS[$IDX]}"
}

# systemd のユニットの状態の語（active / activating / inactive / failed など）を出す。
# systemctl が無い、または何も出ないときは - （不明）。is-active は状態の語を 1 行出し、
# active 以外では 0 以外で抜ける。
unit_state() {
  local s="-"
  if command -v systemctl >/dev/null 2>&1; then
    s="$(systemctl --user is-active "$1" 2>/dev/null || true)"
    [[ -n "$s" ]] || s="-"
  fi
  printf '%s\n' "$s"
}

cmd_attach() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev attach <名前>"
  load_projects
  find_project "$1"
  need_project_dir
  need docker "Docker Engine を入れてください。"
  need devcontainer "外部の機械への導入は README.md の「devcontainer CLI を入れる」。"
  if ! is_running "${P_PATHS[$IDX]}"; then
    # 自分では起こさない。ユニットが起こし直している最中に 2 本目の up を重ねないため。
    die "$1 のコンテナが動いていません。dev up $1 で起こしてから入り直してください（ユニットを有効にしていれば、30 秒ほどで戻ります）。"
  fi
  local rc=0
  dc_exec tmux new-session -A -s "${P_TMUX[$IDX]}" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    # 入れない（exec が通らない）ときの手がかりを出す。コンテナが running でも入れないことがある
    # （プロセス数の上限に達したときなど。dev ls の CONTAINER では見分けられない）。
    # 「入れなかった」と「入れたあとにセッションが異常終了した」は終了コードから区別できないので、
    # どちらとも断定せず、元の終了コードは文面に出す。dev 自身は 1 で終わる（0/1/2 の取り決め）。
    echo "[$PROG] $1: 入れなかった、またはセッションが異常終了しました（終了コード $rc。この 2 つは区別できません）。" >&2
    echo "[$PROG] 原因の切り分け: dev doctor $1" >&2
    echo "[$PROG] 作り直し:       dev rebuild $1" >&2
    return 1
  fi
}

cmd_ls() {
  [[ $# -eq 0 ]] || usage_error "使い方: dev ls"
  load_projects
  need docker "Docker Engine を入れてください。"
  local i path row state unit tmux_s
  printf '%-20s %-10s %-10s %s\n' NAME CONTAINER UNIT TMUX
  for ((i = 0; i < ${#P_NAMES[@]}; i++)); do
    IDX=$i
    path="${P_PATHS[$i]}"
    row="$(container_of "$path" || true)"
    if [[ -z "$row" ]]; then state="none"; else state="${row#* }"; fi
    unit="$(unit_state "dev-up@${P_NAMES[$i]}.service")"
    tmux_s="-"
    if [[ "$state" == "running" ]] && command -v devcontainer >/dev/null 2>&1; then
      # =名前 は完全一致（tmux は -t の名前を前方一致でも引くため）。
      if dc_exec tmux has-session -t "=${P_TMUX[$i]}" </dev/null >/dev/null 2>&1; then
        tmux_s="${P_TMUX[$i]}"
      else
        tmux_s="none"
      fi
    fi
    printf '%-20s %-10s %-10s %s\n' "${P_NAMES[$i]}" "$state" "$unit" "$tmux_s"
  done
}

# systemd のユニット（dev-up@.service）の ExecStart。起こしてから、コンテナが止まるまで待つ。
#
# **止まった理由を問わず、0 以外で抜ける。** VS Code の窓を閉じたときの stopCompose は
# docker から見れば「意図した停止」だが、このプロセスにとっては「待っていたコンテナが
# 止まった」でしかない。0 以外で抜けるので、ユニットの Restart= がどの値でも起こし直す
# （判断の全文は README.md の「VS Code の窓を閉じたときの停止（stopCompose）」）。
cmd_supervise() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev supervise <名前>"
  load_projects
  find_project "$1"
  need_project_dir
  need docker "Docker Engine を入れてください。"
  need devcontainer "外部の機械への導入は README.md の「devcontainer CLI を入れる」。"
  local out id code
  # up は結果の JSON を 1 行で標準出力へ、経過を標準エラーへ出す（失敗の JSON でも 1 で抜ける）。
  out="$(devcontainer up --workspace-folder "${P_PATHS[$IDX]}")" || die "$1: devcontainer up が失敗しました: $out"
  id="$(printf '%s\n' "$out" | tail -n 1 | sed -n 's/.*"containerId":"\([0-9A-Za-z]*\)".*/\1/p')"
  [[ -n "$id" ]] || die "$1: devcontainer up の結果にコンテナの ID がありません: $out"
  echo "[$PROG] $1: コンテナ $id を起こしました。止まるまで待ちます。"
  code="$(docker wait "$id")" || die "$1: docker wait が失敗しました（コンテナ $id）"
  die "$1: コンテナ $id が止まりました（終了コード $code）。ユニットが起こし直します。"
}

# ユニットを止めているあいだの出力。ssh が切れると標準出力・標準エラーが閉じ、echo が失敗する
# （set -e でその場で抜ける）か、SIGPIPE で落ちる。どちらでもユニットが止まったまま残るので、
# 出力の失敗は無視する（SIGPIPE は止めているあいだだけ無視し、書き込みの失敗として受ける）。
# 書き込みが失敗したときの bash の苦情も閉じた標準エラーへ向かうだけなので、捨てる必要は無い。
rb_say() { printf '%s\n' "$*" || true; }
rb_err() { printf '%s\n' "$*" >&2 || true; }

# ユニットを止めてから作業する操作（rebuild / restart）の中断で、止めたユニットを起こし直してから抜ける。
# INT / HUP / TERM を受けたときに働く。子（devcontainer up / docker restart）の実行中に届いた
# シグナルは、子が終わってから処理される。
# **出力より先に起こし直す。** 中断の理由が ssh の切断なら、出力先はもう閉じている。
RB_UNIT=""
rebuild_abort() {
  local started=0
  trap - INT HUP TERM
  systemctl --user start "$RB_UNIT" >/dev/null 2>&1 && started=1
  if [[ "$started" -eq 1 ]]; then
    rb_err "[$PROG] 中断されました（$2）。止めたユニット $RB_UNIT を起こし直しました。"
  else
    rb_err "[$PROG] 中断されました（$2）。ユニット $RB_UNIT を起こせませんでした。手で起こしてください。"
  fi
  exit "$1"
}

# ユニットの状態を見て、止める必要があるかを決める（HAD_UNIT=1 なら止める対象）。
# 引数: 名前 ユニット 操作（「作り直して」など。文面に入れる）。
# 止めない状態は inactive / failed / unknown（ユニットが無い。ユニットを入れずに dev だけを置く運用）/
# - （systemctl が無い）だけ。Restart= の待機中（activating）や停止処理中（deactivating）のユニットも、
# 操作の途中で up を起こしうるので止める。
# systemctl はあるのに状態を引けなかったときは、止めずに進むとユニットの up と重なりうるので、
# 何も変えずに止まる（systemctl が無い機械は、ユニットを使わないので触らず進む）。
HAD_UNIT=0
USTATE="-"
unit_probe() {
  local name="$1" unit="$2" action="$3"
  HAD_UNIT=0
  USTATE="$(unit_state "$unit")"
  if [[ "$USTATE" == "-" ]] && command -v systemctl >/dev/null 2>&1; then
    die "$name: ユニット $unit の状態が分からないので、止めて終わります（何も${action}いません）。確かめる: systemctl --user status $unit"
  fi
  case "$USTATE" in
    inactive | failed | unknown | -) ;;
    *) HAD_UNIT=1 ;;
  esac
}

# unit_probe で止める対象になったユニットを止め、中断されても起こし直せるようにする。
# 引数: 名前 ユニット 操作（「作り直して」など） 理由（止める理由の文）。HAD_UNIT=0 なら何もしない。
unit_guard_begin() {
  local name="$1" unit="$2" action="$3" reason="$4"
  [[ "$HAD_UNIT" -eq 1 ]] || return 0
  # 止めたあとの中断（ssh の切断など）でも起こし直す。止める前に張るのは、止めている最中の
  # 中断でも戻せるようにするため（動いているユニットへの start は何も変えない）。
  RB_UNIT="$unit"
  trap 'rebuild_abort 130 INT' INT
  trap 'rebuild_abort 129 HUP' HUP
  trap 'rebuild_abort 143 TERM' TERM
  # ここから起こし直すまで SIGPIPE を無視する（閉じた出力への書き込みで落ちず、rb_say が失敗を受ける）。
  trap '' PIPE
  rb_say "[$PROG] $name: ユニット $unit（$USTATE）を止めます（${reason}）。"
  systemctl --user stop "$unit" || { trap - INT HUP TERM PIPE; die "$name: ユニット $unit を止められませんでした。何も${action}いません。"; }
}

# unit_guard_begin で止めたユニットを起こし直す。止めていなければ何もしない。
# 操作が失敗していても起こし直す（戻らないまま放置しない）。出力より先に起こす。
# 起こせなかったときだけ 1 を返す。
unit_guard_end() {
  local name="$1" unit="$2" r=0
  [[ "$HAD_UNIT" -eq 1 ]] || return 0
  if systemctl --user start "$unit"; then
    rb_say "[$PROG] $name: ユニット $unit を起こし直しました。"
  else
    rb_err "[$PROG] $name: ユニット $unit を起こせませんでした。"
    r=1
  fi
  trap - INT HUP TERM PIPE
  return "$r"
}

# コンテナを作り直す。ユニットが動いていれば先に止め、作り直したあとで起こし直す。
# 止めずに作り直すと、ユニットの up（dev supervise）が作り直しの途中で重なりうる。
cmd_rebuild() {
  local pull=0 name="" a
  for a in "$@"; do
    case "$a" in
      --pull) pull=1 ;;
      -*) usage_error "知らないオプションです: $a（使い方: dev rebuild <名前> [--pull]）" ;;
      *)
        [[ -z "$name" ]] || usage_error "使い方: dev rebuild <名前> [--pull]"
        name="$a"
        ;;
    esac
  done
  [[ -n "$name" ]] || usage_error "使い方: dev rebuild <名前> [--pull]"
  load_projects
  find_project "$name"
  need_project_dir
  need devcontainer "外部の機械への導入は README.md の「devcontainer CLI を入れる」。"
  local path="${P_PATHS[$IDX]}" unit="dev-up@${name}.service"
  if [[ "$pull" -eq 1 ]]; then
    # 作り直す前に取り込む。失敗したら何も止めずに終わる（ユニットにも触らない）。
    need git "git を入れてください。"
    git -C "$path" pull --ff-only || die "$name: git pull --ff-only が失敗したので、作り直しません: $path"
  fi
  local rc=0
  unit_probe "$name" "$unit" "作り直して"
  unit_guard_begin "$name" "$unit" "作り直して" "作り直しの途中で up が重ならないように"
  if [[ "$HAD_UNIT" -eq 1 ]]; then rb_say "[$PROG] $name: コンテナを作り直します。"; else echo "[$PROG] $name: コンテナを作り直します。"; fi
  devcontainer up --workspace-folder "$path" --remove-existing-container || rc=$?
  unit_guard_end "$name" "$unit" || rc=1
  [[ "$rc" -eq 0 ]] || die "$name: 作り直しが失敗しました（終了コード $rc）。"
  echo "[$PROG] $name: 作り直しました。"
}

# 作り直さずに再起動する。rebuild と同じく、ユニットが動いていれば先に止め（docker restart で
# コンテナが一瞬止まると、ユニットの supervise が 0 以外で抜けて up を重ねうる）、
# 止めたときだけ起こし直す。中断（ssh の切断など）でも起こし直す。
cmd_restart() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev restart <名前>"
  load_projects
  find_project "$1"
  need_project_dir
  need docker "Docker Engine を入れてください。"
  local name="$1" path="${P_PATHS[$IDX]}" unit="dev-up@${1}.service" row id rc=0
  row="$(container_of "$path" || true)"
  # コンテナが無いなら、ユニットにも触らずに止まる（作るのは dev up / dev rebuild の役目）。
  [[ -n "$row" ]] || die "$name: コンテナがありません。dev up $name で起こしてください（再起動は在るコンテナだけを対象にします）。"
  id="${row%% *}"
  unit_probe "$name" "$unit" "再起動して"
  unit_guard_begin "$name" "$unit" "再起動して" "再起動の途中で up が重ならないように"
  if [[ "$HAD_UNIT" -eq 1 ]]; then rb_say "[$PROG] $name: コンテナ $id を再起動します。"; else echo "[$PROG] $name: コンテナ $id を再起動します。"; fi
  docker restart "$id" >/dev/null || rc=$?
  unit_guard_end "$name" "$unit" || rc=1
  [[ "$rc" -eq 0 ]] || die "$name: 再起動が失敗しました（終了コード $rc）。原因の切り分け: dev doctor $name"
  echo "[$PROG] $name: 再起動しました。"
}

# 意図して止める。ユニットを先に止めてから、コンテナを止める（先にコンテナだけを止めると、
# ユニットの supervise が 30 秒後に起こし直す）。ユニットは disable しないので、再起動の後は戻る。
cmd_stop() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev stop <名前>"
  load_projects
  find_project "$1"
  need_project_dir
  need docker "Docker Engine を入れてください。"
  local name="$1" path="${P_PATHS[$IDX]}" unit="dev-up@${1}.service" row id state
  # 止めるのが目的なので、HUP（ssh の切断）と PIPE（閉じた出力）は無視して、ユニットを止めたあとの
  # docker stop まで必ず走らせる（rebuild / restart のように起こし直す必要は無い）。
  trap '' HUP PIPE
  unit_probe "$name" "$unit" "止めて"
  if [[ "$HAD_UNIT" -eq 1 ]]; then
    rb_say "[$PROG] $name: ユニット $unit（$USTATE）を止めます（コンテナだけを止めると起こし直されるため、先に止める）。"
    systemctl --user stop "$unit" || die "$name: ユニット $unit を止められませんでした。コンテナには触っていません。"
  fi
  row="$(container_of "$path" || true)"
  if [[ -z "$row" ]]; then
    rb_say "[$PROG] $name: コンテナがありません。止めるものはありません。"
  else
    id="${row%% *}"
    state="${row#* }"
    if [[ "$state" != "running" ]]; then
      rb_say "[$PROG] $name: コンテナ $id は動いていません（$state）。"
    else
      rb_say "[$PROG] $name: コンテナ $id を止めます。"
      docker stop "$id" >/dev/null || die "$name: docker stop が失敗しました（コンテナ $id）。ユニットは止めたままです。戻す: dev up $name"
    fi
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl --user is-enabled "$unit" >/dev/null 2>&1; then
    rb_say "[$PROG] $name: 止めました。ユニットは disable していないので、外部の機械の再起動の後は戻ります。"
    rb_say "[$PROG] 戻す: dev up $name、またはユニットを起こす systemctl --user start $unit"
  else
    # ユニットが無い、または enable されていないときは、再起動の後も戻らない。ユニットの案内も出さない。
    rb_say "[$PROG] $name: 止めました。ユニットは有効になっていないので、外部の機械の再起動の後も戻りません。"
    rb_say "[$PROG] 戻す: dev up $name"
  fi
}

# ユニットのログの末尾。journalctl --user -u dev-up@<名前>.service。
cmd_logs() {
  local name="" lines=50 a
  while [[ $# -gt 0 ]]; do
    a="$1"
    case "$a" in
      -n)
        [[ $# -ge 2 ]] || usage_error "-n には行数が要ります（使い方: dev logs <名前> [-n <行数>]）"
        lines="$2"
        shift
        ;;
      -*) usage_error "知らないオプションです: $a（使い方: dev logs <名前> [-n <行数>]）" ;;
      *)
        [[ -z "$name" ]] || usage_error "使い方: dev logs <名前> [-n <行数>]"
        name="$a"
        ;;
    esac
    shift
  done
  [[ -n "$name" ]] || usage_error "使い方: dev logs <名前> [-n <行数>]"
  # 先頭 0 を許さない（08 などが 8 進と読まれ、算術で誤るため）。
  if [[ ! "$lines" =~ ^[1-9][0-9]*$ ]]; then
    usage_error "-n は 1 以上の整数で指定します: $lines"
  fi
  load_projects
  find_project "$name"
  need journalctl "systemd の journalctl が要ります（dev-up@.service を使う機械で使う）。"
  journalctl --user -u "dev-up@${name}.service" -n "$lines" --no-pager
}

# ユニットを有効にして起こす。外部の機械の起動時から、コンテナを保つようになる。
cmd_enable() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev enable <名前>"
  load_projects
  find_project "$1"
  need systemctl "systemd の systemctl が要ります（dev-up@.service を使う機械で使う）。"
  systemctl --user enable --now "dev-up@${1}.service" || die "$1: ユニット dev-up@${1}.service を有効にできませんでした。ユニットを入れたかは README.md の「ユニットを入れる」。"
  echo "[$PROG] $1: ユニット dev-up@${1}.service を有効にして起こしました。"
}

# ユニットを無効にして止める。コンテナは止めない（止めるのは dev stop）。
cmd_disable() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev disable <名前>"
  load_projects
  find_project "$1"
  need systemctl "systemd の systemctl が要ります（dev-up@.service を使う機械で使う）。"
  systemctl --user disable --now "dev-up@${1}.service" || die "$1: ユニット dev-up@${1}.service を無効にできませんでした。"
  echo "[$PROG] $1: ユニット dev-up@${1}.service を無効にして止めました。コンテナは止めていません（止める: dev stop $1）。"
  echo "[$PROG] ユニットが無いので、コンテナが止まっても戻りません。戻す: dev enable $1"
}

# tmux を介さずに、コンテナの中でコマンドを 1 つ実行する（codex login --device-auth など）。
# -- より後ろを、devcontainer exec へそのまま渡す。コマンドの終了コードをそのまま返す。
cmd_exec() {
  local name="" a
  [[ $# -ge 1 ]] || usage_error "使い方: dev exec <名前> -- <コマンド...>"
  name="$1"
  shift
  [[ $# -ge 2 && "$1" == "--" ]] || usage_error "使い方: dev exec <名前> -- <コマンド...>（-- の後ろにコマンドが要ります）"
  shift
  # 先頭が - の語は devcontainer exec 自身のオプションとして読まれる（コマンドにならない）。
  [[ "$1" != -* ]] || usage_error "コマンドの先頭が - で始まっています（devcontainer のオプションとして読まれるため渡せません）: $1"
  load_projects
  find_project "$name"
  need_project_dir
  need docker "Docker Engine を入れてください。"
  need devcontainer "外部の機械への導入は README.md の「devcontainer CLI を入れる」。"
  if ! is_running "${P_PATHS[$IDX]}"; then
    # attach と同じく、自分では起こさない（ユニットが起こし直している最中に 2 本目の up を重ねないため）。
    die "$name のコンテナが動いていません。dev up $name で起こしてから実行し直してください（ユニットを有効にしていれば、30 秒ほどで戻ります）。"
  fi
  dc_exec "$@"
}

# ── self-update ───────────────────────────────────────────────────────────────
# devhost は DCB のリリースに同梱されて配られる（README.md の「devhost を入手する」）。
# 取得先は DCB の公開リリース。既定は最新、--version で版を固定する。
RELEASE_BASE_URL="https://github.com/ojos/devcontainer-bootstrap/releases"
# 置き換え先（いま置いてある dev）が devhost の dev.sh である確かめ。1 行目が shebang、2 行目が
# 「# dev — 」で始まること。2 行目を全文で照合しないのは、将来の版が説明文を変えても、
# 古い版から更新できなくなるのを避けるため（接頭辞は版をまたいで変えない約束にする）。
# 取り出した新しい dev には課さない。取得物の正当性は、ハッシュの照合と構文の検査で担保する。
SELF_SHEBANG='#!/usr/bin/env bash'
SELF_HEADER_PREFIX='# dev — '

# ファイルの先頭 2 行が devhost の dev.sh のものであること（置き換え先の確かめ）。
is_devhost_dev_sh() {
  local f="$1" l1 l2
  [[ -f "$f" ]] || return 1
  { IFS= read -r l1 && IFS= read -r l2; } <"$f" || return 1
  [[ "$l1" == "$SELF_SHEBANG" && "$l2" == "$SELF_HEADER_PREFIX"* ]]
}

# ファイルの SHA-256（16 進の小文字 64 桁）を出す。sha256sum は GNU coreutils のコマンドで macOS には無いので、
# shasum へ分岐する（README の手動手順と同じ分岐）。
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'  # bsd-ok: command -v で在るときだけ。無ければ下で shasum -a 256 に分岐する
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

# パスの祖先に .git（ディレクトリでもファイルでも）があれば git の作業ツリーの中。git が無い機械でも
# 判定できるよう、git コマンドでなく祖先の探索で見る。リポジトリのチェックアウトの packages/devhost/dev.sh や、
# 展開しただけのリリースのディレクトリ（リポジトリの中にある場合）を、置き換え先にしないため。
in_git_worktree() {
  local d
  d="$(cd "$(dirname "$1")" && pwd -P)" || return 1
  while :; do
    [[ -e "$d/.git" ]] && return 0
    [[ "$d" == "/" ]] && return 1
    d="${d%/*}"
    [[ -n "$d" ]] || d="/"
  done
}

SU_TMP=""
su_cleanup() { [[ -z "$SU_TMP" ]] || rm -rf "$SU_TMP"; }

# dev 自身を、DCB の公開リリースの devhost/dev.sh へ置き換える。
# 手順は README.md の手動の入手と同じ: RELEASE-MANIFEST.json と PACKAGE_ARCHIVE.tar.gz を取得し、
# マニフェストが記録した archive のハッシュと照合してから、./devhost/dev.sh を取り出す。
# **置き換える前に全部確かめる**（ハッシュが合う / 取り出したものが devhost の dev.sh / 置き換え先も
# devhost の dev.sh）。どれかが外れたら、何も置き換えずに 1 で止まる。置き換えは同じディレクトリの
# 一時ファイルへ書いてから mv する（途中で切れても、半端な dev が残らない）。
cmd_self_update() {
  local version="" a
  while [[ $# -gt 0 ]]; do
    a="$1"
    case "$a" in
      --version)
        [[ $# -ge 2 ]] || usage_error "--version には版が要ります（使い方: dev self-update [--version <vX.Y.Z>]）"
        version="$2"
        shift
        ;;
      *) usage_error "使い方: dev self-update [--version <vX.Y.Z>]" ;;
    esac
    shift
  done
  if [[ -n "$version" && ! "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$ ]]; then
    usage_error "版は vX.Y.Z の形で指定します（URL の一部になるため）: $version"
  fi
  need curl "curl を入れてください。"
  need jq "jq を入れてください（マニフェストを読む。README.md の手動の入手と同じ）。"
  need tar "tar を入れてください。"
  local base self selfdir
  # 最新のとき、マニフェストだけを latest から取り、そこに書かれた版でアーカイブを取る
  # （latest を 2 回引くと、間にリリースが出たときに、別の版のマニフェストとアーカイブを組み合わせうる）。
  local mbase
  if [[ -n "$version" ]]; then mbase="$RELEASE_BASE_URL/download/$version"; else mbase="$RELEASE_BASE_URL/latest/download"; fi
  base="$mbase"

  # 置き換え先。写しとして置いた dev（~/.local/bin/dev）自身。リンクは辿らず、止まる
  # （リンク先のリポジトリの道具を、黙って書き換えないため）。
  self="${DEV_SELF_PATH:-${BASH_SOURCE[0]}}"
  [[ ! -L "$self" ]] || die "置き換え先 $self はリンクです。リンクの先は書き換えません（README.md の「dev を置く」のとおり、写しで置いてください）。何も置き換えていません。"
  ! in_git_worktree "$self" || die "置き換え先 $self は git の作業ツリーの中です（リポジトリのチェックアウトや、展開しただけのディレクトリは書き換えません。~/.local/bin/dev などへ写して置いたものを更新してください）。何も置き換えていません。"
  is_devhost_dev_sh "$self" || die "置き換え先 $self が devhost の dev.sh だと確かめられません（1 行目が shebang、2 行目が「# dev — 」で始まる形ではない、または読めない）。何も置き換えていません。"
  selfdir="$(cd "$(dirname "$self")" && pwd)"

  SU_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dev-self-update.XXXXXX")" || die "作業ディレクトリを作れません。何も置き換えていません。"
  trap su_cleanup EXIT
  echo "[$PROG] 取得先: $mbase"
  curl -fsSL "$mbase/RELEASE-MANIFEST.json" -o "$SU_TMP/RELEASE-MANIFEST.json" || die "RELEASE-MANIFEST.json を取得できません。何も置き換えていません。"
  if [[ -z "$version" ]]; then
    local mver
    mver="$(jq -r '.version // empty' "$SU_TMP/RELEASE-MANIFEST.json")" || die "RELEASE-MANIFEST.json を読めません。何も置き換えていません。"
    [[ "$mver" == v* ]] || mver="v$mver"
    [[ "$mver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$ ]] || die "最新の版をマニフェストから読めません（version: $mver）。--version vX.Y.Z で版を指定してください。何も置き換えていません。"
    base="$RELEASE_BASE_URL/download/$mver"
    echo "[$PROG] 最新の版: $mver（アーカイブは $base から取る）"
  fi
  curl -fsSL "$base/PACKAGE_ARCHIVE.tar.gz" -o "$SU_TMP/PACKAGE_ARCHIVE.tar.gz" || die "PACKAGE_ARCHIVE.tar.gz を取得できません。何も置き換えていません。"

  local want got
  want="$(jq -r '.checksums["PACKAGE_ARCHIVE.tar.gz"] // empty' "$SU_TMP/RELEASE-MANIFEST.json")" || die "RELEASE-MANIFEST.json を読めません。何も置き換えていません。"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "RELEASE-MANIFEST.json に archive のハッシュ（checksums の PACKAGE_ARCHIVE.tar.gz）がありません。何も置き換えていません。"
  got="$(sha256_of "$SU_TMP/PACKAGE_ARCHIVE.tar.gz")" || die "ハッシュを計算できません。何も置き換えていません。"
  [[ "$got" == "$want" ]] || die "PACKAGE_ARCHIVE.tar.gz のハッシュがマニフェストと合いません（マニフェスト $want / 実際 $got）。何も置き換えていません。"
  echo "[$PROG] ハッシュが合いました: $got"

  # archive の中の名前は ./devhost/... なので、./ を付けて指定する（GNU tar は devhost/ だと一致しない）。
  mkdir "$SU_TMP/x" && tar -xzf "$SU_TMP/PACKAGE_ARCHIVE.tar.gz" -C "$SU_TMP/x" ./devhost/dev.sh || die "archive から ./devhost/dev.sh を取り出せません。何も置き換えていません。"
  [[ -s "$SU_TMP/x/devhost/dev.sh" ]] || die "取り出した devhost/dev.sh が空です。何も置き換えていません。"
  "${BASH:-bash}" -n "$SU_TMP/x/devhost/dev.sh" || die "取り出した devhost/dev.sh に構文の誤りがあります。何も置き換えていません。"

  if cmp -s "$SU_TMP/x/devhost/dev.sh" "$self"; then
    echo "[$PROG] すでにこの版です（$self は取得した dev.sh と同じ）。置き換えません。"
    return 0
  fi
  local tmp
  tmp="$(mktemp "$selfdir/.dev.XXXXXX")" || die "$selfdir に一時ファイルを作れません。何も置き換えていません。"
  if ! cp "$SU_TMP/x/devhost/dev.sh" "$tmp" || ! chmod 0755 "$tmp" || ! mv -f "$tmp" "$self"; then
    rm -f "$tmp"
    die "置き換えに失敗しました。何も置き換えていません（置き換え先: $self）。"
  fi
  echo "[$PROG] 置き換えました: $self"
}

# doctor の 1 行ごとの判定。FAIL / WARN の数を数える。
DOC_FAIL=0
DOC_WARN=0
doc_line() {
  local level="$1"
  shift
  case "$level" in
    FAIL) DOC_FAIL=$((DOC_FAIL + 1)) ;;
    WARN) DOC_WARN=$((DOC_WARN + 1)) ;;
  esac
  printf '  [%-4s] %s\n' "$level" "$*"
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

# events 形式のファイル（1 行 1 つの「キー 値」）から、キーの値を出す。無ければ空。
event_value() {
  local file="$1" key="$2" k v
  [[ -r "$file" ]] || return 0
  while read -r k v; do
    if [[ "$k" == "$key" ]]; then
      printf '%s\n' "$v"
      return 0
    fi
  done <"$file"
}

# /proc/<pid>/cgroup（cgroup v2 は 0::/パス の 1 行）から、パスを出す。読めない・v2 でなければ空。
cgroup_path_of() {
  local file="$1" line
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == 0::* ]]; then
      printf '%s\n' "${line#0::}"
      return 0
    fi
  done <"$file"
}

# 「動いているのに入れない」を見分ける。1 つでも FAIL なら 1、WARN だけなら 3、無ければ 0。
cmd_doctor() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev doctor <名前>"
  # GNU の timeout 0 は時間制限を無効にするので、0 や数でない値は受け付けない（返らなくなりうる）。
  if [[ -n "${DEV_EXEC_TIMEOUT:-}" ]] && { ! is_uint "$DEV_EXEC_TIMEOUT" || [[ "$DEV_EXEC_TIMEOUT" -lt 1 ]]; }; then
    usage_error "DEV_EXEC_TIMEOUT は 1 以上の整数（秒）で指定します: $DEV_EXEC_TIMEOUT"
  fi
  if [[ -n "${DEV_EXEC_KILL_GRACE:-}" ]] && { ! is_uint "$DEV_EXEC_KILL_GRACE" || [[ "$DEV_EXEC_KILL_GRACE" -lt 1 ]]; }; then
    usage_error "DEV_EXEC_KILL_GRACE は 1 以上の整数（秒）で指定します: $DEV_EXEC_KILL_GRACE"
  fi
  load_projects
  find_project "$1"
  need_project_dir
  need docker "Docker Engine を入れてください。"
  need devcontainer "外部の機械への導入は README.md の「devcontainer CLI を入れる」。"
  local name="$1" path="${P_PATHS[$IDX]}" unit="dev-up@${1}.service"
  local row id="" state="none" pid="" cgpath=""
  echo "[$PROG] doctor: $name（$path）"

  row="$(container_of "$path" || true)"
  if [[ -n "$row" ]]; then
    id="${row%% *}"
    state="${row#* }"
  fi
  if [[ -z "$row" ]]; then
    doc_line FAIL "コンテナがありません（dev up $name で起こす）"
  elif [[ "$state" != "running" ]]; then
    doc_line FAIL "コンテナ $id の状態が $state です（動いていません）"
  else
    doc_line OK "コンテナ $id は running"
  fi

  if [[ "$state" == "running" ]]; then
    local ec=0 eout tmp secs="${DEV_EXEC_TIMEOUT:-30}" grace="${DEV_EXEC_KILL_GRACE:-5}"
    tmp="$(mktemp "${TMPDIR:-/tmp}/dev-doctor.XXXXXX" 2>/dev/null)" || tmp=/dev/null
    run_limited "$secs" "$grace" "$tmp" devcontainer exec --workspace-folder "$path" true || ec=$?
    eout="$(tail -n 1 "$tmp" 2>/dev/null || true)"
    [[ "$tmp" == /dev/null ]] || rm -f "$tmp"
    if [[ "$ec" -eq 0 ]]; then
      doc_line OK "exec が通ります"
    elif [[ "$ec" -eq 124 || "$ec" -eq 137 || "$ec" -eq 143 ]]; then
      doc_line FAIL "exec が $secs 秒で返りません（止まっています）: $eout"
    else
      doc_line FAIL "exec が通りません（終了コード $ec）: $eout"
    fi

    pid="$(docker inspect --format '{{.State.Pid}}' "$id" 2>/dev/null)" || pid=""
    if ! is_uint "$pid" || [[ "$pid" -eq 0 ]]; then
      doc_line WARN "コンテナの PID を得られません（cgroup の項目を読めません）"
    else
      cgpath="$(cgroup_path_of "$PROC_ROOT/$pid/cgroup")"
      if [[ -z "$cgpath" ]]; then
        doc_line WARN "$PROC_ROOT/$pid/cgroup から cgroup v2 のパスを読めません（cgroup の項目を読めません）"
      else
        doctor_cgroup "$CGROUP_ROOT$cgpath" "$cgpath"
      fi
    fi
  fi

  local ustate
  ustate="$(unit_state "$unit")"
  doc_line INFO "ユニット $unit: $ustate"
  if command -v journalctl >/dev/null 2>&1; then
    echo "  ユニットのログの末尾:"
    local jout
    jout="$(journalctl --user -u "$unit" -n 10 --no-pager 2>&1 || true)"
    printf '%s\n' "$jout" | sed 's/^/    /'
  fi

  if [[ "$DOC_FAIL" -gt 0 ]]; then
    echo "[$PROG] 判定: FAIL（$DOC_FAIL 件）。作り直す: dev rebuild $name"
    exit 1
  elif [[ "$DOC_WARN" -gt 0 ]]; then
    echo "[$PROG] 判定: WARN（$DOC_WARN 件）。"
    exit 3
  fi
  echo "[$PROG] 判定: OK"
}

# 時間を区切って実行する。引数: 秒数 出力先のファイル コマンド...。終了コードを返す
# （時間切れは timeout なら 124（KILL まで進めば 137）、代替（kill）なら 143（KILL なら 137））。
# 期限で TERM を送り、TERM を無視されても猶予（秒）のあとに KILL する。出力をパイプでなくファイルへ受けるのは、
# 殺しきれなかった子が出力の口を握ったまま、受け取る側が返らなくなるのを避けるため。
# timeout が無い環境（macOS など）では、バックグラウンドで起こして指定の秒数で kill する。
run_limited() {
  local secs="$1" grace="$2" out="$3" pid killer rc=0
  shift 3
  if command -v timeout >/dev/null 2>&1; then
    timeout -k "$grace" "$secs" "$@" </dev/null >"$out" 2>&1 || rc=$?
    return "$rc"
  fi
  "$@" </dev/null >"$out" 2>&1 &
  pid=$!
  (
    sleep "$secs"
    kill "$pid"
    sleep "$grace"
    kill -KILL "$pid"
  ) </dev/null >/dev/null 2>&1 &
  killer=$!
  { wait "$pid"; } 2>/dev/null || rc=$?
  kill "$killer" >/dev/null 2>&1 || true
  { wait "$killer"; } 2>/dev/null || true
  return "$rc"
}

# pids の上限を、コンテナ自身の cgroup から根まで遡って見る。上位（systemd の slice の TasksMax など）に
# 上限があり、そちらに当たっていても見逃さないため。上限のある階層のうち、現在値 / 上限 の比が
# 最大のものを判定に使い、どの階層かを表示する。
doctor_pids() {
  local path="$1" dir cur max own=1 own_cur="" warned=0 zero=0
  local best_cur="" best_max="" best_path="" pct
  while :; do
    dir="$CGROUP_ROOT$path"
    cur=""
    max=""
    if [[ -r "$dir/pids.max" ]]; then read -r max <"$dir/pids.max" || true; fi
    if [[ -r "$dir/pids.current" ]]; then read -r cur <"$dir/pids.current" || true; fi
    if [[ "$own" -eq 0 && -n "$max" && "$max" != "max" ]]; then
      # 上位の階層は、上限があるのに読めない・壊れているときに黙って無視しない（上限なしと誤らない）。
      if ! is_uint "$max"; then
        doc_line WARN "pids.max が数でも max でもありません: $max（階層: $path）"
        warned=1
      elif ! is_uint "$cur"; then
        doc_line WARN "pids.current を読めません（階層: $path。pids.max は $max）"
        warned=1
      fi
    fi
    if [[ "$own" -eq 1 ]]; then
      # コンテナ自身の階層は、読めないこと自体を警告する（上位の階層の欠落は根で自然に起きる）。
      own=0
      own_cur="$cur"
      if ! is_uint "$cur"; then
        doc_line WARN "pids.current を読めません（$dir）"
        warned=1
      fi
      if [[ -z "$max" ]]; then
        doc_line WARN "pids.max を読めません（$dir）"
        warned=1
      elif [[ "$max" != "max" ]] && ! is_uint "$max"; then
        doc_line WARN "pids.max が数でも max でもありません: $max（$dir）"
        warned=1
      fi
    fi
    if is_uint "$max" && is_uint "$cur"; then
      if [[ "$max" -eq 0 ]]; then
        doc_line FAIL "pids.max が 0 です（階層: $path）。新しいタスクを作れません"
        zero=1
      elif [[ -z "$best_max" || $((cur * best_max)) -gt $((best_cur * max)) ]]; then
        best_cur="$cur" best_max="$max" best_path="$path"
      fi
    fi
    [[ "$path" == "/" ]] && break
    path="${path%/*}"
    [[ -n "$path" ]] || path="/"
  done
  if [[ -n "$best_max" ]]; then
    pct=$((best_cur * 100 / best_max))
    if [[ $((best_cur * 100)) -ge $((best_max * 90)) ]]; then
      doc_line FAIL "pids が上限に近づいています: $best_cur / $best_max（${pct}%）（階層: $best_path）"
    else
      doc_line OK "pids: $best_cur / $best_max（${pct}%）（階層: $best_path）"
    fi
  elif [[ "$warned" -eq 0 && "$zero" -eq 0 ]]; then
    doc_line OK "pids: $own_cur（上限なし）"
  fi
}

# コンテナの cgroup から、pids・上限に当たった回数・OOM・ゾンビを出して判定する。
doctor_cgroup() {
  local cgdir="$1" cgpath="$2" hits oom
  doctor_pids "$cgpath"

  hits="$(event_value "$cgdir/pids.events" max)"
  if ! is_uint "$hits"; then
    doc_line WARN "pids.events を読めません"
  elif [[ "$hits" -ge 1 ]]; then
    doc_line WARN "pids の上限に当たった回数: $hits"
  else
    doc_line OK "pids の上限に当たった回数: 0"
  fi

  oom="$(event_value "$cgdir/memory.events" oom_kill)"
  if ! is_uint "$oom"; then
    doc_line WARN "memory.events を読めません"
  elif [[ "$oom" -ge 1 ]]; then
    doc_line WARN "OOM で殺された回数（oom_kill）: $oom"
  else
    doc_line OK "oom_kill: 0"
  fi

  # ゾンビ = そのコンテナの cgroup（と配下）に属し、状態が Z のタスク。ps の `-eo pid=,stat=` は
  # 「PID 状態」を 1 行ずつ出す（見出しなし）。所属は /proc/<PID>/cgroup で引く。
  # ゾンビの数に比例してプロセスを起こさないよう、突き合わせは awk 1 回にまとめる
  # （ゾンビが 18000 個ある環境で、1 個ごとにサブシェルを起こすと数十秒かかる）。
  local psout zc
  if ! command -v awk >/dev/null 2>&1; then
    doc_line WARN "awk が無く、ゾンビを数えられません"
    return 0
  fi
  if ! psout="$(ps -eo pid=,stat= 2>/dev/null)"; then
    doc_line WARN "ps を実行できず、ゾンビを数えられません"
    return 0
  fi
  zc="$(awk -v root="$PROC_ROOT" -v cg="$cgpath" '
    $2 ~ /^Z/ {
      f = root "/" $1 "/cgroup"
      p = ""
      while ((getline line < f) > 0) {
        if (substr(line, 1, 3) == "0::") { p = substr(line, 4); break }
      }
      close(f)
      if (p == cg || index(p, cg "/") == 1) n++
    }
    END { print n + 0 }
  ' <<<"$psout")"
  if [[ "$zc" -ge 100 ]]; then
    doc_line WARN "ゾンビ: $zc（100 以上）"
  else
    doc_line OK "ゾンビ: $zc"
  fi
}

# ── help（説明文の正本。README の「コマンドの説明」は、この出力をそのまま載せる）────────
help_ls() {
  cat <<'EOF'
dev ls — 登録したプロジェクトの状態を並べる。

使い方:
  dev ls

NAME / CONTAINER / UNIT / TMUX を 1 行ずつ出す。
  CONTAINER  docker の状態（running / exited など）。無ければ none
  UNIT       dev-up@<名前> の systemd のユニットの状態。systemctl が無ければ -
  TMUX       コンテナの中の tmux のセッションの有無（CONTAINER が running のときだけ）
CONTAINER が running でも入れないことがある。そのときは dev doctor <名前>。

終了コード: 0 = 成功 / 2 = 使い方か設定ファイルの誤り
EOF
}

help_up() {
  cat <<'EOF'
dev up — devcontainer を起こす（在れば何もしない）。

使い方:
  dev up <名前>

devcontainer up --workspace-folder <パス> を呼ぶ。作り直しはしない（作り直すときは dev rebuild）。

終了コード: 0 = 成功 / 1 = 起動の失敗 / 2 = 使い方か設定ファイルの誤り（未登録の名前を含む）
失敗したとき: 経過の出力を読む。コンテナが戻らないときは dev doctor <名前>。
EOF
}

help_attach() {
  cat <<'EOF'
dev attach — コンテナの中の tmux に入る（無ければ作る）。

使い方:
  dev attach <名前>

devcontainer exec で tmux new-session -A -s <セッション名> を呼ぶ。セッション名の既定は main で、
設定ファイルの tmux_session=<名前> で変えられる。コンテナは起こさない（ユニットが起こし直している
最中に 2 本目の up を重ねないため）。

終了コード: 0 = 成功 / 1 = コンテナが動いていない、または中へ入れなかった・セッションが異常終了した
            （この 2 つは区別できない。元の終了コードは案内の文面に出す） / 2 = 使い方か設定の誤り
失敗したとき:
  コンテナが動いていない  dev up <名前>（ユニットを有効にしていれば 30 秒ほどで戻る）
  入れなかった           dev doctor <名前> で切り分け、直らなければ dev rebuild <名前>
EOF
}

help_supervise() {
  cat <<'EOF'
dev supervise — 起こして、止まるまで待つ（systemd のユニット dev-up@.service の ExecStart）。

使い方:
  dev supervise <名前>

devcontainer up で起こし、docker wait でコンテナが止まるまで待つ。止まった理由を問わず、
必ず 0 以外で終わる（ユニットの Restart=always が起こし直す）。人が直接使うものではない。
意図して止めたいときはユニットを先に止める（dev rebuild は自分で止めて起こし直す）。

終了コード: 1 = コンテナが止まった、または起こせなかった / 2 = 使い方か設定ファイルの誤り
EOF
}

help_rebuild() {
  cat <<'EOF'
dev rebuild — コンテナを作り直す。

使い方:
  dev rebuild <名前> [--pull]

呼ぶ順序:
  1. --pull のときだけ git -C <パス> pull --ff-only。失敗したら、何も止めずに終わる
  2. ユニット dev-up@<名前> が inactive / failed / unknown（ユニットを入れていない）でなければ止める
     （起こし直しの待機中の activating も止める。止める必要の無いとき、または systemctl が無いときは
     触らない）。systemctl はあるのに状態の語が得られないとき（問い合わせの失敗）は、
     up と重なる危険を避けるため、何も作り直さずに 1 で止まる
     （確かめる: systemctl --user status dev-up@<名前>）
  3. devcontainer up --workspace-folder <パス> --remove-existing-container
  4. 2 で止めたときだけ、ユニットを起こし直す。3 が失敗しても、INT / HUP / TERM で中断されても
     （ssh の切断など）起こし直してから終わる（中断の終了コードは 130 / 129 / 143）
ユニットを先に止めるのは、作り直しの途中でユニットの up が重ならないようにするため。
各プロジェクトの compose や devcontainer.json は書き換えない。

オプション:
  --pull   作り直す前に git pull --ff-only する（利用者が明示したときだけ）

終了コード: 0 = 作り直した / 1 = 失敗（pull・ユニットの停止・作り直し） / 2 = 使い方か設定の誤り
失敗したとき: pull の失敗は手で解消してからやり直す。作り直しの失敗は出力を読み、dev doctor <名前>。
EOF
}

help_doctor() {
  cat <<'EOF'
dev doctor — 「コンテナは動いているのに入れない」を見分ける。

使い方:
  dev doctor <名前>

出す項目: コンテナの有無と状態 / exec が実際に通るか / cgroup の pids.current と pids.max /
pids の上限に当たった回数 / ゾンビの数 / memory.events の oom_kill / ユニットの状態 / ユニットのログの末尾。
cgroup は /proc/<コンテナの PID>/cgroup から求める（cgroup v2）。
pids の上限は、コンテナの cgroup から根まで遡り、上限のある階層のうち現在値 / 上限 の比が最大のもので
判定して、その階層を表示する（systemd の slice の TasksMax などに当たっていても見逃さない）。
exec は 30 秒（環境変数 DEV_EXEC_TIMEOUT で変えられる。1 以上の整数）で返らなければ FAIL にする。
TERM を送っても止まらないときは、さらに 5 秒（DEV_EXEC_KILL_GRACE。1 以上の整数）後に KILL する。

判定:
  FAIL  exec が通らないか返らない / pids が上限の 90% 以上 / pids.max が 0 /
        コンテナが無いか動いていない
  WARN  pids の上限に当たった回数が 1 以上 / ゾンビが 100 以上 / oom_kill が 1 以上
  （読めない項目、pids.max が数でも max でもない値のときも WARN）

終了コード: 0 = 問題なし / 1 = FAIL がある / 2 = 使い方か設定ファイルの誤り / 3 = WARN だけ
失敗したとき: FAIL なら dev rebuild <名前> で作り直す。WARN だけなら原因を調べてから判断する。
EOF
}

help_restart() {
  cat <<'EOF'
dev restart — 作り直さずにコンテナを再起動する。

使い方:
  dev restart <名前>

呼ぶ順序:
  1. コンテナを探す。無ければ、ユニットにも触らずに 1 で止まる（dev up <名前>）
  2. ユニット dev-up@<名前> を、dev rebuild と同じ基準で止める（inactive / failed / unknown /
     systemctl が無い、のときは触らない。状態の語が得られないときは、何も変えずに 1 で止まる）
  3. docker restart <コンテナ>
  4. 2 で止めたときだけ、ユニットを起こし直す。3 が失敗しても、INT / HUP / TERM で中断されても
     （ssh の切断など）起こし直してから終わる（中断の終了コードは 130 / 129 / 143）
ユニットを先に止めるのは、再起動でコンテナが一瞬止まったときに、ユニットが up を重ねないようにするため。
作り直しはしない（定義を変えたときは dev rebuild）。各プロジェクトの compose や devcontainer.json は書き換えない。

終了コード: 0 = 再起動した / 1 = 失敗（コンテナが無い・ユニットの停止・docker restart） / 2 = 使い方か設定の誤り
失敗したとき: 出力を読み、dev doctor <名前>。直らなければ dev rebuild <名前>。
EOF
}

help_stop() {
  cat <<'EOF'
dev stop — 意図してコンテナを止める。

使い方:
  dev stop <名前>

呼ぶ順序:
  1. ユニット dev-up@<名前> を、dev rebuild と同じ基準で先に止める
     （コンテナだけを止めると、ユニットが 30 秒後に起こし直すため）。止められなければ、コンテナには触らない
  2. docker stop <コンテナ>（無い・動いていないときは何もしない）
ユニットは disable しない。外部の機械を再起動すれば、ユニットが戻ってコンテナも戻る。
戻すとき: dev up <名前>、またはユニットを起こす systemctl --user start dev-up@<名前>.service
再起動の後も戻したくないときは、dev disable <名前> も行う。

終了コード: 0 = 止めた（元から無い・止まっているときも 0） / 1 = 失敗（ユニットの停止・docker stop） / 2 = 使い方か設定の誤り
EOF
}

help_logs() {
  cat <<'EOF'
dev logs — ユニットのログの末尾を出す。

使い方:
  dev logs <名前> [-n <行数>]

journalctl --user -u dev-up@<名前>.service -n <行数> --no-pager を呼ぶ。行数の既定は 50（1 以上の整数）。

オプション:
  -n <行数>   末尾から出す行数

終了コード: 0 = 成功 / 1 = journalctl が失敗した（または無い） / 2 = 使い方か設定の誤り
EOF
}

help_enable() {
  cat <<'EOF'
dev enable — ユニットを有効にして起こす。

使い方:
  dev enable <名前>

systemctl --user enable --now dev-up@<名前>.service を呼ぶ。外部の機械の起動時から、
ユニットがコンテナを起こして保つようになる。ユニットを入れる手順は README の「ユニットを入れる」。

終了コード: 0 = 成功 / 1 = systemctl が失敗した（または無い） / 2 = 使い方か設定の誤り
EOF
}

help_disable() {
  cat <<'EOF'
dev disable — ユニットを無効にして止める。

使い方:
  dev disable <名前>

systemctl --user disable --now dev-up@<名前>.service を呼ぶ。コンテナは止めない
（止めるときは dev stop <名前>）。無効にすると、コンテナが止まっても自動では戻らない。
戻すときは dev enable <名前>。

終了コード: 0 = 成功 / 1 = systemctl が失敗した（または無い） / 2 = 使い方か設定の誤り
EOF
}

help_exec() {
  cat <<'EOF'
dev exec — tmux を介さずに、コンテナの中でコマンドを 1 つ実行する。

使い方:
  dev exec <名前> -- <コマンド...>

コンテナが動いていなければ、dev attach と同じく案内して 1 で止まる（自分では起こさない）。
動いていれば devcontainer exec --workspace-folder <パス> <コマンド...> を呼び、-- より後ろを
そのまま渡す。コマンドの先頭が - で始まるものは渡せない（devcontainer 自身のオプションと読まれるため）。
例: dev exec <名前> -- codex login --device-auth
ssh 越し（ssh -t <ホスト> .local/bin/dev exec ...）では、外部の機械のログインシェルが引数を
もう一度分割するので、ssh の引数のクォートが 1 段剥がれる。空白を含む引数や sh -c '...' は、
ssh のコマンド全体をクォートして、外側と内側の二重に包む。

終了コード: 0 = コマンドが成功 / 1 = コンテナが動いていない / 2 = 使い方か設定の誤り /
            それ以外 = コンテナの中のコマンドの終了コードをそのまま返す
EOF
}

help_self-update() {
  cat <<'EOF'
dev self-update — dev 自身を、DCB の公開リリースの版へ置き換える。

使い方:
  dev self-update [--version <vX.Y.Z>]

呼ぶ順序:
  1. 置き換え先（この dev）が、リンクでなく、devhost の dev.sh であることを確かめる（先頭 2 行）
  2. 公開リリースから RELEASE-MANIFEST.json と PACKAGE_ARCHIVE.tar.gz を取得する
     （既定は最新。--version でその版に固定する）
  3. マニフェストに記録された archive の SHA-256 と、取得した archive のハッシュを照合する
  4. archive から ./devhost/dev.sh を取り出し、devhost の dev.sh であることと構文を確かめる
  5. 同じディレクトリの一時ファイルへ写し、mv で置き換える
どれか 1 つでも外れたら、何も置き換えずに 1 で止まる。手動の入手（README の「devhost を入手する」）と
同じ照合。dev.sh だけを置き換える（dev-up@.service や設定ファイルには触らない）。
curl / jq / tar と、sha256sum または shasum が要る。

オプション:
  --version <vX.Y.Z>   取得する版（既定は最新）

終了コード: 0 = 置き換えた（すでに同じ版なら置き換えずに 0） / 1 = 失敗（取得・照合・置き換え先の確認・置き換え） / 2 = 使い方の誤り
EOF
}

help_help() {
  cat <<'EOF'
dev help — サブコマンドの説明を出す。

使い方:
  dev help                  使い方の一覧
  dev help <サブコマンド>    ls / up / attach / supervise / rebuild / doctor /
                            restart / stop / logs / enable / disable / exec / self-update の説明

終了コード: 0 = 成功 / 2 = 知らないサブコマンド
EOF
}

# help の対象は、help_<名前> の関数があるサブコマンド（一覧を別に持たない）。
list_help_subcommands() {
  local f
  for f in $(compgen -A function help_); do
    printf '%s\n' "${f#help_}"
  done
}

cmd_help() {
  [[ $# -le 1 ]] || usage_error "使い方: dev help [サブコマンド]"
  if [[ $# -eq 0 ]]; then
    usage
    return 0
  fi
  if [[ "$1" =~ ^[a-z][a-z-]*$ ]] && declare -F "help_$1" >/dev/null; then
    "help_$1"
    return 0
  fi
  usage_error "知らないサブコマンドです: $1（$(list_help_subcommands | tr '\n' ' ')）"
}

main() {
  [[ $# -ge 1 ]] || { usage >&2; exit 2; }
  local sub="$1"
  shift
  case "$sub" in
    ls) cmd_ls "$@" ;;
    up) cmd_up "$@" ;;
    attach) cmd_attach "$@" ;;
    supervise) cmd_supervise "$@" ;;
    rebuild) cmd_rebuild "$@" ;;
    doctor) cmd_doctor "$@" ;;
    restart) cmd_restart "$@" ;;
    stop) cmd_stop "$@" ;;
    logs) cmd_logs "$@" ;;
    enable) cmd_enable "$@" ;;
    disable) cmd_disable "$@" ;;
    exec) cmd_exec "$@" ;;
    self-update) cmd_self_update "$@" ;;
    help) cmd_help "$@" ;;
    -h | --help) usage ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
