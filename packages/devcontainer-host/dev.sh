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
#   dev doctor --runner <名前>  自前のランナーの点検（イメージ・PAT ファイルの権限・ユニット）
#   dev runner build            自前のランナーのイメージを作る
#   dev runner run <名前>       使い捨てのランナーのコンテナを起こして、止まるまで待つ（ユニットから使う）
#   dev restart <名前>          作り直さずに再起動する（ユニットを止めて、docker restart して、起こし直す。compose なら全体）
#   dev stop <名前>             意図して止める（ユニットを先に止めてから、コンテナを止める。compose なら全体）
#   dev logs <名前> [-n <行数>]  ユニットのログの末尾（既定 50 行）
#   dev enable <名前>           ユニットを有効にして起こす（起動時から保つ）
#   dev disable <名前>          ユニットを無効にして止め、コンテナも止める（再起動の後も止めたまま）
#   dev exec <名前> -- <コマンド...>  tmux を介さずにコンテナの中でコマンドを 1 つ実行する
#   dev self-update [--version <vX.Y.Z>]  dev 自身を devcontainer-host の公開リリースの版へ置き換える
#   dev version                 dev の版を出す（`dev --version` も同じ）
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

# dev の版。公開する版（リリースのタグ）は、リリースの手順がこの行を書き換えて配る
# （scripts/release-packages.sh の stamp_host_version）。リポジトリの中の値は、次に出す版の目印で、
# 公開物の値ではない。行の形（DEV_VERSION="vX.Y.Z"）を変えると、リリースの手順が止まる。
DEV_VERSION="v0.2.0"

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
  dev doctor --runner <名前>
  dev runner build
  dev runner run <名前>     （systemd のユニット dev-runner@.service から使う）
  dev runner net script|unit
  dev restart <名前>
  dev stop <名前>
  dev logs <名前> [-n <行数>]
  dev enable <名前>
  dev disable <名前>
  dev exec <名前> -- <コマンド...>
  dev self-update [--version <vX.Y.Z>]
  dev version
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

# 止める・再起動する対象のコンテナを集める（結果は T_ROWS に「ID 状態」を 1 要素ずつ）。
# 対象は、devcontainer のコンテナ（app）と、それが compose で動いているなら、その compose のプロジェクトの
# コンテナ全体（VS Code の stopCompose と同じ範囲。DB などの別のサービスを含む）。compose かどうかは
# app のコンテナの label com.docker.compose.project で見る。各プロジェクトの compose ファイルは読まず、
# 書き換えもしない。label が無ければ app のコンテナ 1 つだけ。コンテナが無ければ T_ROWS は空。
# docker の問い合わせが失敗したら 1 を返す（「無い」と区別するため）。
T_ROWS=()
target_rows() {
  local row id proj out line
  T_ROWS=()
  row="$(container_of "$1")" || return 1
  [[ -n "$row" ]] || return 0
  id="${row%% *}"
  proj="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$id")" || return 1
  if [[ -z "$proj" || "$proj" == "<no value>" ]]; then
    T_ROWS=("$row")
    return 0
  fi
  out="$(docker ps -a --filter "label=com.docker.compose.project=$proj" --format '{{.ID}} {{.State}}')" || return 1
  while IFS= read -r line; do
    [[ -z "$line" ]] || T_ROWS+=("$line")
  done <<<"$out"
  [[ ${#T_ROWS[@]} -gt 0 ]] || T_ROWS=("$row")
}

# 作り直さずに再起動する。rebuild と同じく、ユニットが動いていれば先に止め（docker restart で
# コンテナが一瞬止まると、ユニットの supervise が 0 以外で抜けて up を重ねうる）、
# 止めたときだけ起こし直す。中断（ssh の切断など）でも起こし直す。
# 対象は compose のプロジェクト全体（compose で動くとき。target_rows）。
cmd_restart() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev restart <名前>"
  load_projects
  find_project "$1"
  need_project_dir
  need docker "Docker Engine を入れてください。"
  local name="$1" path="${P_PATHS[$IDX]}" unit="dev-up@${1}.service" rc=0 ids=() r
  # docker の問い合わせの失敗は「コンテナが無い」と区別する（失敗を空として扱うと、在るコンテナを無いと取り違える）。
  target_rows "$path" || die "$name: コンテナの状態を引けませんでした（docker の問い合わせが失敗）。何も再起動していません。"
  # コンテナが無いなら、ユニットにも触らずに止まる（作るのは dev up / dev rebuild の役目）。
  [[ ${#T_ROWS[@]} -gt 0 ]] || die "$name: コンテナがありません。dev up $name で起こしてください（再起動は在るコンテナだけを対象にします）。"
  for r in "${T_ROWS[@]}"; do ids+=("${r%% *}"); done
  unit_probe "$name" "$unit" "再起動して"
  unit_guard_begin "$name" "$unit" "再起動して" "再起動の途中で up が重ならないように"
  if [[ "$HAD_UNIT" -eq 1 ]]; then rb_say "[$PROG] $name: コンテナ ${ids[*]} を再起動します。"; else echo "[$PROG] $name: コンテナ ${ids[*]} を再起動します。"; fi
  docker restart "${ids[@]}" >/dev/null || rc=$?
  unit_guard_end "$name" "$unit" || rc=1
  [[ "$rc" -eq 0 ]] || die "$name: 再起動が失敗しました（終了コード $rc）。原因の切り分け: dev doctor $name"
  echo "[$PROG] $name: 再起動しました。"
}

# コンテナを止める（dev stop と dev disable が共有する）。対象は target_rows の範囲（compose のプロジェクト全体）。
# 止まりきった状態（exited / created / dead）のコンテナは、コンテナごとに止めない。paused / restarting などは
# running でなくてもコンテナが残り、また動きうるので止める。
# docker の問い合わせの失敗は「コンテナが無い」と区別する。ユニットは止めたあとなので、その旨を添える。
stop_containers() {
  local name="$1" path="$2" r id state ids=()
  target_rows "$path" || die "$name: コンテナの状態を引けませんでした（docker の問い合わせが失敗）。コンテナが止まったかは分かりません。ユニットは止めたままです。確かめる: docker ps"
  if [[ ${#T_ROWS[@]} -eq 0 ]]; then
    rb_say "[$PROG] $name: コンテナがありません。止めるものはありません。"
    return 0
  fi
  for r in "${T_ROWS[@]}"; do
    id="${r%% *}"
    state="${r#* }"
    case "$state" in
      exited | created | dead) rb_say "[$PROG] $name: コンテナ $id は動いていません（$state）。" ;;
      *)
        rb_say "[$PROG] $name: コンテナ $id（$state）を止めます。"
        ids+=("$id")
        ;;
    esac
  done
  [[ ${#ids[@]} -eq 0 ]] || docker stop "${ids[@]}" >/dev/null || die "$name: docker stop が失敗しました（コンテナ ${ids[*]}）。ユニットは止めたままです。戻す: dev enable $name"
}

# 意図して止める。ユニットを先に止めてから、コンテナを止める（先にコンテナだけを止めると、
# ユニットの supervise が 30 秒後に起こし直す）。ユニットは disable しない。
# 戻すのは dev enable（enable --now は、無効のユニットにも、有効のまま止まっているユニットにも効く。
# dev up はコンテナを起こすだけで、止めたユニットは起き直らない）。
cmd_stop() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev stop <名前>"
  load_projects
  find_project "$1"
  # need_project_dir は見ない。コンテナはパスのラベルで探すので、登録先のディレクトリを動かした・消した
  # あとでも、動き続けるユニットとコンテナを止められるようにする。
  need docker "Docker Engine を入れてください。"
  local name="$1" unit="dev-up@${1}.service"
  # 止めるのが目的なので、HUP（ssh の切断）と PIPE（閉じた出力）は無視して、ユニットを止めたあとの
  # docker stop まで必ず走らせる（rebuild / restart のように起こし直す必要は無い）。
  trap '' HUP PIPE
  unit_probe "$name" "$unit" "止めて"
  if [[ "$HAD_UNIT" -eq 1 ]]; then
    rb_say "[$PROG] $name: ユニット $unit（$USTATE）を止めます（コンテナだけを止めると起こし直されるため、先に止める）。"
    systemctl --user stop "$unit" || die "$name: ユニット $unit を止められませんでした。コンテナには触っていません。"
  fi
  stop_containers "$name" "${P_PATHS[$IDX]}"
  case "$USTATE" in
    unknown | -)
      # ユニットを入れていない、または systemctl が無い機械では、dev enable は使えない。
      rb_say "[$PROG] $name: 止めました。"
      rb_say "[$PROG] 戻す: dev up $name（ユニット $unit が無いので、コンテナを起こすだけ）"
      ;;
    *)
      rb_say "[$PROG] $name: 止めました。ユニットは disable していません（有効なら、外部の機械の再起動の後は戻ります）。"
      rb_say "[$PROG] 戻す: dev enable $name（ユニットを有効にして起こす。コンテナも戻る。dev up ではユニットは起き直りません）"
      ;;
  esac
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

# ユニットを無効にして止め、dev stop と同じ順番（ユニット → コンテナ）でコンテナまで止める。
# 再起動の後も止めたままにするため。ユニットを止めるのは disable --now（先）、コンテナの停止は後。
# コンテナを止める処理（compose 全体、docker ps の失敗の区別）は dev stop と共有する。
cmd_disable() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev disable <名前>"
  load_projects
  find_project "$1"
  # dev stop と同じく need_project_dir は見ない（登録先のディレクトリが無くても、ユニットを無効にできるように）。
  need systemctl "systemd の systemctl が要ります（dev-up@.service を使う機械で使う）。"
  # dev stop と同じく、止めるのが目的なので HUP と PIPE は無視する。
  trap '' HUP PIPE
  systemctl --user disable --now "dev-up@${1}.service" || die "$1: ユニット dev-up@${1}.service を無効にできませんでした。コンテナには触っていません。"
  rb_say "[$PROG] $1: ユニット dev-up@${1}.service を無効にして止めました。"
  # docker の確かめはユニットを無効にした後。docker が無い機械でも、再起動の後に起こさないことは先に済ませる。
  need docker "Docker Engine を入れてください（ユニットは無効にしました。コンテナは止めていません）。"
  stop_containers "$1" "${P_PATHS[$IDX]}"
  rb_say "[$PROG] $1: 止めました。ユニットが無効なので、外部の機械の再起動の後も戻りません。"
  rb_say "[$PROG] 戻す: dev enable $1"
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

# ── runner（GitHub Actions の自前のランナー）──────────────────────────────────
# 設定ファイル runners の 1 行は「名前 組織 [キー=値 ...]」（書式は runners.example）。
# 読んだ結果は projects と同じく並びの配列に置く。
R_NAMES=()
R_ORGS=()
R_LABELS=()
R_DOCKER=()
R_PAT=()
R_LAN=()
R_GROUP=()
# ランナーのイメージに使う公式のランナーの版（設定ファイルの runner_version=X.Y.Z）。空なら Dockerfile の既定値。
R_VERSION=""
# 設定の誤りなど、起こし直しても直らない失敗の終了コード（EX_CONFIG）。ユニットの RestartPreventExitStatus が見る。
EXIT_PERMANENT=78

# ランナー専用の Docker ネットワークとそのブリッジ名。ブリッジ名は規則（root のスクリプト）と一致させる必要があるため固定する
# （Docker が付ける br-<ID> はネットワークを作り直すたびに変わる）。規則側の綴りは runner_net_script の BRIDGE と同じ。
RUNNER_NET_NAME="dev-runner"
RUNNER_NET_BRIDGE="dev-runner0"

runners_file() {
  if [[ -n "${DEV_RUNNERS_FILE:-}" ]]; then
    printf '%s\n' "$DEV_RUNNERS_FILE"
  else
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/dev/runners"
  fi
}

# ランナーのイメージの名前と、そのビルドに使う Dockerfile の置き場所。
runner_image() { printf '%s\n' "${DEV_RUNNER_IMAGE:-dev-runner:local}"; }
runner_dockerfile() {
  if [[ -n "${DEV_RUNNER_DOCKERFILE:-}" ]]; then
    printf '%s\n' "$DEV_RUNNER_DOCKERFILE"
  else
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/dev/runner.Dockerfile"
  fi
}
# ジョブへ渡すホストの Docker のソケット（docker=yes のときだけ使う）。
runner_docker_sock() { printf '%s\n' "${DEV_RUNNER_DOCKER_SOCK:-/var/run/docker.sock}"; }
# GitHub 上のランナーの名前。別の機械が同じ設定の名前を使っていても取り違えないよう、ホスト名を前に付ける
# （止めたときに外す相手を、この名前の完全一致で選ぶ）。
runner_github_name() { printf '%s-%s\n' "${DEV_RUNNER_HOSTNAME:-${HOSTNAME:-host}}" "$1"; }

load_runners() {
  local file lineno=0 line name org kv key val i labels dock pat grp
  file="$(runners_file)"
  if [[ ! -f "$file" ]]; then
    usage_error "設定ファイルがありません: $file
[$PROG] 雛形（runners.example）を写して、名前と組織を 1 行ずつ書いてください。"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    line="${line%%#*}"
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    [[ $# -gt 0 ]] || continue
    if [[ $# -eq 1 && "$1" == runner_version=* ]]; then
      R_VERSION="${1#runner_version=}"
      [[ "$R_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage_error "$file:$lineno: runner_version は X.Y.Z の形です: $R_VERSION"
      continue
    fi
    if [[ $# -lt 2 ]]; then
      usage_error "$file:$lineno: 「名前 組織」の 2 つが要ります: $line"
    fi
    name="$1" org="$2"
    shift 2
    if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
      usage_error "$file:$lineno: 名前に使えるのは英数字と _ . - だけです（systemd のインスタンス名にもなるため）: $name"
    fi
    if [[ ! "$org" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
      usage_error "$file:$lineno: 組織名に使えるのは英数字と - だけです: $org"
    fi
    for ((i = 0; i < ${#R_NAMES[@]}; i++)); do
      [[ "${R_NAMES[$i]}" == "$name" ]] && usage_error "$file:$lineno: 名前が重複しています: $name"
    done
    labels="" dock="no" lan="deny" grp=""
    pat="$(dirname "$file")/runner-pat"
    for kv in "$@"; do
      if [[ "$kv" != *=* ]]; then
        usage_error "$file:$lineno: 3 つ目以降は キー=値 で書きます: $kv"
      fi
      key="${kv%%=*}" val="${kv#*=}"
      [[ -n "$val" ]] || usage_error "$file:$lineno: 値が空です: $kv"
      case "$key" in
        labels)
          [[ "$val" =~ ^[A-Za-z0-9_.-]+(,[A-Za-z0-9_.-]+)*$ ]] || usage_error "$file:$lineno: labels はカンマ区切りの英数字と _ . - です: $val"
          labels="$val"
          ;;
        docker)
          case "$val" in
            yes | no) dock="$val" ;;
            *) usage_error "$file:$lineno: docker は yes か no です: $val" ;;
          esac
          ;;
        lan)
          case "$val" in
            allow | deny) lan="$val" ;;
            *) usage_error "$file:$lineno: lan は allow か deny です: $val" ;;
          esac
          ;;
        group)
          [[ "$val" =~ ^[A-Za-z0-9._-]+$ ]] || usage_error "$file:$lineno: group に使えるのは英数字と . _ - だけです（空白は使えません）: $val"
          grp="$val"
          ;;
        pat_file)
          [[ "$val" == /* ]] || usage_error "$file:$lineno: pat_file は絶対パスで書きます（~ や \$HOME は展開しません）: $val"
          pat="$val"
          ;;
        *) usage_error "$file:$lineno: 知らないキーです（labels / docker / lan / group / pat_file）: $key" ;;
      esac
    done
    R_NAMES+=("$name")
    R_ORGS+=("$org")
    R_LABELS+=("$labels")
    R_DOCKER+=("$dock")
    R_LAN+=("$lan")
    R_GROUP+=("$grp")
    R_PAT+=("$pat")
  done <"$file"
  if [[ ${#R_NAMES[@]} -eq 0 ]]; then
    usage_error "設定ファイルにランナーが 1 つもありません: $file"
  fi
}

RIDX=-1
find_runner() {
  local name="$1" i
  for ((i = 0; i < ${#R_NAMES[@]}; i++)); do
    if [[ "${R_NAMES[$i]}" == "$name" ]]; then
      RIDX=$i
      return 0
    fi
  done
  usage_error "登録されていないランナーです: $name（登録済み: ${R_NAMES[*]}）"
}

# 起こし直しても直らない失敗（設定・PAT の権限・イメージ無し）。専用の終了コードで抜け、ユニットが再起動しない。
die_permanent() { echo "[$PROG] $*" >&2; exit "$EXIT_PERMANENT"; }

# ファイルの権限（8 進。例: 600）を出す。GNU の stat と BSD の stat の両方を試す。
file_mode_of() {
  local m
  m="$(stat -L -c %a "$1" 2>/dev/null)" || m="$(stat -L -f %Lp "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$m"
}

file_uid_of() {
  local u
  u="$(stat -L -c %u "$1" 2>/dev/null)" || u="$(stat -L -f %u "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$u"
}

file_gid_of() {
  local g
  g="$(stat -L -c %g "$1" 2>/dev/null)" || g="$(stat -L -f %g "$1" 2>/dev/null)" || return 1
  printf '%s\n' "$g"
}

# PAT ファイルを使ってよいか。だめなら理由を標準出力へ出して 1 を返す。**値は決して出さない。**
# group / other に権限があれば拒む（他のユーザーが読めるファイルに PAT を置かせないため）。
runner_pat_problem() {
  local f="$1" mode
  if [[ ! -f "$f" ]]; then
    echo "PAT ファイルがありません（通常のファイルではありません）: $f"
    return 1
  fi
  mode="$(file_mode_of "$f")" || {
    echo "PAT ファイルの権限を読めません: $f"
    return 1
  }
  # group / other に権限があれば拒む（400 のような、より厳しい権限は許す）。
  if [[ ! "$mode" =~ ^[0-7]+$ ]] || (( (8#$mode & 8#077) != 0 )); then
    echo "PAT ファイルの権限が緩すぎます（$mode。group / other に権限があります）: $f（chmod 600 で直してください）"
    return 1
  fi
  if [[ ! -r "$f" ]]; then
    echo "PAT ファイルを読めません: $f"
    return 1
  fi
  return 0
}

# PAT の値。標準の環境には出さない（export しない）。
# 親の環境で RUNNER_PAT が export されていると、再代入しても export 属性が残り、ファイルから読んだ PAT が
# curl / docker の子プロセスの環境に出る。unset で属性ごと消してから、export していない変数として持つ。
unset RUNNER_PAT
RUNNER_PAT=""

# PAT ファイルを読む。空白と改行を取り除き、PAT の形（英数字と _）でなければ拒む
# （curl の設定へ書くとき、引用符や改行が混ざって別の設定として読まれるのを防ぐ）。
runner_pat_load() {
  local f="$1" v
  v="$(tr -d '[:space:]' <"$f")" || return 1
  if [[ -z "$v" ]]; then
    echo "PAT ファイルが空です: $f" >&2
    return 1
  fi
  if [[ ! "$v" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "PAT ファイルの中身が PAT の形ではありません（英数字と _ だけのはずです）: $f" >&2
    return 1
  fi
  RUNNER_PAT="$v"
}

# GitHub の API を呼ぶ。応答を標準出力へ出す。
# **PAT はコマンドラインの引数に出さない**（ps で見えるため）。curl の設定を標準入力から渡す
# （printf は bash の組み込みなので、引数としても外部のプロセスには現れない）。
# 使い方: runner_api <メソッド> <パス>
# HTTP ステータスは curl の -w で読む(-f は使わない)。戻り値: 0 = 成功(2xx。本文を出す) /
# 10 = 直らない失敗(401・403・404: PAT の失効・権限不足・組織名の誤り) / 11 = 一時的な失敗(429・5xx・通信の失敗など)。
runner_api() {
  local method="$1" path="$2" out code
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$RUNNER_PAT" |
    curl -sSL -K - -X "$method" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      -w '\n%{http_code}' \
      "${DEV_GITHUB_API:-https://api.github.com}$path")" || return 11
  code="${out##*$'\n'}"
  case "$code" in
    2??)
      printf '%s\n' "${out%$'\n'*}"
      return 0
      ;;
    401 | 403 | 404)
      echo "[$PROG] GitHub の API が HTTP $code を返しました: $method $path" >&2
      return 10
      ;;
    *)
      echo "[$PROG] GitHub の API が HTTP $code を返しました: $method $path" >&2
      return 11
      ;;
  esac
}

cmd_runner() {
  local sub="${1:-}"
  [[ $# -ge 1 ]] || usage_error "使い方: dev runner build | dev runner run <名前> | dev runner net script|unit"
  shift
  case "$sub" in
    build) cmd_runner_build "$@" ;;
    run) cmd_runner_run "$@" ;;
    net) cmd_runner_net "$@" ;;
    *) usage_error "知らない runner のサブコマンドです: $sub（build / run / net）" ;;
  esac
}

# 設定ファイルの runner_version だけを読む（build はランナーの行が 0 件でも通す）。
load_runners_version() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line%%#*}"
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    if [[ $# -eq 1 && "$1" == runner_version=* ]]; then
      R_VERSION="${1#runner_version=}"
    fi
  done <"$(runners_file)"
}

# ランナーのイメージを作る。Dockerfile は標準入力から渡す（ビルドの文脈を作らない。設定ディレクトリの
# PAT のファイルが、ビルドの文脈としてデーモンへ送られることがないように）。
cmd_runner_build() {
  [[ $# -eq 0 ]] || usage_error "使い方: dev runner build"
  need docker "Docker Engine を入れてください。"
  local df img
  df="$(runner_dockerfile)"
  [[ -f "$df" ]] || die "Dockerfile がありません: $df（install.sh が置きます。README.md の「自前のランナー」）"
  img="$(runner_image)"
  # 公式のランナーの版。環境変数 > 設定ファイルの runner_version > Dockerfile の既定値。Dockerfile は編集させない。
  local ver="${DEV_RUNNER_VERSION:-}" bargs=()
  if [[ -z "$ver" && -f "$(runners_file)" ]]; then
    load_runners_version
    ver="$R_VERSION"
  fi
  if [[ -n "$ver" ]]; then
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage_error "ランナーの版は X.Y.Z の形です: $ver"
    bargs=(--build-arg "RUNNER_VERSION=$ver")
  fi
  echo "[$PROG] ランナーのイメージを作ります: $img（$df${ver:+、ランナーの版 $ver}）"
  docker build ${bargs[@]+"${bargs[@]}"} -t "$img" - <"$df" || die "ランナーのイメージを作れませんでした: $img"
}

# 後始末が要るか。コンテナを起こしたあと、正常に終わらなかったとき（失敗・TERM / INT / HUP）だけ 1 にする。
# ephemeral のジョブが正常に終わったときは、GitHub 側でランナーが外れているので何もしない。
RUNNER_NEED_CLEANUP=0
RUNNER_CLEANED=0
RUNNER_CNAME=""
RUNNER_CHILD=""
RUNNER_ORG=""
RUNNER_GHNAME=""
runner_cleanup() {
  [[ "$RUNNER_CLEANED" -eq 0 ]] || return 0
  RUNNER_CLEANED=1
  trap - EXIT INT TERM HUP
  [[ "$RUNNER_NEED_CLEANUP" -eq 1 && -n "$RUNNER_CNAME" ]] || return 0
  # 動いているコンテナがあれば止める（--rm なので、止まれば消える）。もう無ければ何もしない。
  docker stop "$RUNNER_CNAME" >/dev/null 2>&1 || true
  if [[ -n "$RUNNER_CHILD" ]]; then wait "$RUNNER_CHILD" 2>/dev/null || true; fi
  runner_deregister
}

# 組織に登録されているランナーのうち、この名前のものを外す。無ければ何もしない。失敗は警告にとどめる。
# 一覧は全ページを読む（1 ページ 100 件。件数が満たないページで終わる）。
runner_deregister() {
  local list rids="" page=1 n id
  [[ -n "$RUNNER_PAT" && -n "$RUNNER_ORG" ]] || return 0
  while [[ "$page" -le 100 ]]; do
    if ! list="$(runner_api GET "/orgs/$RUNNER_ORG/actions/runners?per_page=100&page=$page")"; then
      echo "[$PROG] 警告: 組織のランナーの一覧を取得できませんでした。登録が残っていれば、GitHub の設定から外してください: $RUNNER_GHNAME" >&2
      break
    fi
    rids="$rids $(printf '%s\n' "$list" | jq -r --arg n "$RUNNER_GHNAME" '.runners[]? | select(.name == $n) | .id')" || true
    n="$(printf '%s\n' "$list" | jq -r '.runners | length')" || n=0
    [[ "$n" =~ ^[0-9]+$ && "$n" -ge 100 ]] || break
    page=$((page + 1))
  done
  for id in $rids; do
    if runner_api DELETE "/orgs/$RUNNER_ORG/actions/runners/$id" >/dev/null; then
      echo "[$PROG] 組織から登録を外しました: $RUNNER_GHNAME"
    else
      echo "[$PROG] 警告: 組織からランナーを外せませんでした（ジョブの実行中は外せません）。GitHub の設定から外してください: $RUNNER_GHNAME" >&2
    fi
  done
}

# 同じ名前のランナーを 2 本同時に動かさないためのロック。2 本目が `docker rm -f` や後始末の `docker stop` で
# 動いているジョブのコンテナを殺し、`--replace` で登録を奪うのを防ぐ。ロックはプロセスの終了で外れる
# (dev だけが強制終了されたときの、動き続けるコンテナは、起動時に前回のコンテナを待って扱う)。
# 取れなければ、何も消さずに 75（一時的な失敗。ユニットは起こし直す）で抜ける。
runner_lock() {
  local dir lockf owner mode
  # 置き場所は、自分だけが書けるディレクトリにする(予測できる名前を、共有の /tmp に置かない)。
  # 環境変数 DEV_RUNNER_LOCK_DIR で変えられる。
  dir="${DEV_RUNNER_LOCK_DIR:-${XDG_RUNTIME_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/dev}}"
  if [[ ! -e "$dir" ]]; then
    # 権限 700 が付くのは最も深いディレクトリだけ(親は既定の権限)。それで足りる。
    # shellcheck disable=SC2174
    mkdir -p -m 700 "$dir" || die_permanent "$1: ロックのディレクトリを作れません: $dir"
  fi
  [[ -d "$dir" ]] || die_permanent "$1: ロックの置き場所がディレクトリではありません: $dir"
  owner="$(file_uid_of "$dir")" || die_permanent "$1: ロックのディレクトリの所有者を読めません: $dir"
  mode="$(file_mode_of "$dir")" || die_permanent "$1: ロックのディレクトリの権限を読めません: $dir"
  [[ "$owner" == "$UID" ]] || die_permanent "$1: ロックのディレクトリの所有者が自分ではありません: $dir"
  if [[ ! "$mode" =~ ^[0-7]+$ ]] || (( (8#$mode & 8#022) != 0 )); then
    die_permanent "$1: ロックのディレクトリに group / other の書き込み権限があります($mode): $dir(自分だけが書ける場所にしてください)"
  fi
  lockf="$dir/dev-runner-$1.lock"
  # リンクを辿らない: 既存のものがリンクや通常のファイルでなければ拒む。切り詰めない形(>>)で開く。
  if [[ -L "$lockf" ]]; then
    die_permanent "$1: ロックのファイルがリンクです(辿りません): $lockf"
  fi
  if [[ -e "$lockf" && ! -f "$lockf" ]]; then
    die_permanent "$1: ロックのファイルが通常のファイルではありません: $lockf"
  fi
  need flock "flock（util-linux）が要ります。"
  exec 9>>"$lockf" || die "$1: ロックのファイルを開けません: $lockf"
  if ! flock -n 9; then
    echo "[$PROG] $1: 同じ名前のランナーがすでに動いています（ロック $lockf）。何も消さずに終わります。" >&2
    exit 75
  fi
}

# ── runner の出口の制限（専用ネットワークと、root が入れる規則）─────────────────────
# ジョブが外部の機械の LAN・機械自身・リンクローカルへ届かないよう、ランナーを専用の Docker ネットワークで動かし、
# そのブリッジからの出口を規則（iptables）で止める。規則の追加には root が要るため、dev 本体は入れない。
# root で動く部分（スクリプトと systemd のシステムのユニット）は dev runner net script / unit が出力し、利用者が sudo で入れる。
# 規則が入ると、スクリプトが印のファイルを置く。dev runner run は印を確かめ、無ければ起動しない。

# 規則の印のファイル。1 行目が「bridge=<ブリッジ名>」。root だけが書ける場所（/run 配下）に置く。
runner_net_marker() { printf '%s\n' "${DEV_RUNNER_NET_MARKER:-/run/dev-runner-net/ready}"; }

# 印が無いとき待つ秒数。Docker の再起動では規則のユニットも入れ直すので、その間を待つ。
runner_net_wait() { printf '%s\n' "${DEV_RUNNER_NET_WAIT:-30}"; }

# 印のファイルを確かめる。無いときは一時的な失敗（1）で抜ける（規則のユニットが入れ終えるのを待つ間に、ユニットが起こし直す。
# 78 にすると RestartPreventExitStatus に当たって二度と起きないため）。ブリッジ名が合わないのは設定の誤りなので 78。
# 登録用のトークンを取る（API を呼ぶ）より前に呼ぶこと。起こし直しが API を消費しないようにするため。
runner_net_require() {
  local name="$1" marker waited=0 limit
  marker="$(runner_net_marker)"
  limit="$(runner_net_wait)"
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=0
  while [[ ! -f "$marker" && "$waited" -lt "$limit" ]]; do
    sleep 1
    waited=$((waited + 1))
  done
  if [[ ! -f "$marker" ]]; then
    die "$name: 出口の規則の印がありません: $marker。規則が入っていないまま動かさないため起動しません（ユニットが起こし直します）。規則を入れてください（dev runner net script / unit。README.md の「自前のランナー」）。LAN に届いてよいランナーは、設定ファイルで lan=allow にします"
  fi
  if ! grep -qxF "bridge=$RUNNER_NET_BRIDGE" "$marker"; then
    die_permanent "$name: 出口の規則の印のブリッジ名が、このバージョンの dev と合いません（期待 bridge=$RUNNER_NET_BRIDGE）: $marker。規則のスクリプトとユニットを、dev runner net script / unit で入れ直してください"
  fi
}

# 専用ネットワークが無ければ作る（IPv6 は無効、ブリッジ名は固定）。あれば、ブリッジ名と IPv6 が期待どおりかを確かめる。
runner_net_ensure() {
  local name="$1" out want="$RUNNER_NET_BRIDGE false"
  if out="$(docker network inspect --format '{{index .Options "com.docker.network.bridge.name"}} {{.EnableIPv6}}' "$RUNNER_NET_NAME" 2>&1)"; then
    [[ "$out" == "$want" ]] || die_permanent "$name: Docker のネットワーク $RUNNER_NET_NAME の設定が期待と違います（期待「$want」/ 実際「$out」）。docker network rm $RUNNER_NET_NAME で消してから起こし直してください"
    return 0
  fi
  case "$out" in
    *"No such network"* | *"not found"*) ;;
    *) die "$name: docker に問い合わせられません（デーモンが起きていないかもしれません）: $out" ;;
  esac
  if ! out="$(docker network create --driver bridge --ipv6=false -o "com.docker.network.bridge.name=$RUNNER_NET_BRIDGE" "$RUNNER_NET_NAME" 2>&1)"; then
    # 別のランナーが同時に作った場合は、作られていればよい。
    if out="$(docker network inspect --format '{{index .Options "com.docker.network.bridge.name"}} {{.EnableIPv6}}' "$RUNNER_NET_NAME" 2>&1)" && [[ "$out" == "$want" ]]; then
      return 0
    fi
    die "$name: Docker のネットワーク $RUNNER_NET_NAME を作れませんでした: $out"
  fi
  echo "[$PROG] $name: Docker のネットワーク $RUNNER_NET_NAME（ブリッジ $RUNNER_NET_BRIDGE、IPv6 無効）を作りました。"
}

# dev runner net script|unit: root で入れる部分を標準出力へ出す（dev 自身は何も入れない）。
cmd_runner_net() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev runner net script|unit"
  case "$1" in
    script) runner_net_script ;;
    unit) runner_net_unit ;;
    *) usage_error "使い方: dev runner net script|unit（知らない種類です: $1）" ;;
  esac
}

# 規則を入れる root のスクリプト（/usr/local/sbin/dev-runner-net）。単体で動く。
#   apply  規則を入れ直して、印を置く（冪等）
#   unmark 印だけを消す（規則は残す）
#   clear  印と規則を外す（利用者が明示して打つときだけ）
#   rules  入れる規則（iptables-restore に渡す内容）を出す。何も実行しない（試験用）
runner_net_script() {
  cat <<'EOF'
#!/usr/bin/env bash
# dev-runner-net — devhost の自前のランナー（専用の Docker ネットワーク）の出口を止める規則を入れる。
#
# root で動く。systemd のシステムのユニット dev-runner-net.service から呼ぶ（dev runner net unit）。
#   dev-runner-net apply   規則を入れ直して、印のファイルを置く（何度呼んでもよい）
#   dev-runner-net unmark  印のファイルだけを消す（規則は残す。ユニットの停止で呼ぶ）
#   dev-runner-net clear   印のファイルを消し、規則を外す（利用者が明示して打つときだけ）
#   dev-runner-net rules   入れる規則（iptables-restore に渡す内容）を出す。何も実行しない
#
# 入れ直しは iptables-restore --noflush の 1 回の取り込みで行う（鎖の中身の入れ替えと飛び先の追加が一度に切り替わる）。
# 止めるもの（ランナーのブリッジから出る、新しい接続）:
#   - FORWARD（DOCKER-USER から飛ぶ）: 10/8・172.16/12・192.168/16・169.254/16・100.64/10 への接続
#   - INPUT: この機械自身への接続（ブリッジのゲートウェイ、LAN 側のアドレスを含む）
# 通るもの: 上の帯の外（インターネット）。Docker の内蔵の DNS（127.0.0.11）はコンテナの中で応答する。
# 上流の DNS が LAN の帯にあって名前が引けないときは、環境変数 DEV_RUNNER_NET_ALLOW_DNS（空白区切りの IPv4）へ書くと、
# そのアドレスの 53 番だけを通す（/etc/default/dev-runner-net に書く）。
set -euo pipefail

BRIDGE="dev-runner0"
FWD_CHAIN="DEV-RUNNER-FWD"
IN_CHAIN="DEV-RUNNER-IN"
BLOCKED_CIDRS=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10)
STATE_DIR="${DEV_RUNNER_NET_STATE_DIR:-/run/dev-runner-net}"
MARKER="$STATE_DIR/ready"
ALLOW_DNS="${DEV_RUNNER_NET_ALLOW_DNS:-}"

die() { echo "[dev-runner-net] $*" >&2; exit 1; }

# 飛び先（DOCKER-USER / INPUT からランナーのブリッジの鎖へ）が既にあるか。
hook_exists() { iptables -C "$1" -i "$BRIDGE" -j "$2" 2>/dev/null; }

# iptables-restore --noflush に渡す内容を出す。引数は、足す飛び先（fwd / in。無ければ足さない）。
# 鎖の宣言（:鎖 - [0:0]）は、既にある鎖の中身を同じ取り込みの中で空にして入れ直す。1 回の取り込みで切り替わるので、制限の無い瞬間ができない。
restore_input() {
  local c a h
  echo "*filter"
  echo ":$FWD_CHAIN - [0:0]"
  echo ":$IN_CHAIN - [0:0]"
  for a in $ALLOW_DNS; do
    [[ "$a" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "DEV_RUNNER_NET_ALLOW_DNS に IPv4 でない値があります: $a"
    echo "-A $FWD_CHAIN -d $a -p udp --dport 53 -j ACCEPT"
    echo "-A $FWD_CHAIN -d $a -p tcp --dport 53 -j ACCEPT"
    echo "-A $IN_CHAIN -d $a -p udp --dport 53 -j ACCEPT"
    echo "-A $IN_CHAIN -d $a -p tcp --dport 53 -j ACCEPT"
  done
  for c in "${BLOCKED_CIDRS[@]}"; do
    echo "-A $FWD_CHAIN -d $c -m conntrack --ctstate NEW -j REJECT"
  done
  echo "-A $IN_CHAIN -m conntrack --ctstate NEW -j REJECT"
  for h in "$@"; do
    case "$h" in
      fwd) echo "-I DOCKER-USER -i $BRIDGE -j $FWD_CHAIN" ;;
      in) echo "-I INPUT -i $BRIDGE -j $IN_CHAIN" ;;
    esac
  done
  echo "COMMIT"
}

# 入れる規則の全文（飛び先も含む。何も実行しない）。
rules() { restore_input fwd in; }

need_restore() { command -v iptables-restore >/dev/null 2>&1 || die "iptables-restore がありません。何も入れていません"; }

apply() {
  local input hooks=()
  # 入れ直しの途中で失敗したとき、古い印が残って「規則が入っている」と読まれないよう、先に消す。
  rm -f "$MARKER"
  need_restore
  # 規則の生成に失敗したら（不正な DNS の指定など）、何も入れずに止まる。
  hook_exists DOCKER-USER "$FWD_CHAIN" || hooks+=(fwd)
  hook_exists INPUT "$IN_CHAIN" || hooks+=(in)
  input="$(restore_input ${hooks[@]+"${hooks[@]}"})"
  # DOCKER-USER が転送（FORWARD）の経路に入っていることを、何かを入れる前に確かめる。Docker が iptables を使っていない構成
  # （nftables のバックエンドなど）では、Docker は FORWARD から DOCKER-USER への飛び先を作らない。自分で鎖を作って入れても
  # 転送の経路に掛からないので、制限が効かないまま印を置くことになる。入っていなければ、何も入れず印も置かずに止まる。
  if ! iptables -C FORWARD -j DOCKER-USER 2>/dev/null; then
    die "FORWARD から DOCKER-USER への飛び先がありません。Docker が iptables を使っていない（nftables のバックエンド、--iptables=false など）か、Docker がまだ起きていません。この構成では出口の規則は効かないので、何も入れず印も置きません"
  fi
  # 鎖の中身の入れ替えと、足りない飛び先の追加を、1 回の取り込みで行う。失敗したら何も変わらず、印も置かない。
  printf '%s\n' "$input" | iptables-restore --noflush
  mkdir -p "$STATE_DIR"
  chmod 755 "$STATE_DIR"
  printf 'bridge=%s\n' "$BRIDGE" >"$MARKER.tmp"
  chmod 644 "$MARKER.tmp"
  mv -f "$MARKER.tmp" "$MARKER"
  echo "[dev-runner-net] 規則を入れました（ブリッジ $BRIDGE）"
}

unmark() {
  rm -f "$MARKER"
  echo "[dev-runner-net] 印を消しました（規則は残します）"
}

clear_rules() {
  local lines=() ch
  rm -f "$MARKER"
  need_restore
  # 飛び先の削除と鎖の削除を 1 回の取り込みにする。無いものを消すと取り込み全体が失敗するので、あるものだけを入れる。
  if hook_exists DOCKER-USER "$FWD_CHAIN"; then lines+=("-D DOCKER-USER -i $BRIDGE -j $FWD_CHAIN"); fi
  if hook_exists INPUT "$IN_CHAIN"; then lines+=("-D INPUT -i $BRIDGE -j $IN_CHAIN"); fi
  for ch in "$FWD_CHAIN" "$IN_CHAIN"; do
    if iptables -n -L "$ch" >/dev/null 2>&1; then lines+=("-F $ch" "-X $ch"); fi
  done
  if [[ ${#lines[@]} -gt 0 ]]; then
    { echo "*filter"; printf '%s\n' "${lines[@]}"; echo "COMMIT"; } | iptables-restore --noflush
  fi
  echo "[dev-runner-net] 規則を外しました"
}

case "${1:-}" in
  apply) apply ;;
  unmark) unmark ;;
  clear) clear_rules ;;
  rules) rules ;;
  *) die "使い方: dev-runner-net apply|unmark|clear|rules" ;;
esac
EOF
}

# 規則を入れるシステムのユニット（/etc/systemd/system/dev-runner-net.service）。
runner_net_unit() {
  cat <<'EOF'
# dev-runner-net.service — devhost の自前のランナーの出口を止める規則を入れる（root で動くシステムのユニット）。
#
# dev runner net unit で出力し、/etc/systemd/system/ へ置く。導入の手順は README.md の「自前のランナー」。
# Docker のデーモンが再起動するたびに入れ直す（PartOf）。Docker の再起動で DOCKER-USER が作り直されても、規則が外れたままにならない。
# 止めたとき（Docker の停止を含む）は、印だけを消し、規則は消さない。Docker の live-restore でコンテナが動き続けるあいだも、
# 制限が外れないようにするため。自分の鎖と飛び先は Docker の再起動でも残り、起動時の apply が 1 回の取り込みで入れ替える。
# 規則を外すのは、利用者が明示して dev-runner-net clear を打つときだけ。
# PartOf は Docker の停止と再起動しか伝えない。停止（印を消す）のあとに docker.service だけを起動しても印が戻らないよう、
# [Install] の WantedBy=docker.service で、Docker の起動に合わせてこのユニットも起動する（systemctl enable で効く）。

[Unit]
Description=devhost の自前のランナーの出口の規則（専用ブリッジから LAN と機械自身への接続を止める）
After=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
# 上流の DNS が LAN の帯にあるときの許可（DEV_RUNNER_NET_ALLOW_DNS="192.0.2.53" の形。無くてもよい）。
EnvironmentFile=-/etc/default/dev-runner-net
ExecStart=/usr/local/sbin/dev-runner-net apply
ExecStop=/usr/local/sbin/dev-runner-net unmark

[Install]
WantedBy=multi-user.target
WantedBy=docker.service
EOF
}

# systemd のユニット（dev-runner@.service）の ExecStart。1 回の起動で、ジョブを 1 つ受けて終わる。
# (1) PAT で登録用のトークンを取り、(2) --ephemeral のランナーを --rm のコンテナで動かし、
# (3) コンテナが止まったら抜ける。起こし直しはユニット（Restart=always）が行う。
# 設定の誤り・PAT の権限・イメージが無い、という直らない失敗は 78 で抜ける（ユニットは起こし直さない）。
cmd_runner_run() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev runner run <名前>"
  load_runners
  find_runner "$1"
  local name="$1" org="${R_ORGS[$RIDX]}" labels="${R_LABELS[$RIDX]}" dock="${R_DOCKER[$RIDX]}" patf="${R_PAT[$RIDX]}" lan="${R_LAN[$RIDX]}" grp="${R_GROUP[$RIDX]}"
  need docker "Docker Engine を入れてください。"
  need curl "curl を入れてください。"
  need jq "jq を入れてください。"
  # ロックを最初に取る（これより前に、動いているコンテナへ触る処理を置かない）。
  runner_lock "$name"
  local img why iout
  img="$(runner_image)"
  if ! iout="$(docker image inspect "$img" 2>&1)"; then
    # 「イメージが無い」と「デーモンに届かない」は分ける。後者は一時的なので起こし直す。
    case "$iout" in
      *"No such image"*) die_permanent "$name: ランナーのイメージがありません: $img（dev runner build で作ります）" ;;
      *) die "$name: docker に問い合わせられません（デーモンが起きていないかもしれません）: $iout" ;;
    esac
  fi
  # PAT は、group / other に権限があれば読む前に拒む。
  why="$(runner_pat_problem "$patf")" || die_permanent "$name: $why"
  runner_pat_load "$patf" || die_permanent "$name: PAT ファイルを読めませんでした"

  # 出口の制限。lan=allow のランナーだけが、専用ネットワークと規則の印の確認を外す（従来どおり既定のブリッジで動く）。
  local net_args=()
  if [[ "$lan" != "allow" ]]; then
    runner_net_require "$name"
    runner_net_ensure "$name"
    net_args=(--network "$RUNNER_NET_NAME")
  fi

  local sock="" gid="" args
  if [[ "$dock" == "yes" ]]; then
    sock="$(runner_docker_sock)"
    [[ -e "$sock" ]] || die_permanent "$name: docker=yes ですが、Docker のソケットがありません: $sock"
    gid="$(file_gid_of "$sock")" || die_permanent "$name: Docker のソケットのグループを読めません: $sock"
  fi

  RUNNER_CNAME="dev-runner-$name"
  RUNNER_ORG="$org"
  RUNNER_GHNAME="$(runner_github_name "$name")"
  trap runner_cleanup EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP

  # 前回のコンテナの扱い。ロックが示すのは dev のプロセスの生存だけで、dev が強制終了(SIGKILL など)されても
  # コンテナは動き続けうる。動いていれば(実行中のジョブがある)、終わるまで待ってから起動する。殺さない。
  # 止まっている残り(--rm が働かなかったもの)だけを消す。待っている間の TERM は、前回のコンテナを止めて登録を外してから抜ける。wait が失敗したら何も消さない。
  local prev=""
  prev="$(docker container inspect --format '{{.State.Status}}' "$RUNNER_CNAME" 2>/dev/null)" || prev=""
  case "$prev" in
    "") ;;
    running | restarting | paused)
      echo "[$PROG] $name: 前回のコンテナ $RUNNER_CNAME がまだ動いています。ジョブが終わるまで待ちます(殺しません)。"
      # 待っているあいだに止められた(TERM / INT / HUP)ら、前回のコンテナを止めて登録を外す(いまの起動と同じ後始末)。
      # 止められたユニットのコンテナが、ジョブを受け続けないようにするため。
      RUNNER_NEED_CLEANUP=1
      docker wait "$RUNNER_CNAME" >/dev/null 2>&1 &
      RUNNER_CHILD=$!
      local wrc=0
      wait "$RUNNER_CHILD" || wrc=$?
      RUNNER_CHILD=""
      if [[ "$wrc" -ne 0 ]]; then
        # wait の失敗は「終わった」ではない(Docker への接続障害など)。コンテナではジョブが続いているかもしれないので、
        # 何も消さず、止めもせずに、一時的な失敗(1)で抜ける。
        RUNNER_NEED_CLEANUP=0
        die "$name: 前回のコンテナ $RUNNER_CNAME の終了を待てませんでした(docker wait が失敗)。何も消していません。ユニットが起こし直します。"
      fi
      RUNNER_NEED_CLEANUP=0
      docker rm -f "$RUNNER_CNAME" >/dev/null 2>&1 || true
      ;;
    *) docker rm -f "$RUNNER_CNAME" >/dev/null 2>&1 || true ;;
  esac

  local resp tok arc=0
  resp="$(runner_api POST "/orgs/$org/actions/runners/registration-token")" || arc=$?
  if [[ "$arc" -eq 10 ]]; then
    # 401 / 403 / 404: 起こし直しても直らない。5 秒ごとに API を叩き続けないよう 78 で抜ける。
    die_permanent "$name: 登録用のトークンを取得できませんでした(PAT の失効・権限不足、または組織名の誤り)。PAT の権限(組織の Self-hosted runners: Read and write)と組織名($org)を確かめてください。直してから systemctl --user start dev-runner@$name.service で起こし直します"
  elif [[ "$arc" -ne 0 ]]; then
    die "$name: 登録用のトークンを取得できませんでした(API の不調か通信の失敗です。ユニットが起こし直します)"
  fi
  tok="$(printf '%s\n' "$resp" | jq -r '.token // empty')" || tok=""
  [[ -n "$tok" ]] || die "$name: 登録用のトークンが応答にありません"

  # コンテナへ渡すのは登録用のトークン（1 時間で切れる）だけ。値は引数に書かず、名前だけを -e に渡す
  # （docker が環境から読む）。PAT はこのプロセスの変数にあるだけで、export していない。
  args=(run --rm --name "$RUNNER_CNAME" -e RUNNER_TOKEN ${net_args[@]+"${net_args[@]}"})
  if [[ "$dock" == "yes" ]]; then
    args+=(-v "$sock:/var/run/docker.sock" --group-add "$gid")
  fi
  echo "[$PROG] $name: ランナー $RUNNER_GHNAME を起こします（組織 $org、docker=$dock、lan=$lan${grp:+、group=$grp}）。ジョブを 1 つ受けたら終わります。"
  # ここから先は、正常に終わらなければ後始末（コンテナの停止と登録の削除）をする。
  RUNNER_NEED_CLEANUP=1
  # group があるときだけ、4 つ目の引数で --runnergroup を渡す。登録が拒まれたら 78 で抜ける（既定のグループへ黙って入らない。
  # 指定したグループが無いと config.sh は非 0 で終わる）。group を書かない行の引数は従来のまま。
  RUNNER_TOKEN="$tok" docker "${args[@]}" "$img" bash -c \
    'set -uo pipefail
rc=0
./config.sh --unattended --ephemeral --disableupdate --replace --url "$1" --token "$RUNNER_TOKEN" --name "$2" ${3:+--labels "$3"} ${4:+--runnergroup "$4"} || rc=$?
if [ "$rc" -ne 0 ]; then
  [ -n "${4:-}" ] && exit 78
  exit "$rc"
fi
unset RUNNER_TOKEN
exec ./run.sh' runner "https://github.com/$org" "$RUNNER_GHNAME" "$labels" ${grp:+"$grp"} &
  RUNNER_CHILD=$!
  tok=""
  local rc=0
  wait "$RUNNER_CHILD" || rc=$?
  RUNNER_CHILD=""
  if [[ "$rc" -eq 78 && -n "$grp" ]]; then
    die_permanent "$name: ランナーグループ $grp へ登録できませんでした（グループが無いか、登録が拒まれました）。既定のグループへは入りません。組織 $org のグループ名と、そのグループを使えるリポジトリの設定を確かめてください。直してから systemctl --user start dev-runner@$name.service で起こし直します"
  fi
  if [[ "$rc" -ne 0 ]]; then
    die "$name: ランナーのコンテナが失敗して止まりました（終了コード $rc）。ユニットが起こし直します。"
  fi
  RUNNER_NEED_CLEANUP=0
  echo "[$PROG] $name: ジョブを終えてコンテナが止まりました。ユニットが新しいコンテナで起こし直します。"
}

# group を指定したランナーの点検。組織のランナーグループの一覧にあれば OK、無ければ FAIL、読めなければ WARN（PAT の値は出さない）。
# 使い方: doctor_runner_group <組織> <グループ名> <PAT ファイル>
doctor_runner_group() {
  local org="$1" grp="$2" patf="$3" page=1 resp rc names="" found=0
  if ! runner_pat_problem "$patf" >/dev/null || ! runner_pat_load "$patf" 2>/dev/null; then
    doc_line WARN "ランナーグループ $grp: PAT を読めないため、組織のグループの一覧を確かめられません"
    return 0
  fi
  while :; do
    rc=0
    resp="$(runner_api GET "/orgs/$org/actions/runner-groups?per_page=100&page=$page" 2>/dev/null)" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      if [[ "$rc" -eq 10 ]]; then
        doc_line WARN "ランナーグループ $grp: グループの一覧を読めませんでした（HTTP 401 / 403 / 404。PAT の権限（組織の Self-hosted runners: Read）か組織名 $org を確かめる）"
      else
        doc_line WARN "ランナーグループ $grp: グループの一覧を読めませんでした（API の不調か通信の失敗）"
      fi
      return 0
    fi
    names="$(printf '%s\n' "$resp" | jq -r '.runner_groups[]?.name' 2>/dev/null)" || names=""
    # 完全一致で見る（group の値は英数字と . _ - だけなので、パターンの特殊文字は含まない）。
    if [[ $'\n'"$names"$'\n' == *$'\n'"$grp"$'\n'* ]]; then
      found=1
      break
    fi
    # 1 ページが 100 件で埋まっていれば次のページを見る。
    [[ "$(printf '%s\n' "$names" | grep -c .)" -ge 100 ]] || break
    page=$((page + 1))
  done
  if [[ "$found" -eq 1 ]]; then
    doc_line OK "ランナーグループ $grp が組織 $org にあります"
  else
    doc_line FAIL "ランナーグループ $grp が組織 $org にありません（登録は 78 で止まる。GitHub 側でグループを作るか、runners の group= を直す）"
  fi
}

# dev doctor --runner <名前>: ランナーの点検。1 つでも FAIL なら 1、WARN だけなら 3、無ければ 0。
cmd_doctor_runner() {
  [[ $# -eq 1 ]] || usage_error "使い方: dev doctor --runner <名前>"
  load_runners
  find_runner "$1"
  need docker "Docker Engine を入れてください。"
  local name="$1" dock="${R_DOCKER[$RIDX]}" patf="${R_PAT[$RIDX]}" grp="${R_GROUP[$RIDX]}" unit="dev-runner@${1}.service" img why us sock
  img="$(runner_image)"
  echo "[$PROG] doctor: ランナー $name（組織 ${R_ORGS[$RIDX]}）"

  if docker image inspect "$img" >/dev/null 2>&1; then
    doc_line OK "イメージ $img があります"
  else
    doc_line FAIL "イメージ $img がありません（dev runner build で作る）"
  fi

  if why="$(runner_pat_problem "$patf")"; then
    doc_line OK "PAT ファイル $patf（権限 $(file_mode_of "$patf")）"
  else
    doc_line FAIL "$why"
  fi

  if [[ "$dock" == "yes" ]]; then
    sock="$(runner_docker_sock)"
    if [[ -e "$sock" ]]; then
      doc_line INFO "docker=yes: ジョブがホストの Docker を自由に操作できます（ソケット $sock を渡す設定）"
    else
      doc_line FAIL "docker=yes ですが、Docker のソケット $sock がありません"
    fi
  else
    doc_line OK "Docker のソケットは渡しません（docker=no）"
  fi

  if [[ -n "$grp" ]]; then
    doctor_runner_group "${R_ORGS[$RIDX]}" "$grp" "$patf"
  fi

  us="$(unit_state "$unit")"
  case "$us" in
    active | activating) doc_line OK "ユニット $unit: $us" ;;
    *) doc_line WARN "ユニット $unit: $us（有効にしていないか、止まっています: systemctl --user enable --now $unit）" ;;
  esac

  if [[ "$DOC_FAIL" -gt 0 ]]; then
    echo "[$PROG] 判定: FAIL（$DOC_FAIL 件）。"
    exit 1
  elif [[ "$DOC_WARN" -gt 0 ]]; then
    echo "[$PROG] 判定: WARN（$DOC_WARN 件）。"
    exit 3
  fi
  echo "[$PROG] 判定: OK"
}

# ── self-update ───────────────────────────────────────────────────────────────
# devhost は公開リポジトリ ojos/devcontainer-host のリリースで配られる（README.md の「devhost を入手する」）。
# 取得先はその公開リリース。既定は最新、--version で版を固定する。
# （以前は devcontainer-bootstrap のリリースに同梱していた。取得先を変えても、下の確かめは変えない。）
RELEASE_BASE_URL="https://github.com/ojos/devcontainer-host/releases"
# devhost の dev.sh である確かめ。1 行目が bash の shebang、2 行目が「# dev — 」で始まること。2 行目を全文で照合しないのは、将来の版が説明文を変えても、
# 古い版から更新できなくなるのを避けるため（接頭辞は版をまたいで変えない約束にする）。
# 置き換え先（いま置いてある dev）と、取得した新しい dev の両方に課す（取得物は、ハッシュの照合と
# 構文の検査に加えて、sh や無関係なスクリプトを dev として置かないための確かめ）。
SELF_HEADER_PREFIX='# dev — '
# 版（vX.Y.Z）の形。--version の値とマニフェストの版に課す（URL の一部になるため）。
SEMVER_RE='^v[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$'

# ファイルの先頭 2 行が devhost の dev.sh のものであること。
is_devhost_dev_sh() {
  local f="$1" l1 l2
  [[ -f "$f" ]] || return 1
  { IFS= read -r l1 && IFS= read -r l2; } <"$f" || return 1
  case "$l1" in
    '#!/usr/bin/env bash' | '#!/bin/bash' | '#!/usr/bin/bash') ;;
    *) return 1 ;;
  esac
  [[ "$l2" == "$SELF_HEADER_PREFIX"* ]]
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

# ファイルが git で追跡されているか。git が無い機械では、追跡されていないとみなす。
# リポジトリのチェックアウトの packages/devcontainer-host/dev.sh を、置き換え先にしないため。
# 「祖先に .git がある」では判定しない（ホームを ~/.git で管理している機械で、置いた dev まで拒んでしまう）。
is_git_tracked() {
  local f="$1" d
  command -v git >/dev/null 2>&1 || return 1
  d="$(cd "$(dirname "$f")" && pwd -P)" || return 1
  git -C "$d" ls-files --error-unmatch -- "${f##*/}" >/dev/null 2>&1
}

# 置き換え先の dev を書き換えてよいか。だめなら理由を標準出力へ出して 1 を返す（呼び出し側が「何も置いていない」を添えて止まる）。
# リンク（先を書き換えない）・ディレクトリ・git で追跡されているファイル・devhost の dev.sh でないもの、のいずれかなら拒む。
dev_target_refusal() {
  local p="$1"
  if [[ -L "$p" ]]; then
    echo "置き換え先 $p はリンクです。リンクの先は書き換えません（README.md の「dev を置く」のとおり、写しで置いてください）。"
    return 1
  fi
  if [[ -d "$p" ]]; then
    echo "置き換え先 $p はディレクトリです。"
    return 1
  fi
  if is_git_tracked "$p"; then
    echo "置き換え先 $p は git で追跡されているファイルです（リポジトリのチェックアウトの dev.sh は書き換えません。~/.local/bin/dev などへ写して置いたものを更新してください）。"
    return 1
  fi
  if ! is_devhost_dev_sh "$p"; then
    echo "置き換え先 $p が devhost の dev.sh だと確かめられません（1 行目が bash の shebang、2 行目が「# dev — 」で始まる形ではない、または読めない）。"
    return 1
  fi
  return 0
}

SU_TMP=""
su_cleanup() { [[ -z "$SU_TMP" ]] || rm -rf "$SU_TMP"; }

# 置いてあるファイル（ユニット・ランナーの Dockerfile）を、同じリリースの同名の資産と比べ、違えば install.sh の再実行を案内する。
# **書き換えない**（差の検出と案内だけ。書き換えは install.sh の再実行に任せる）。
# 比べる相手は、マニフェストの checksums[<資産の名前>]（照合済みの dev.sh と同じリリースのマニフェスト）。
# ファイルを置いていない機械（手動で使う、ランナーを使わない）、マニフェストにハッシュが無い版では何も言わない。
# 案内が出せなくても self-update 自体は失敗させない（dev.sh の置き換えはもう済んでいる）。
# 使い方: su_check_asset <マニフェスト> <リリースの版> <指定した版（--version を付けなかったときは空）> <資産の名前> <置いてあるパス> <呼び名> [<更新したあとの案内>]
su_check_asset() {
  local manifest="$1" ver="$2" pin="${3:-}" asset="$4" path="$5" label="$6" hint="${7:-}" want got
  [[ -f "$path" ]] || return 0
  want="$(jq -r --arg a "$asset" '.checksums[$a] // empty' "$manifest" 2>/dev/null)" || return 0
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || return 0
  got="$(sha256_of "$path")" || {
    echo "[$PROG] 警告: $path のハッシュを計算できないので、リリースの${label}とは比べていません。" >&2
    return 0
  }
  if [[ "$got" != "$want" ]]; then
    echo "[$PROG] 置いてある$label（$path）が、リリース${ver:+（$ver）}の $asset と違います。"
    echo "[$PROG]   install.sh を再実行して${label}を更新してください${pin:+（bash install.sh --version $pin）}（README.md の「install.sh で入れる」。self-update は書き換えません）。${hint}"
  fi
}

# 置いてあるユニット・ランナーのファイルを、リリースのものと比べる（su_check_asset）。
# 使い方: su_check_unit <マニフェスト> <リリースの版> <指定した版（--version を付けなかったときは空）>
su_check_unit() {
  local conf="${XDG_CONFIG_HOME:-$HOME/.config}"
  su_check_asset "$1" "$2" "${3:-}" dev-up@.service "$conf/systemd/user/dev-up@.service" "ユニット"
  su_check_asset "$1" "$2" "${3:-}" dev-runner@.service "$conf/systemd/user/dev-runner@.service" "ランナーのユニット"
  su_check_asset "$1" "$2" "${3:-}" runner.Dockerfile "$(runner_dockerfile)" "ランナーの Dockerfile" "更新したら dev runner build でイメージを作り直してください。"
}

# dev 自身を、devcontainer-host の公開リリースの dev.sh へ置き換える。
# 手順は README.md の手動の入手と同じ: RELEASE-MANIFEST.json と dev.sh を取得し、
# マニフェストが記録した dev.sh のハッシュ（checksums の dev.sh）と照合する。dev.sh は個別の資産として
# 配られているので、アーカイブは取らない。
# **置き換える前に全部確かめる**（ハッシュが合う / 取得したものが devhost の dev.sh で構文が通る / 置き換え先も
# devhost の dev.sh）。どれかが外れたら、何も置き換えずに 1 で止まる。置き換えは同じディレクトリの
# 一時ファイルへ書いてから mv する（途中で切れても、半端な dev が残らない）。
cmd_self_update() {
  local version="" a
  while [[ $# -gt 0 ]]; do
    a="$1"
    case "$a" in
      --version)
        [[ $# -ge 2 && -n "$2" ]] || usage_error "--version には版が要ります（空は不可。使い方: dev self-update [--version <vX.Y.Z>]）"
        version="$2"
        shift
        ;;
      *) usage_error "使い方: dev self-update [--version <vX.Y.Z>]" ;;
    esac
    shift
  done
  if [[ -n "$version" && ! "$version" =~ $SEMVER_RE ]]; then
    usage_error "版は vX.Y.Z の形で指定します（URL の一部になるため）: $version"
  fi
  need curl "curl を入れてください。"
  need jq "jq を入れてください（マニフェストを読む。README.md の手動の入手と同じ）。"
  local base self selfdir mver=""
  # 最新のとき、マニフェストだけを latest から取り、そこに書かれた版で dev.sh を取る
  # （latest を 2 回引くと、間にリリースが出たときに、別の版のマニフェストと dev.sh を組み合わせうる）。
  local mbase
  if [[ -n "$version" ]]; then mbase="$RELEASE_BASE_URL/download/$version"; else mbase="$RELEASE_BASE_URL/latest/download"; fi
  base="$mbase"

  # 置き換え先。写しとして置いた dev（~/.local/bin/dev）自身。リンクは辿らず、止まる
  # （リンク先のリポジトリの道具を、黙って書き換えないため）。
  self="${DEV_SELF_PATH:-${BASH_SOURCE[0]}}"
  local why
  if [[ -e "$self" || -L "$self" ]]; then
    why="$(dev_target_refusal "$self")" || die "$why 何も置き換えていません。"
  else
    die "置き換え先 $self が無いか、読めません。何も置き換えていません。"
  fi
  selfdir="$(cd "$(dirname "$self")" && pwd)"

  SU_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dev-self-update.XXXXXX")" || die "作業ディレクトリを作れません。何も置き換えていません。"
  trap su_cleanup EXIT
  echo "[$PROG] 取得先: $mbase"
  curl -fsSL "$mbase/RELEASE-MANIFEST.json" -o "$SU_TMP/RELEASE-MANIFEST.json" || die "RELEASE-MANIFEST.json を取得できません。何も置き換えていません。"
  if [[ -z "$version" ]]; then
    mver="$(jq -r '.version // empty' "$SU_TMP/RELEASE-MANIFEST.json")" || die "RELEASE-MANIFEST.json を読めません。何も置き換えていません。"
    [[ "$mver" == v* ]] || mver="v$mver"
    [[ "$mver" =~ $SEMVER_RE ]] || die "最新の版をマニフェストから読めません（version: $mver）。--version vX.Y.Z で版を指定してください。何も置き換えていません。"
    base="$RELEASE_BASE_URL/download/$mver"
    echo "[$PROG] 最新の版: $mver（dev.sh は $base から取る）"
  fi

  local want got
  want="$(jq -r '.checksums["dev.sh"] // empty' "$SU_TMP/RELEASE-MANIFEST.json")" || die "RELEASE-MANIFEST.json を読めません。何も置き換えていません。"
  [[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "RELEASE-MANIFEST.json に dev.sh のハッシュ（checksums の dev.sh）がありません。何も置き換えていません。"
  curl -fsSL "$base/dev.sh" -o "$SU_TMP/dev.sh" || die "dev.sh を取得できません。何も置き換えていません。"
  got="$(sha256_of "$SU_TMP/dev.sh")" || die "ハッシュを計算できません。何も置き換えていません。"
  [[ "$got" == "$want" ]] || die "dev.sh のハッシュがマニフェストと合いません（マニフェスト $want / 実際 $got）。何も置き換えていません。"
  echo "[$PROG] ハッシュが合いました: $got"

  is_devhost_dev_sh "$SU_TMP/dev.sh" || die "取得した dev.sh が devhost の dev.sh だと確かめられません（1 行目が bash の shebang、2 行目が「# dev — 」で始まる形ではない）。何も置き換えていません。"
  "${BASH:-bash}" -n "$SU_TMP/dev.sh" || die "取得した dev.sh に構文の誤りがあります。何も置き換えていません。"

  local relver="${version:-${mver:-}}"
  if cmp -s "$SU_TMP/dev.sh" "$self"; then
    echo "[$PROG] すでにこの版です（$self は取得した dev.sh と同じ）。置き換えません。"
    su_check_unit "$SU_TMP/RELEASE-MANIFEST.json" "$relver" "$version"
    return 0
  fi
  local tmp
  tmp="$(mktemp "$selfdir/.dev.XXXXXX")" || die "$selfdir に一時ファイルを作れません。何も置き換えていません。"
  if ! cp "$SU_TMP/dev.sh" "$tmp" || ! chmod 0755 "$tmp" || ! mv -f "$tmp" "$self"; then
    rm -f "$tmp"
    die "置き換えに失敗しました。何も置き換えていません（置き換え先: $self）。"
  fi
  echo "[$PROG] 置き換えました: $self"
  su_check_unit "$SU_TMP/RELEASE-MANIFEST.json" "$relver" "$version"
  echo "[$PROG] すでに動いているユニットは、起こし直すまで古い dev のまま動き続けます。dev restart <名前>（コンテナも再起動します）か systemctl --user restart dev-up@<名前>.service で起こし直してください。"
}

# dev の版を出す。
cmd_version() {
  [[ $# -eq 0 ]] || usage_error "使い方: dev version"
  printf '%s %s\n' "$PROG" "$DEV_VERSION"
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
  if [[ "${1:-}" == "--runner" ]]; then
    shift
    cmd_doctor_runner "$@"
    return
  fi
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
  dev doctor --runner <名前>

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

--runner は自前のランナー（dev runner、設定ファイル runners の名前）の点検。プロジェクトの設定ファイルは読まない。
  FAIL  ランナーのイメージが無い / PAT ファイルが無い・group / other に権限がある・読めない /
        docker=yes なのに Docker のソケットが無い
  WARN  ユニット dev-runner@<名前> が active でも activating でもない
  （docker=yes の設定は、危険を知らせる INFO を出す。PAT の値は出さない）
EOF
}

help_runner() {
  cat <<'EOF'
dev runner — GitHub Actions の自前のランナーを、使い捨てのコンテナで動かす。

使い方:
  dev runner build
  dev runner run <名前>
  dev runner net script|unit

build: ランナーのイメージ（公式のランナーのイメージに道具を足した runner.Dockerfile）を作る。
  Dockerfile は標準入力から渡す（ビルドの文脈を作らない）。Dockerfile は編集しない。公式のランナーの版を上げるときは、
  環境変数 DEV_RUNNER_VERSION か、設定ファイルの `runner_version=X.Y.Z` の行で指定する（--build-arg で渡す。未指定なら Dockerfile の既定値）。
run: ユニット dev-runner@<名前>.service の ExecStart。1 回の起動で次をする。
  0. 同じ名前のランナーがすでに動いていれば（ロックが取れなければ）、何も消さずに 75 で終わる
  1. 設定ファイル runners の PAT のファイルを調べる（group / other に権限があれば、読まずに拒んで 78 で終わる）
  2. PAT で組織の登録用のトークンを取得する（PAT は引数にも環境変数にも出さない）
  3. --ephemeral のランナーを --rm のコンテナで起こす。コンテナへ渡すのは登録用のトークンだけ
  4. ジョブが 1 つ終わってコンテナが止まったら抜ける（ユニットが新しいコンテナで起こし直す）
  3 の前（2 の API を呼ぶより前）に、出口の規則の印（/run/dev-runner-net/ready。ブリッジ名 dev-runner0 を含む）を確かめる。無いときは起動せず 1 で終わり（ユニットが起こし直す）、ブリッジ名が違うときは 78 で終わる
  （Docker の再起動に備え、無ければ 30 秒まで待つ）。印があれば、専用の Docker ネットワーク dev-runner（IPv6 無効、ブリッジ名 dev-runner0 固定）を
  無ければ作り、コンテナをそこで動かす。設定ファイルで lan=allow にしたランナーは、この確認を外し、既定のブリッジで動かす。
  コンテナを起こしたあと、正常に終わらなかったとき（止めたとき（ユニットの停止・TERM・INT・HUP）や失敗したとき）だけ、
  コンテナを止め、登録中のランナーを組織から外す（正常に終わったときは、GitHub 側で外れている）。
  Docker のソケットは、設定ファイルで docker=yes にしたランナーにだけ渡す（既定は渡さない。
  渡すと、ジョブがホストの Docker を自由に操作できる）。
設定ファイル: runners（既定は ~/.config/dev/runners（XDG_CONFIG_HOME があればその下）。環境変数 DEV_RUNNERS_FILE で差し替える。書式は runners.example）。
  1 行 1 ランナーで「名前 組織 [labels=a,b] [docker=yes|no] [lan=allow|deny] [group=名前] [pat_file=絶対パス]」。
  group=名前 は登録先のランナーグループ（英数字と . _ - だけ。書かなければ組織の既定のグループ）。ラベルは安全の境界にならない
  （組織のどのリポジトリでも runs-on に書ける）。使えるリポジトリを絞るのはグループで、グループの作成と対象の設定は GitHub 側で行う。
  グループが無い、または登録が拒まれたときは 78 で終わり、既定のグループへは入らない。
  `runner_version=X.Y.Z` だけの行は、イメージに使う公式のランナーの版（共通の設定）。
net: 出口の規則を入れる root の部分を標準出力へ出す（dev 自身は何も入れない。sudo で入れる手順は、このパッケージの README の自前のランナーの節）。
  script  規則を入れるスクリプト（/usr/local/sbin/dev-runner-net）。apply / unmark / clear / rules を持つ
  unit    それを呼ぶ systemd のシステムのユニット（/etc/systemd/system/dev-runner-net.service）
  止める出口: 専用ブリッジから 10/8・172.16/12・192.168/16・169.254/16・100.64/10 と、機械自身への新しい接続。docker=yes のランナーはソケットで迂回できるので対象外。
点検は dev doctor --runner <名前>。curl と jq が要る。

終了コード: 0 = ジョブを終えて止まった（build は作れた） / 1 = 一時的な失敗（API の 429・5xx や通信の失敗、コンテナの失敗、出口の規則の印がまだ無い、など。ユニットは起こし直す） /
            2 = 使い方か設定ファイルの誤り / 75 = 同じ名前がすでに動いている / 78 = イメージが無い・PAT の権限が緩い・Docker のソケットが無い・出口の規則の印のブリッジ名が違う・group を指定したランナーグループへ登録できない・API が 401 / 403 / 404（PAT の失効・権限不足・組織名の誤り）
            （2 と 78 は、ユニットが起こし直さない）
失敗したとき: dev doctor --runner <名前> で原因を見分ける。
EOF
}

help_restart() {
  cat <<'EOF'
dev restart — 作り直さずにコンテナを再起動する。

使い方:
  dev restart <名前>

呼ぶ順序:
  1. 対象のコンテナを集める。無ければ、ユニットにも触らずに 1 で止まる（dev up <名前>）。
     docker の問い合わせが失敗したときも、何も変えずに 1 で止まる（「無い」とは区別する）
  2. ユニット dev-up@<名前> を、dev rebuild と同じ基準で止める（inactive / failed / unknown /
     systemctl が無い、のときは触らない。状態の語が得られないときは、何も変えずに 1 で止まる）
  3. docker restart <対象のコンテナ>
  4. 2 で止めたときだけ、ユニットを起こし直す。3 が失敗しても、INT / HUP / TERM で中断されても
     （ssh の切断など）起こし直してから終わる（中断の終了コードは 130 / 129 / 143）
範囲: コンテナ 1 つではなく、compose で動くプロジェクトならそのプロジェクトのコンテナ全体
（app のコンテナの label com.docker.compose.project で同じプロジェクトを列挙する。DB などの別のサービスも
含む。VS Code の stopCompose と同じ範囲）。label が無いものは、これまでどおりコンテナ 1 つ。
各プロジェクトの compose ファイルは読まず、書き換えない。
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
  2. 対象のコンテナを集めて docker stop する。無いときは何もしない。止まりきった状態
     （exited / created / dead）のコンテナは、コンテナごとに止めない（paused / restarting などは止める）。
     docker の問い合わせが失敗したときは、「無い」とせずに 1 で終わる（ユニットは止めたまま）
範囲: コンテナ 1 つではなく、compose で動くプロジェクトならそのプロジェクトのコンテナ全体
（app のコンテナの label com.docker.compose.project で同じプロジェクトを列挙する。DB などの別のサービスも
含む。VS Code の stopCompose と同じ範囲）。label が無いものは、これまでどおりコンテナ 1 つ。
各プロジェクトの compose ファイルは読まず、書き換えない。
ユニットは disable しない（有効なら、外部の機械を再起動すれば、ユニットが戻ってコンテナも戻る）。
戻すとき: dev enable <名前>。enable --now は、無効のユニットにも、有効のまま止まっているユニットにも効く。
dev up はコンテナを起こすだけで、止めたユニットは起き直らないので、戻すのには使わない。
再起動の後も戻したくないときは、dev disable <名前>（ユニットを無効にして、コンテナも止める）。

終了コード: 0 = 止めた（元から無い・止まっているときも 0） / 1 = 失敗（ユニットの停止・docker の問い合わせ・docker stop） / 2 = 使い方か設定の誤り
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
dev disable — ユニットを無効にして、コンテナも止める。

使い方:
  dev disable <名前>

呼ぶ順序（dev stop と同じ、ユニット → コンテナ）:
  1. systemctl --user disable --now dev-up@<名前>.service（ユニットを無効にして止める）。失敗したら、コンテナには触らない
  2. 対象のコンテナを docker stop する（範囲・止まりきった状態の扱い・docker の問い合わせの失敗の扱いは dev stop と同じ。
     compose で動くプロジェクトなら、そのプロジェクトのコンテナ全体）
外部の機械を再起動した後も、止めたままになる。戻すときは dev enable <名前>
（ユニットを有効にして起こす。コンテナも戻る）。コンテナだけを止めて再起動の後は戻したいときは dev stop <名前>。

終了コード: 0 = 無効にして止めた / 1 = 失敗（systemctl・docker の問い合わせ・docker stop） / 2 = 使い方か設定の誤り
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
dev self-update — dev 自身を、devcontainer-host の公開リリースの版へ置き換える。

使い方:
  dev self-update [--version <vX.Y.Z>]

呼ぶ順序:
  1. 置き換え先（この dev）が、リンクでもディレクトリでも git で追跡されているファイルでもなく、devhost の dev.sh であることを
     確かめる（1 行目が bash の shebang、2 行目が「# dev — 」で始まる）
  2. 公開リリースから RELEASE-MANIFEST.json を取得する（既定は最新。--version でその版に固定する）
  3. マニフェストの checksums に記録された dev.sh の SHA-256 を読み、同じリリースの dev.sh を取得して照合する
  4. 取得した dev.sh が 1 と同じ形（bash の shebang と「# dev — 」）であることと、構文を確かめる
  5. 同じディレクトリの一時ファイルへ写し、mv で置き換える
  6. 置いてあるユニットのファイル（~/.config/systemd/user/dev-up@.service と dev-runner@.service）と、ランナーの
     Dockerfile（~/.config/dev/runner.Dockerfile）を、同じリリースのマニフェストの checksums の同名の資産と比べる。
     違えば、install.sh を再実行して更新するよう案内する
     （ファイルを置いていない、マニフェストにハッシュが無いときは何も言わない）
  7. 置き換えたあと、動いているユニットは起こし直すまで古い dev のまま動き続けることを案内する
     （dev restart <名前>、または systemctl --user restart dev-up@<名前>.service）
どれか 1 つでも外れたら（1〜5）、何も置き換えずに 1 で止まる。手動の入手（README の「devhost を入手する」）と
同じ照合。dev.sh だけを置き換える。**ユニット・Dockerfile・設定ファイルは書き換えない**（6 は差の案内だけで、
更新は install.sh の再実行に任せる）。
curl と jq と、sha256sum または shasum が要る。

オプション:
  --version <vX.Y.Z>   取得する版（既定は最新）

終了コード: 0 = 置き換えた（すでに同じ版なら置き換えずに 0） / 1 = 失敗（取得・照合・置き換え先の確認・置き換え） / 2 = 使い方の誤り
EOF
}

help_version() {
  cat <<'EOF'
dev version — dev の版を出す。

使い方:
  dev version
  dev --version

出力は `dev vX.Y.Z` の 1 行。公開した版のこの値は、リリースの手順が書き込む。
プロジェクトの設定ファイルは読まない。

終了コード: 0 = 成功 / 2 = 使い方の誤り
EOF
}

help_help() {
  cat <<'EOF'
dev help — サブコマンドの説明を出す。

使い方:
  dev help                  使い方の一覧
  dev help <サブコマンド>    ls / up / attach / supervise / rebuild / doctor / runner /
                            restart / stop / logs / enable / disable / exec / self-update / version の説明

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
    runner) cmd_runner "$@" ;;
    restart) cmd_restart "$@" ;;
    stop) cmd_stop "$@" ;;
    logs) cmd_logs "$@" ;;
    enable) cmd_enable "$@" ;;
    disable) cmd_disable "$@" ;;
    exec) cmd_exec "$@" ;;
    self-update) cmd_self_update "$@" ;;
    version | --version) cmd_version "$@" ;;
    help) cmd_help "$@" ;;
    -h | --help) usage ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
