#!/usr/bin/env bash
# selftest.sh — dev（dev.sh）の自己試験。非対話で、本物の devcontainer / docker / tmux /
# systemctl を 1 つも呼ばない。
#
# 偽の道具を一時ディレクトリに置き、PATH をその偽物と最小限の道具（sed など）だけにして
# dev.sh を回す。偽物は呼ばれた引数を 1 行ずつ記録し、試験はその記録を突き合わせる。
#
# ## 偽物を本物に合わせたところ（本物がしないことはさせない）
#
# - devcontainer（CLI 0.89.0 の dist を読んで合わせた）
#   - `up`: 結果を JSON 1 行で標準出力へ、経過を標準エラーへ出す。失敗の JSON
#     （outcome=error）でも 1 で抜ける。devcontainer.json が無いワークスペースは
#     `Dev container config (...) not found.` で失敗する
#   - `exec`: **最初のオプションでない語で引数の解析を止め**（halt-at-non-option）、それより
#     後をそのままコマンドに渡す。動いているコンテナが無ければ `Dev container not found.` で 1
#   - `up --remove-existing-container`: 在るコンテナを消して**別の ID で**作り直す（本物は古い
#     コンテナを削除して新しく作るので ID が変わる）
#   - exec が通らないとき（FAKE_EXEC_FAIL=1）: docker exec の失敗（procReady not received）を
#     1 で返す。本物の終了コードは確かめていない（dev は 0 以外を「入れない」とだけ読む）
#   - `exec ... true`: 偽のコンテナには true が無いので、0 で抜ける
#     （本物はコンテナの中の true を実行して 0 で抜ける）
# - docker `inspect --format '{{.State.Pid}}' <id>`: 動いていれば PID、止まっていれば 0（本物は
#   止まったコンテナの State.Pid を 0 で返す）。無い ID は 1。他の形は落とす
# - ps: `-eo pid=,stat=`（`=` で見出しを消した「PID 状態」の列。PID は右寄せ。この環境の
#   procps-ng 4.0.4 の出力に合わせた）。cgroup の所属は ps に出させず、dev が
#   /proc/<PID>/cgroup を読む（ps の cgroup 列はルートの cgroup で `-` と出る環境があり、
#   パスの形が信用できないため）
# - git: `-C <dir> pull --ff-only` と、`-C <dir> ls-files --error-unmatch -- <名前>`（常に追跡なし。記録しない）だけ。失敗は本物と同じ形の `fatal: ...` を 128 で返す
# - journalctl: `--user -u <unit> -n <N> --no-pager` だけ。履歴が無ければ本物と同じ `-- No entries --`
# - systemctl: `--user is-active|is-enabled|stop|start <unit>` と `--user enable|disable --now <unit>`、`--user list-units|list-unit-files [--...] <glob>...`（FAKE_*_UNITS から組み立てる）。stop / start / enable / disable は何も出さず 0
# - docker `restart|stop <id>...`: 状態を running / exited にする（ID は複数可）。無い ID は 1
# - docker `inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' <id>`: コンテナの compose のプロジェクト名（label が無ければ空）。
#   `ps --filter label=com.docker.compose.project=<名>` でそのプロジェクトのコンテナを列挙する
#   （コンテナの状態は 1 行 1 つで「パス<TAB>ID<TAB>状態<TAB>compose のプロジェクト（任意）」）
# - curl: `-fsSL <URL> -o <出力先>` だけ。リリースの取得先（devcontainer-host の latest/download か download/v*）以外の URL は落とす
#   （ネットワークには出ない。URL の末尾のファイル名で、試験が用意したファイルを写す。-f の失敗は 22）
# - curl（devhost の最新の版）: `-sSL ... <https://api.github.com/repos/ojos/devcontainer-host/releases/latest>`。FAKE_DH_LATEST の JSON を 200 で返す（未設定は 404。FAKE_DH_LATEST_FAIL / FAKE_API_NETFAIL で失敗）。認証を付けたら落とす
# - docker（ランナー用）: `image inspect <イメージ>`（FAKE_IMAGE_MISSING=1 で無い）、`build -t <名前> -`（標準入力を $FAKE_STATE/build-stdin へ写す）、
#   `rm -f <名前>`、`run ...`（**環境変数の一覧を $FAKE_STATE/run-env へ書く**。FAKE_RUN_SIGNAL=TERM で親へ TERM を送って 143 で抜ける
#   ＝ユニットを止められた状況。FAKE_RUN_EXIT で抜ける終了コードを変える）。他の形は落とす
# - docker `network inspect --format ... <名前>` と `network create ...`（自前のランナーの専用ネットワーク。作った印は $FAKE_STATE/network。
#   FAKE_NET_BRIDGE / FAKE_NET_IPV6 で既存のネットワークの設定を差し替える。他の形は落とす）
# - iptables: 引数を記録するだけ。`-C FORWARD ...` は FAKE_IPT_FWD（既定 0＝DOCKER-USER への飛び先がある）、他の `-C` は FAKE_IPT_CHECK（既定 1＝無い）、`-n -L` は FAKE_IPT_LIST（既定 1＝鎖が無い）で抜ける。
#   iptables-restore: 引数を記録し、標準入力を $FAKE_STATE/restore-in へ写す（FAKE_IPTR_FAIL=1 で失敗）。規則の実体は見ない（生成した文面で確かめる）
# - curl（API）: `-sSL -K - -X <メソッド> -H ... -w <書式> <URL>` の形だけ。**標準入力の設定を $FAKE_STATE/curl-config へ書き**
#   （PAT が引数でなく標準入力で渡ることを見る）、FAKE_PAT_EXPECT を含まなければ 401 相当（22）で落とす。
#   組織の登録用トークン（POST）・ランナーの一覧（GET、page 付き。FAKE_REGISTERED_NAME のランナーを 1 つ返す。FAKE_PAGES=2 なら 1 ページ目は 100 件の別のランナーで、自分は 2 ページ目）・登録の削除（DELETE）だけ
# - curl（API、dev runner route 用）: 上の API の偽物に、次を足す。変数 ACTIONS_RUNS_ON は $FAKE_VARS_DIR/<リポジトリ>（ファイルがあれば設定済み。中身が値）で持つ。
#   `GET /repos/<組織>/<リポジトリ>/actions/variables/ACTIONS_RUNS_ON`（無ければ 404）、`PATCH` 同上（204）、`POST /repos/.../actions/variables`（201。既にあれば 409）。
#   本文は `-d` で受け、書いた内容を $FAKE_STATE/writes へ「メソッド リポジトリ 値」で足す。失敗の注入: FAKE_WRITE_FAIL（書き込みが常に 500 のリポジトリ。カンマ区切り）/
#   FAKE_WRITE_FAIL_ONCE（最初の書き込みだけ 500）/ FAKE_VAR_FAIL（読み取りが 500）/ FAKE_VAR_403（読み取りが 403）。
#   `GET .../runner-groups/<id>/repositories`（FAKE_GROUP_REPOS のカンマ区切り。既定 r-a,r-b,r-c。FAKE_GROUP_REPOS_GEN=N なら gen-1..gen-N。FAKE_API_FAIL=group-repos で失敗）、
#   グループの一覧は visibility を持つ（FAKE_GROUP_VIS。既定 selected）。FAKE_GROUP_REPOS_AFTER は、1 回目の読み取りのあとの一覧（ロックを取るまでにグループが変わる仕込み）、FAKE_GROUP_REPOS_AFTER_FAIL=1 は 2 回目以降の読み取りが 500。
#   FAKE_GROUPS_PAD=N は、名前の違うグループ N 件を前に並べて対象を 2 ページ目へ送る。
#   ランナーの一覧は FAKE_RUNNERS（「名前:状態:ラベル+ラベル」のカンマ区切り）で差し替えられる（FAKE_RUNNERS_FIRST は 1 回目の読み取りだけ。FAKE_RUNNERS_PAGES=2 は 1 ページ目を 100 件の別のランナーで埋める。FAKE_API_FAIL=runners で失敗）。
#   FAKE_PAR_TRACK=1 は、変数の読み取りを 0.3 秒止めて、同時に走っている数を $FAKE_STATE/par へ足す（並列の上限を見る）。
#   `sleep` は、route の試験だけ PATH の先頭に置いた偽物（呼ばれた引数を記録して、待たずに返る）に差し替える。
# - /proc と cgroup は偽の木（$WORK/proc と $WORK/cg）を DEV_PROC_ROOT / DEV_CGROUP_ROOT で渡す。
#   cgroup v2 の形に合わせる（/proc/<PID>/cgroup は `0::/パス` の 1 行、pids.current / pids.max は
#   数か `max`、pids.events は `max N`、memory.events は 1 行 1 キー）
# - docker: `ps -a` / `--filter label=k=v`（値の完全一致）/ `--format '{{.ID}} {{.State}}'`、
#   `wait <id>`（止まるまで待ち、終了コードを 1 行出して 0 で抜ける。無い ID は 1）。
#   **知らない形の呼び出しは黙って通さずに落とす**（dev.sh が想定外の形で呼んだら赤にする）
# - tmux: `has-session -t =<名前>`（無ければ 1）と `new-session -A -s <名前>`
# - systemctl: `--user is-active <unit>` は状態の語を 1 行出し、active で 0、それ以外で 3
#
# 使い方（<dir> はこのファイルのあるディレクトリ。モノレポでは packages/devcontainer-host、
# 公開リポジトリのリリースの archive から取り出したものでは、展開先に付けた名前）:
#   bash <dir>/selftest.sh                    同じディレクトリの dev.sh を試す
#   DEV_BIN=<path> bash <dir>/selftest.sh     別の dev.sh を試す（変異を当てるとき）
#   DEV_UNIT=<path> bash <dir>/selftest.sh    別のユニットを試す（同上）
#
# 終了コード: 0 = DEVHOST_SELFTEST_PASS / 1 = 期待と食い違った
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV="${DEV_BIN:-$HERE/dev.sh}"
BASH_BIN="$(command -v bash)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devhost-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

FAKEBIN="$WORK/fakebin"
TOOLBIN="$WORK/toolbin"
mkdir -p "$FAKEBIN" "$TOOLBIN" "$WORK/home"

# dev.sh と偽物が使う道具だけを置く。本物の docker などが入った環境でも PATH から見えない。
for t in sed tail head cat rm mkdir grep tr env awk sleep mktemp stat flock tee; do  # bsd-ok: mktemp は呼び出しではなく、偽の PATH へ写す道具の名前の一覧
  p="$(command -v "$t")" || { echo "[devhost-selftest] $t が見つかりません" >&2; exit 1; }
  ln -s "$p" "$TOOLBIN/$t"
done

# ── 偽物 ──────────────────────────────────────────────────────────────────────
# 記録の書式: 道具の名前に続けて、引数を 1 つずつ [ ] で囲む（空白を含む引数を取り違えない）。
cat >"$FAKEBIN/_log" <<'EOF'
log_call() {
  local line="$1"
  shift
  local a
  for a in "$@"; do line="$line [$a]"; done
  printf '%s\n' "$line" >>"$FAKE_LOG"
  # 版の知らせのロックの記述子（8）を引き継いで起動されたら記録する（tmux などへ漏れると、ロックが持たれ続けるため）。
  # 問い合わせの curl は、ロックを持っているあいだに走って終わるだけなので数えない。
  if [[ "${0##*/}" != curl && -e "/proc/$$/fd/8" ]]; then printf '%s\n' "${0##*/} $1" >>"$FAKE_STATE/fd8-leak"; fi
}
# コンテナの状態: 1 行 1 つで「ワークスペースのパス<TAB>ID<TAB>状態」。
STATE_FILE="$FAKE_STATE/containers"
touch_state() { [[ -f "$STATE_FILE" ]] || : >"$STATE_FILE"; }
EOF

cat >"$FAKEBIN/devcontainer" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/devcontainer" <<'EOF'
log_call devcontainer "$@"
touch_state
sub="${1:-}"
shift || true
wf=""
remove=0
# オプションは --名前 値 の対で読む。最初のオプションでない語で止まる（exec の halt-at-non-option）。
while [[ $# -gt 0 && "$1" == --* ]]; do
  case "$1" in
    --workspace-folder) wf="$2"; shift 2 ;;
    --remove-existing-container) remove=1; shift ;;
    *) echo "fake devcontainer: この試験が想定していないオプションです: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$wf" ]] || { echo "fake devcontainer: --workspace-folder がありません" >&2; exit 2; }
if [[ ! -f "$wf/.devcontainer/devcontainer.json" && ! -f "$wf/.devcontainer.json" ]]; then
  echo "Dev container config ($wf/.devcontainer/devcontainer.json) not found." >&2
  [[ "$sub" == "up" ]] && printf '{"outcome":"error","message":"Dev container config (%s/.devcontainer/devcontainer.json) not found.","description":"Dev container config (%s/.devcontainer/devcontainer.json) not found."}\n' "$wf" "$wf"
  exit 1
fi
find_row() { grep -F "$wf	" "$STATE_FILE" | sed -n 1p || true; }
case "$sub" in
  up)
    [[ $# -eq 0 ]] || { echo "fake devcontainer: up に余分な引数があります: $*" >&2; exit 2; }
    if [[ -n "${FAKE_UP_SIGNAL:-}" ]]; then
      # 作り直しの最中に、dev（親）がシグナルを受ける状況（ssh の切断など）を作る。
      kill -s "$FAKE_UP_SIGNAL" "$PPID"
      exit 1
    fi
    if [[ "${FAKE_UP_FAIL:-0}" == "1" ]]; then
      echo "[fake] Error: docker compose up が失敗しました" >&2
      printf '{"outcome":"error","message":"Command failed: docker compose up -d","description":"An error occurred starting Docker Compose up."}\n'
      exit 1
    fi
    row="$(find_row)"
    if [[ -n "$row" && "$remove" == 1 ]]; then
      # 古いコンテナを消して、別の ID で作り直す。
      id="$(printf '%s\n' "$row" | cut -f 2)"
      grep -vF "$wf	" "$STATE_FILE" >"$STATE_FILE.new" || true
      mv "$STATE_FILE.new" "$STATE_FILE"
      id="${id}n"
    elif [[ -n "$row" ]]; then
      id="$(printf '%s\n' "$row" | cut -f 2)"
      grep -vF "$wf	" "$STATE_FILE" >"$STATE_FILE.new" || true
      mv "$STATE_FILE.new" "$STATE_FILE"
    else
      id="$(printf '%s' "$wf" | cksum | cut -d ' ' -f 1)"
      id="c0ffee${id}"
    fi
    printf '%s\t%s\trunning\n' "$wf" "$id" >>"$STATE_FILE"
    echo "[fake] Start: Run: docker compose up -d" >&2
    printf '{"outcome":"success","containerId":"%s","composeProjectName":"x_devcontainer","remoteUser":"vscode","remoteWorkspaceFolder":"/workspaces/x"}\n' "$id"
    ;;
  exec)
    [[ $# -gt 0 ]] || { echo "Not enough non-option arguments: got 0, need at least 1" >&2; exit 1; }
    row="$(find_row)"
    if [[ -z "$row" || "$(printf '%s\n' "$row" | cut -f 3)" != "running" ]]; then
      echo "Dev container not found." >&2
      exit 1
    fi
    if [[ "${FAKE_EXEC_FAIL:-0}" == "1" ]]; then
      echo "OCI runtime exec failed: exec failed: unable to start container process: procReady not received: unknown" >&2
      exit 1
    fi
    if [[ "${FAKE_EXEC_HANG:-0}" == "ignoreterm" ]]; then
      # TERM を無視して居座る（KILL でしか止まらない）。20 秒で自分で終わる（直す前の dev.sh を
      # 試験に当てたとき、いつまでも居座らないため）。
      trap '' TERM
      for ((hang_i = 0; hang_i < 20; hang_i++)); do sleep 1; done
      exit 0
    fi
    if [[ "${FAKE_EXEC_HANG:-0}" == "1" ]]; then
      # 応答が返らない状況（本物は exec が止まったまま）。sleep そのものに置き換わるので、
      # 親が PID を kill すれば確実に終わる。
      exec sleep 20
    fi
    [[ "$1" == "true" ]] && exit 0
    exec "$@"
    ;;
  *) echo "fake devcontainer: この試験が想定していないサブコマンドです: $sub" >&2; exit 2 ;;
esac
EOF

cat >"$FAKEBIN/docker" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/docker" <<'EOF'
log_call docker "$@"
touch_state
sub="${1:-}"
shift || true
case "$sub" in
  ps)
    if [[ "${FAKE_DOCKER_FAIL:-}" == "ps" ]]; then
      echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2
      exit 1
    fi
    all=0 filter="" format=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -a) all=1; shift ;;
        --filter) filter="$2"; shift 2 ;;
        --format) format="$2"; shift 2 ;;
        *) echo "fake docker: この試験が想定していない ps の引数です: $1" >&2; exit 2 ;;
      esac
    done
    [[ "$format" == '{{.ID}} {{.State}}' ]] || { echo "fake docker: 想定外の format: $format" >&2; exit 2; }
    case "$filter" in
      label=devcontainer.local_folder=*) mode=path want="${filter#label=devcontainer.local_folder=}" ;;
      label=com.docker.compose.project=*) mode=project want="${filter#label=com.docker.compose.project=}" ;;
      *) echo "fake docker: 想定外の filter: $filter" >&2; exit 2 ;;
    esac
    while IFS='	' read -r path id state project; do
      if [[ "$mode" == path ]]; then [[ "$path" == "$want" ]] || continue; else [[ "$project" == "$want" ]] || continue; fi
      [[ "$all" == 1 || "$state" == "running" ]] || continue
      printf '%s %s\n' "$id" "$state"
    done <"$STATE_FILE"
    ;;
  inspect)
    [[ $# -eq 3 && "$1" == "--format" ]] || { echo "fake docker: 想定外の inspect の引数: $*" >&2; exit 2; }
    row="$(grep -F "	$3	" "$STATE_FILE" || true)"
    if [[ -z "$row" ]]; then
      echo "Error: No such object: $3" >&2
      exit 1
    fi
    if [[ "${FAKE_DOCKER_FAIL:-}" == "inspect" ]]; then
      echo "Error: inspect に失敗しました" >&2
      exit 1
    fi
    if [[ "$2" == '{{index .Config.Labels "com.docker.compose.project"}}' ]]; then
      # compose の label。無いコンテナは空文字（本物は index が空文字を返す）。
      printf '%s\n' "$(printf '%s\n' "$row" | cut -f 4)"
      exit 0
    fi
    [[ "$2" == '{{.State.Pid}}' ]] || { echo "fake docker: 想定外の inspect の format: $2" >&2; exit 2; }
    if [[ "$(printf '%s\n' "$row" | cut -f 3)" == "running" ]]; then
      echo "${FAKE_CONTAINER_PID:-4242}"
    else
      echo 0
    fi
    ;;
  wait)
    if [[ "${1:-}" == dev-runner-* ]]; then
      # 前回のコンテナの終了待ち。FAKE_WAIT_FAIL=1 は接続障害など(失敗で抜ける)。FAKE_WAIT_SIGNAL は待っている最中に親へ送る信号。
      if [[ -n "${FAKE_WAIT_SIGNAL:-}" ]]; then kill -s "$FAKE_WAIT_SIGNAL" "$PPID"; exit 143; fi
      [[ "${FAKE_WAIT_FAIL:-0}" != "1" ]] || { echo "error during connect: daemon unreachable" >&2; exit 1; }
      exit 0
    fi
    [[ $# -eq 1 ]] || { echo "fake docker: wait の引数は 1 つだけを想定しています" >&2; exit 2; }
    if ! grep -qF "	$1	" "$STATE_FILE"; then
      echo "Error response from daemon: No such container: $1" >&2
      exit 1
    fi
    # 止まったことにする（本物はここで止まるまで待つ）。
    sed "s/	$1	running/	$1	exited/" "$STATE_FILE" >"$STATE_FILE.new"
    mv "$STATE_FILE.new" "$STATE_FILE"
    echo "${FAKE_WAIT_CODE:-137}"
    ;;
  restart | stop)
    [[ $# -ge 1 ]] || { echo "fake docker: $sub に ID がありません" >&2; exit 2; }
    for cid in "$@"; do
      if ! grep -qF "	$cid	" "$STATE_FILE"; then
        echo "Error response from daemon: No such container: $cid" >&2
        exit 1
      fi
    done
    if [[ -n "${FAKE_DOCKER_SIGNAL:-}" && "$sub" == "restart" ]]; then
      # 再起動の最中に、dev（親）がシグナルを受ける状況（ssh の切断など）を作る。
      kill -s "$FAKE_DOCKER_SIGNAL" "$PPID"
      exit 1
    fi
    if [[ "${FAKE_DOCKER_FAIL:-}" == "$sub" ]]; then
      echo "Error response from daemon: $sub に失敗しました" >&2
      exit 1
    fi
    if [[ "$sub" == "restart" ]]; then new=running; else new=exited; fi
    for cid in "$@"; do
      sed "s/	$cid	[a-z]*/	$cid	$new/" "$STATE_FILE" >"$STATE_FILE.new"
      mv "$STATE_FILE.new" "$STATE_FILE"
      echo "$cid"
    done
    ;;
  image)
    # `image inspect <イメージ>`（存在確認）と、`image inspect --format <書式> <イメージ>`（ラベルの読み出し）だけを受ける。
    fmt=""
    if [[ $# -eq 4 && "$1" == "inspect" && "$2" == "--format" ]]; then fmt="$3"; set -- "$1" "$4"; fi
    [[ $# -eq 2 && "$1" == "inspect" ]] || { echo "fake docker: 想定外の image の引数: $*" >&2; exit 2; }
    [[ "${FAKE_IMAGE_MISSING:-0}" != "1" ]] || { echo "Error: No such image: $2" >&2; exit 1; }
    [[ "${FAKE_IMAGE_MISSING:-0}" != "daemon" ]] || { echo "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?" >&2; exit 1; }
    if [[ -n "$fmt" ]]; then
      [[ "$fmt" == '{{ index .Config.Labels "devhost.runner-version" }}' ]] || { echo "fake docker: 想定外の image inspect の書式: $fmt" >&2; exit 2; }
      # FAKE_IMAGE_LABEL: イメージのラベルの版（既定は 2.338.0。空文字ならラベル無し＝本物の docker と同じく空を出す）
      printf '%s\n' "${FAKE_IMAGE_LABEL-2.338.0}"
    fi
    ;;
  build)
    while [[ "${1:-}" == "--build-arg" || "${1:-}" == "--label" ]]; do shift 2; done
    [[ $# -eq 3 && "$1" == "-t" && "$3" == "-" ]] || { echo "fake docker: 想定外の build の引数: $*" >&2; exit 2; }
    cat >"$FAKE_STATE/build-stdin"
    ;;
  container)
    [[ $# -eq 4 && "$1" == "inspect" && "$2" == "--format" ]] || { echo "fake docker: 想定外の container の引数: $*" >&2; exit 2; }
    # FAKE_PREV: 前回のコンテナの状態(running / exited)。無ければコンテナ無し(本物は 1 で抜ける)。
    [[ -n "${FAKE_PREV:-}" ]] || { echo "Error: No such container: $4" >&2; exit 1; }
    echo "$FAKE_PREV"
    ;;
  network)
    case "${1:-}" in
      inspect)
        [[ $# -eq 4 && "$2" == "--format" ]] || { echo "fake docker: 想定外の network inspect の引数: $*" >&2; exit 2; }
        [[ -f "$FAKE_STATE/network" ]] || { echo "Error response from daemon: network $4 not found" >&2; exit 1; }
        echo "${FAKE_NET_BRIDGE:-dev-runner0} ${FAKE_NET_IPV6:-false}"
        ;;
      create)
        [[ "${FAKE_NET_CREATE_FAIL:-0}" != "1" ]] || { echo "Error response from daemon: network create に失敗しました" >&2; exit 1; }
        : >"$FAKE_STATE/network"
        echo "0123456789abcdef"
        ;;
      *) echo "fake docker: 想定外の network のサブコマンド: $*" >&2; exit 2 ;;
    esac
    ;;
  rm)
    [[ $# -eq 2 && "$1" == "-f" ]] || { echo "fake docker: 想定外の rm の引数: $*" >&2; exit 2; }
    ;;
  run)
    [[ "$1" == "--rm" && "$2" == "--name" ]] || { echo "fake docker: 想定外の run の引数: $*" >&2; exit 2; }
    # 試験の道具自身の変数（FAKE_*。期待する PAT を含む）は除く。docker のコンテナに渡る環境の側だけを見る。
    env | grep -v '^FAKE_' >"$FAKE_STATE/run-env" || true
    if [[ -n "${FAKE_RUN_SIGNAL:-}" ]]; then
      # コンテナの実行中に、ユニットが止められる状況（systemd が TERM を送る）。docker run は止まって 143 で抜ける。
      kill -s "$FAKE_RUN_SIGNAL" "$PPID"
      exit 143
    fi
    if [[ -n "${FAKE_CONFIG_MSG+x}" ]]; then
      # コンテナの中の bash -c のスクリプトを、偽の config.sh（FAKE_CONFIG_MSG を出して FAKE_CONFIG_RC で終わる）で本当に走らせる。
      ctr="$FAKE_STATE/ctr"
      mkdir -p "$ctr"
      # 受け取った引数を 1 引数 1 行で $FAKE_STATE/config-args へ記録する。--token の値は伏せる（記録に残さない）。
      printf '#!%s\nprev=""\nfor a in "$@"; do\n  if [ "$prev" = --token ]; then printf "%%s\\n" "<伏せ字>"; else printf "%%s\\n" "$a"; fi\n  prev="$a"\ndone >"%s/config-args"\necho "%s"\nexit %s\n' \
        "$BASH" "$FAKE_STATE" "$FAKE_CONFIG_MSG" "${FAKE_CONFIG_RC:-1}" >"$ctr/config.sh"
      printf '#!%s\nexit 0\n' "$BASH" >"$ctr/run.sh"
      chmod +x "$ctr/config.sh" "$ctr/run.sh"
      while [[ $# -gt 0 && "$1" != "bash" ]]; do shift; done
      shift 2
      script="$1"
      shift
      cd "$ctr"
      RUNNER_TOKEN=REGTOKEN123 "$BASH" -c "$script" "$@"
      exit $?
    fi
    exit "${FAKE_RUN_EXIT:-0}"
    ;;
  *) echo "fake docker: この試験が想定していないサブコマンドです: $sub" >&2; exit 2 ;;
esac
EOF

cat >"$FAKEBIN/iptables" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/iptables" <<'EOF'
log_call iptables "$@"
if [[ "${1:-}" == "-C" && "${2:-}" == "FORWARD" ]]; then exit "${FAKE_IPT_FWD:-0}"; fi
if [[ "${1:-}" == "-C" ]]; then exit "${FAKE_IPT_CHECK:-1}"; fi
if [[ "${1:-}" == "-n" && "${2:-}" == "-L" ]]; then exit "${FAKE_IPT_LIST:-1}"; fi
exit 0
EOF

# iptables-restore: 引数を記録し、標準入力を $FAKE_STATE/restore-in へ写す。FAKE_IPTR_FAIL=1 で失敗する。
cat >"$FAKEBIN/iptables-restore" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/iptables-restore" <<'EOF'
log_call iptables-restore "$@"
cat >"$FAKE_STATE/restore-in"
[[ "${FAKE_IPTR_FAIL:-0}" != "1" ]] || { echo "iptables-restore: 失敗" >&2; exit 1; }
exit 0
EOF

cat >"$FAKEBIN/tmux" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/tmux" <<'EOF'
log_call tmux "$@"
case "${1:-}" in
  has-session)
    [[ "${2:-}" == "-t" ]] || exit 2
    name="${3#=}"
    for s in ${FAKE_TMUX_SESSIONS:-}; do [[ "$s" == "$name" ]] && exit 0; done
    echo "can't find session: $name" >&2
    exit 1
    ;;
  new-session) exit "${FAKE_TMUX_EXIT:-0}" ;;
  *) echo "fake tmux: この試験が想定していない呼び出しです: $*" >&2; exit 2 ;;
esac
EOF

cat >"$FAKEBIN/systemctl" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/systemctl" <<'EOF'
log_call systemctl "$@"
[[ "${1:-}" == "--user" ]] || { echo "fake systemctl: 想定外の呼び出し: $*" >&2; exit 2; }
case "${2:-}" in
  enable | disable)
    [[ $# -eq 4 && "$3" == "--now" ]] || { echo "fake systemctl: 想定外の呼び出し: $*" >&2; exit 2; }
    if [[ "$2" == "disable" && -n "${FAKE_SYSTEMCTL_STOP_SIGNAL:-}" ]]; then
      kill -s "$FAKE_SYSTEMCTL_STOP_SIGNAL" "$PPID"
    fi
    if [[ "${FAKE_SYSTEMCTL_FAIL:-}" == "$2" ]]; then
      echo "Failed to $2 unit: Unit file $4 does not exist." >&2
      exit 1
    fi
    exit 0
    ;;
esac
case "${2:-}" in
  list-units | list-unit-files)
    # list-units は「ユニット LOAD ACTIVE SUB 説明」、list-unit-files は「ユニット STATE」。引数のうち -- で始まらないものは glob。
    sub="$2"
    shift 2
    pats=()
    for a in "$@"; do [[ "$a" == --* ]] || pats+=("$a"); done
    emit() {
      local kind="$1" state="$2" u pat
      shift 2
      for u in "$@"; do
        for pat in "${pats[@]}"; do
          # shellcheck disable=SC2053
          if [[ "$u" == $pat ]]; then
            if [[ "$kind" == units ]]; then echo "$u loaded $state running desc"; else echo "$u $state disabled"; fi
          fi
        done
      done
    }
    if [[ "$sub" == list-units ]]; then
      emit units active ${FAKE_ACTIVE_UNITS:-}
      emit units activating ${FAKE_ACTIVATING_UNITS:-}
      emit units failed ${FAKE_FAILED_UNITS:-}
    else
      emit files enabled ${FAKE_ENABLED_UNITS:-}
      emit files enabled-runtime ${FAKE_ENABLED_RUNTIME_UNITS:-}
    fi
    exit 0
    ;;
esac
[[ $# -eq 3 ]] || { echo "fake systemctl: 想定外の呼び出し: $*" >&2; exit 2; }
case "$2" in
  is-enabled)
    for u in ${FAKE_ENABLED_UNITS:-}; do
      [[ "$u" == "$3" ]] && { echo enabled; exit 0; }
    done
    for u in ${FAKE_ENABLED_RUNTIME_UNITS:-}; do
      [[ "$u" == "$3" ]] && { echo enabled-runtime; exit 0; }
    done
    echo disabled
    exit 1
    ;;
  is-active)
    if [[ "${FAKE_SYSTEMCTL_FAIL:-}" == "is-active" ]]; then
      # 問い合わせ自体の失敗（バスに繋がらないなど）。状態の語は出さない。
      echo "Failed to connect to user scope bus via local transport: No medium found" >&2
      exit 1
    fi
    for u in ${FAKE_ACTIVE_UNITS:-}; do
      [[ "$u" == "$3" ]] && { echo active; exit 0; }
    done
    # Restart= の待機中は activating、失敗して止まったままのものは failed（どちらも 3 で抜ける）。
    for u in ${FAKE_ACTIVATING_UNITS:-}; do
      [[ "$u" == "$3" ]] && { echo activating; exit 3; }
    done
    # ユニットを入れていない機械（dev だけを置く運用）。本物は unknown を出し、4 で抜ける。
    for u in ${FAKE_UNKNOWN_UNITS:-}; do
      [[ "$u" == "$3" ]] && { echo unknown; exit 4; }
    done
    for u in ${FAKE_FAILED_UNITS:-}; do
      [[ "$u" == "$3" ]] && { echo failed; exit 3; }
    done
    echo inactive
    exit 3
    ;;
  stop | start)
    if [[ "$2" == "stop" && -n "${FAKE_SYSTEMCTL_STOP_SIGNAL:-}" ]]; then
      # ユニットを止めた直後に、dev（親）がシグナルを受ける状況（ssh の切断など）を作る。
      kill -s "$FAKE_SYSTEMCTL_STOP_SIGNAL" "$PPID"
    fi
    if [[ "${FAKE_SYSTEMCTL_FAIL:-}" == "$2" ]]; then
      echo "Failed to $2 $3: Access denied" >&2
      exit 1
    fi
    exit 0
    ;;
  *) echo "fake systemctl: 想定外のサブコマンド: $2" >&2; exit 2 ;;
esac
EOF

cat >"$FAKEBIN/git" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/git" <<'EOF'
# `-C <dir> ls-files --error-unmatch -- <名前>`（self-update が置き換え先の追跡を見る）は、追跡されていないと答える。
# dev の道具の呼び出しではないので、記録しない。追跡されているファイルの試験は、本物の git で行う。
if [[ $# -eq 6 && "$1" == "-C" && "$3" == "ls-files" && "$4" == "--error-unmatch" && "$5" == "--" ]]; then
  echo "error: pathspec '$6' did not match any file(s) known to git" >&2
  exit 1
fi
log_call git "$@"
[[ $# -eq 4 && "$1" == "-C" && "$3" == "pull" && "$4" == "--ff-only" ]] || { echo "fake git: 想定外の呼び出し: $*" >&2; exit 2; }
[[ -d "$2" ]] || { echo "fatal: cannot change to '$2': No such file or directory" >&2; exit 128; }
if [[ "${FAKE_GIT_FAIL:-0}" == "1" ]]; then
  echo "fatal: Not possible to fast-forward, aborting." >&2
  exit 128
fi
echo "Already up to date."
EOF

cat >"$FAKEBIN/ps" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/ps" <<'EOF'
log_call ps "$@"
[[ $# -eq 2 && "$1" == "-eo" && "$2" == "pid=,stat=" ]] || { echo "fake ps: 想定外の呼び出し: $*" >&2; exit 2; }
# 「PID 状態」の列を FAKE_STATE/ps（1 行 1 タスクで「PID 状態」）から、PID を右寄せで出す。
[[ -f "$FAKE_STATE/ps" ]] || exit 0
while read -r p s; do
  printf '%7s %s\n' "$p" "$s"
done <"$FAKE_STATE/ps"
EOF

cat >"$FAKEBIN/journalctl" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/journalctl" <<'EOF'
log_call journalctl "$@"
[[ $# -eq 6 && "$1" == "--user" && "$2" == "-u" && "$4" == "-n" && "$6" == "--no-pager" ]] || { echo "fake journalctl: 想定外の呼び出し: $*" >&2; exit 2; }
if [[ -n "${FAKE_JOURNAL:-}" ]]; then
  printf '%s\n' "$FAKE_JOURNAL"
else
  echo "-- No entries --"
fi
EOF
# コンテナの中で exec されるコマンド（dev exec の引数の素通しを見る）。
cat >"$FAKEBIN/codex" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
EOF
cat >>"$FAKEBIN/codex" <<'EOF'
log_call codex "$@"
exit "${FAKE_CODEX_EXIT:-0}"
EOF

# curl: ネットワークに出ない。`-fsSL <URL> -o <出力先>` だけを受け、URL の末尾のファイル名で
# $FAKE_CURL_DIR のファイルを写す（URL がリリースの取得先でなければ落とす）。FAKE_CURL_FAIL=1 は HTTP 404 相当（-f で 22）。
REAL_SLEEP_PATH="$(command -v sleep)"
cat >"$FAKEBIN/curl" <<EOF
#!$BASH_BIN
set -euo pipefail
. "$FAKEBIN/_log"
REAL_SLEEP="$REAL_SLEEP_PATH"
EOF
cat >>"$FAKEBIN/curl" <<'EOF'
log_call curl "$@"
if [[ "${*: -1}" == "https://api.github.com/repos/actions/runner/releases?per_page=100" ]]; then
  # 公開の API（PAT を付けない。-K を使わない）。FAKE_RELEASES は JSON の配列（既定は 2.338.0 だけ）。
  # FAKE_RELEASES_FAIL=500 は HTTP エラー。FAKE_API_NETFAIL=1 は通信の失敗。
  [[ "$*" != *Authorization* ]] || { echo "fake curl: 公開 API に認証を付けてはなりません: $*" >&2; exit 2; }
  if [[ "${FAKE_API_NETFAIL:-}" == "1" ]]; then
    echo "curl: (6) Could not resolve host: api.github.com" >&2
    exit 6
  fi
  if [[ -n "${FAKE_RELEASES_FAIL:-}" ]]; then
    printf '%s\n%s' '{"message":"error"}' "$FAKE_RELEASES_FAIL"
    exit 0
  fi
  default_releases='[{"tag_name":"v2.338.0","published_at":"2026-10-06T10:00:00Z","prerelease":false,"draft":false}]'
  printf '%s\n%s' "${FAKE_RELEASES:-$default_releases}" 200
  exit 0
fi
if [[ "${*: -1}" == "https://api.github.com/repos/ojos/devcontainer-host/releases/latest" ]]; then
  # devhost の最新の安定版（dev up / attach の知らせ。PAT を付けない）。FAKE_DH_LATEST は JSON（未設定は 404）。
  # FAKE_DH_LATEST_FAIL=500 は HTTP エラー。FAKE_API_NETFAIL=1 は通信の失敗。
  [[ "$*" != *Authorization* ]] || { echo "fake curl: 公開 API に認証を付けてはなりません: $*" >&2; exit 2; }
  if [[ "${FAKE_API_NETFAIL:-}" == "1" ]]; then
    echo "curl: (6) Could not resolve host: api.github.com" >&2
    exit 6
  fi
  if [[ -n "${FAKE_DH_LATEST_FAIL:-}" ]]; then
    printf '%s\n%s' '{"message":"error"}' "$FAKE_DH_LATEST_FAIL"
  elif [[ -n "${FAKE_DH_LATEST:-}" ]]; then
    printf '%s\n%s' "$FAKE_DH_LATEST" 200
  else
    printf '%s\n%s' '{"message":"Not Found"}' 404
  fi
  exit 0
fi
if [[ "${2:-}" == "-K" ]]; then
  # API。設定（PAT のヘッダ）は標準入力から来る。本物の `-w '\n%{http_code}'` に合わせ、本文の後に HTTP ステータスを出す
  # （-f を付けないので、HTTP エラーでも curl 自身は 0 で抜ける）。
  [[ $# -ge 10 && "$1" == "-sSL" && "$3" == "-" && "$4" == "-X" && "${*: -3:1}" == "-w" ]] || { echo "fake curl: 想定外の API の呼び出し: $*" >&2; exit 2; }
  method="$5"
  url="${*: -1}"
  cat >>"$FAKE_STATE/curl-config"
  # curl の子プロセスの環境(PAT が環境変数に現れないことを見る)。試験の道具自身の変数(FAKE_*)は除く。
  env | grep -v '^FAKE_' >>"$FAKE_STATE/curl-env" || true
  body="" code=200
  if [[ "${FAKE_API_NETFAIL:-}" == "1" ]]; then
    echo "curl: (6) Could not resolve host: api.github.com" >&2
    exit 6
  fi
  if ! grep -qF "Bearer ${FAKE_PAT_EXPECT:-?}\"" "$FAKE_STATE/curl-config"; then
    body='{"message":"Bad credentials"}' code=401
  else
    case "$method $url" in
      "POST https://api.github.com/orgs/"*"/actions/runners/registration-token")
        if [[ "${FAKE_API_FAIL:-}" == "token" ]]; then
          body='{"message":"error"}' code="${FAKE_API_CODE:-403}"
        else
          body='{"token":"REGTOKEN123","expires_at":"2099-01-01T00:00:00Z"}'
        fi
        ;;
      "GET https://api.github.com/orgs/"*"/actions/runners?per_page=100&page="* | "GET https://api.github.com/orgs/"*"/actions/runner-groups/"*"/runners?per_page=100&page="*)
        # 組織のランナーの一覧と、グループのランナーの一覧（dev runner route が数える）を同じ FAKE_RUNNERS で返す。
        page="${url##*page=}"
        if [[ "${FAKE_API_FAIL:-}" == "runners" ]]; then
          body='{"message":"error"}' code="${FAKE_API_CODE:-500}"
        elif [[ -n "${FAKE_RUNNERS:-}${FAKE_RUNNERS_FIRST:-}" ]]; then
          spec="${FAKE_RUNNERS:-}"
          if [[ "${FAKE_RUNNERS_PAGES:-1}" == "2" && "$page" == "1" ]]; then
            spec=""
            body="$(jq -nc '{total_count: 101, runners: [range(100) | {id: (2000 + .), name: "filler-\(.)", status: "offline", labels: []}]}')"
          else
            if [[ -n "${FAKE_RUNNERS_FIRST:-}" && ! -e "$FAKE_STATE/runners-first-done" ]]; then
              spec="$FAKE_RUNNERS_FIRST"
              : >"$FAKE_STATE/runners-first-done"
            fi
            body="$(jq -nc --arg s "$spec" '{runners: [$s | split(",")[] | select(length > 0) | split(":") | {id: 5, name: .[0], status: .[1], labels: [(.[2] // "") | split("+")[] | select(length > 0) | {name: .}]}], total_count: 1}')"
          fi
        elif [[ "${FAKE_PAGES:-1}" == "2" && "$page" == "1" ]]; then
          # 1 ページ目は 100 件で埋まり、自分のランナーは 2 ページ目にいる。
          body="$(jq -nc '{total_count: 101, runners: [range(100) | {id: (1000 + .), name: "filler-\(.)"}]}')"
        elif [[ -n "${FAKE_REGISTERED_NAME:-}" ]]; then
          body="$(printf '{"total_count":2,"runners":[{"id":11,"name":"other-host-r1"},{"id":77,"name":"%s"}]}' "$FAKE_REGISTERED_NAME")"
        else
          body='{"total_count":0,"runners":[]}'
        fi
        ;;
      "DELETE https://api.github.com/orgs/"*"/actions/runners/77") code=204 ;;
      "GET https://api.github.com/orgs/"*"/actions/runner-groups?per_page=100&page="*)
        # FAKE_GROUPS: 組織にあるグループ名（カンマ区切り。既定は Default,my-group）。FAKE_API_FAIL=groups で FAKE_API_CODE を返す
        if [[ "${FAKE_API_FAIL:-}" == "groups" ]]; then
          body='{"message":"error"}' code="${FAKE_API_CODE:-403}"
        else
          # 名前の前に visibility を置かない並び（キーの並び順に頼らない）。FAKE_GROUPS_PAD は前に N 件並べる。ページは 100 件ごと。
          page="${url##*page=}"
          body="$(jq -nc --arg g "${FAKE_GROUPS:-Default,my-group}" --arg vis "${FAKE_GROUP_VIS:-selected}" --argjson pad "${FAKE_GROUPS_PAD:-0}" --argjson page "$page" '
            ([range($pad) | "pad-\(.)"] + ($g | split(","))) as $all
            | {runner_groups: [$all | to_entries[] | {name: .value, id: (.key + 1), visibility: $vis}][(($page - 1) * 100):($page * 100)], total_count: ($all | length)}')"
        fi
        ;;
      "GET https://api.github.com/orgs/"*"/actions/runner-groups/"*"/repositories?per_page=100&page="*)
        if [[ "${FAKE_API_FAIL:-}" == "group-repos" ]]; then
          body='{"message":"error"}' code="${FAKE_API_CODE:-500}"
        elif [[ "${FAKE_API_BADBODY:-}" == "group-repos" ]]; then
          # 2xx だが、配列のキー（repositories）が無い応答。
          body='{"message":"ok"}'
        elif [[ "${FAKE_API_BADBODY:-}" == "group-repos-item" ]]; then
          # 2xx で配列はあるが、名前の無い要素が混ざる応答。
          body='{"total_count":2,"repositories":[{"name":"r-a"},{"id":9}]}'
        else
          page="${url##*page=}"
          # FAKE_GROUP_REPOS_AFTER: 対象の一覧の 1 回目の読み取り（1 ページ目）のあとは、この一覧に変わる（ロックを取るまでにグループが変わる仕込み）。
          # FAKE_GROUP_REPOS_AFTER_FAIL=1 なら、2 回目以降の読み取りが 500 になる。
          grpn="$(cat "$FAKE_STATE/group-repos-n" 2>/dev/null || echo 0)"
          if [[ "$page" == "1" ]]; then printf '%s' "$((grpn + 1))" >"$FAKE_STATE/group-repos-n"; fi
          grepos="${FAKE_GROUP_REPOS-r-a,r-b,r-c}"
          if [[ "$grpn" -ge 1 && -n "${FAKE_GROUP_REPOS_AFTER+x}" ]]; then grepos="$FAKE_GROUP_REPOS_AFTER"; fi
          if [[ "$grpn" -ge 1 && "${FAKE_GROUP_REPOS_AFTER_FAIL:-0}" == "1" ]]; then body='{"message":"error"}' code=500; fi
          [[ -n "$body" ]] || body="$(jq -nc --arg r "$grepos" --argjson gen "${FAKE_GROUP_REPOS_GEN:-0}" --argjson page "$page" '
            (if $gen > 0 then [range($gen) | "gen-\(. + 1)"] else ($r | split(",") | map(select(length > 0))) end) as $all
            | {total_count: ($all | length), repositories: [$all[] | {full_name: ("my-org/" + .), name: .}][(($page - 1) * 100):($page * 100)]}')"
        fi
        ;;
      "GET https://api.github.com/repos/"*"/actions/variables/ACTIONS_RUNS_ON" | "PATCH https://api.github.com/repos/"*"/actions/variables/ACTIONS_RUNS_ON" | "POST https://api.github.com/repos/"*"/actions/variables")
        rp="${url#https://api.github.com/repos/}"
        rp="${rp%%/actions/*}"
        repo="${rp#*/}"
        vf="$FAKE_VARS_DIR/$repo"
        # 本文（-d の次の引数）
        reqbody=""
        prev=""
        for arg in "$@"; do
          [[ "$prev" == "-d" ]] && reqbody="$arg"
          prev="$arg"
        done
        in_list() { case ",$2," in *",$1,"*) return 0 ;; esac; return 1; }
        if [[ "$method" == "GET" ]]; then
          if [[ "${FAKE_PAR_TRACK:-}" == "1" ]]; then
            mkdir -p "$FAKE_STATE/inflight"
            : >"$FAKE_STATE/inflight/$$"
            set -- "$FAKE_STATE"/inflight/*
            echo "$#" >>"$FAKE_STATE/par"
            "$REAL_SLEEP" 0.3
            rm -f "$FAKE_STATE/inflight/$$"
          fi
          if in_list "$repo" "${FAKE_VAR_FAIL:-}"; then
            body='{"message":"error"}' code=500
          elif in_list "$repo" "${FAKE_VAR_403:-}"; then
            body='{"message":"Resource not accessible by personal access token"}' code=403
          elif [[ -f "$vf" ]]; then
            body="$(jq -nc --rawfile v "$vf" '{value: $v, name: "ACTIONS_RUNS_ON"}')"
          else
            body='{"message":"Not Found"}' code=404
          fi
        else
          if in_list "$repo" "${FAKE_WRITE_FAIL:-}"; then
            body='{"message":"error"}' code=500
          elif in_list "$repo" "${FAKE_WRITE_FAIL_ONCE:-}" && [[ ! -e "$FAKE_STATE/once-$repo" ]]; then
            : >"$FAKE_STATE/once-$repo"
            body='{"message":"error"}' code=500
          elif [[ "$method" == "POST" ]]; then
            # POST は、変数の名前を本文の name から取る。既にあれば 409（空の値の既存の変数を未設定と取り違えると、ここで失敗する）。
            repo="${rp#*/}"
            vf="$FAKE_VARS_DIR/$repo"
            if [[ -f "$vf" ]]; then
              body='{"message":"Already exists"}' code=409
            else
              printf '%s' "$(printf '%s' "$reqbody" | jq -r '.value')" >"$vf"
              printf 'POST %s %s\n' "$repo" "$(printf '%s' "$reqbody" | jq -r '.value')" >>"$FAKE_STATE/writes"
              body='{}' code=201
            fi
          else
            if [[ -f "$vf" ]]; then
              printf '%s' "$(printf '%s' "$reqbody" | jq -r '.value')" >"$vf"
              printf 'PATCH %s %s\n' "$repo" "$(printf '%s' "$reqbody" | jq -r '.value')" >>"$FAKE_STATE/writes"
              body='' code=204
            else
              body='{"message":"Not Found"}' code=404
            fi
          fi
        fi
        ;;
      *) echo "fake curl: 想定外の API: $method $url" >&2; exit 2 ;;
    esac
  fi
  printf '%s\n%s' "$body" "$code"
  exit 0
fi
if [[ "${2:-}" == https://raw.githubusercontent.com/ojos/devcontainer-host/v*/CHANGELOG.md ]]; then
  # 版の知らせが読む配布先の CHANGELOG.md（-fsSL <URL> -o <ファイル> -m 5 --connect-timeout 2）。FAKE_DH_CHANGELOG のファイルを写す。
  # 未設定なら 404 相当（-f で 22）。
  [[ "$1" == "-fsSL" && "$3" == "-o" ]] || { echo "fake curl: 想定外の CHANGELOG の取得: $*" >&2; exit 2; }
  [[ -n "${FAKE_DH_CHANGELOG:-}" ]] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
  cp "$FAKE_DH_CHANGELOG" "$4"
  exit 0
fi
[[ $# -eq 4 && "$1" == "-fsSL" && "$3" == "-o" ]] || { echo "fake curl: 想定外の呼び出し: $*" >&2; exit 2; }
case "$2" in
  https://github.com/ojos/devcontainer-host/releases/latest/download/* | https://github.com/ojos/devcontainer-host/releases/download/v*/*) ;;
  *) echo "fake curl: リリースの取得先ではない URL です: $2" >&2; exit 2 ;;
esac
if [[ "${FAKE_CURL_FAIL:-0}" == "1" ]]; then
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
cp "$FAKE_CURL_DIR/${2##*/}" "$4"
EOF

# route の試験でだけ PATH の先頭に置く偽の sleep（待たずに返り、引数を記録する）。ほかの試験の呼び出しの記録には現れない。
ROUTEBIN="$WORK/routebin"
mkdir -p "$ROUTEBIN"
cat >"$ROUTEBIN/sleep" <<EOF
#!$BASH_BIN
. "$FAKEBIN/_log"
EOF
cat >>"$ROUTEBIN/sleep" <<'EOF'
log_call sleep "$@"
EOF
chmod +x "$ROUTEBIN/sleep"

chmod +x "$FAKEBIN/devcontainer" "$FAKEBIN/docker" "$FAKEBIN/tmux" "$FAKEBIN/systemctl" "$FAKEBIN/git" "$FAKEBIN/ps" "$FAKEBIN/journalctl" "$FAKEBIN/codex" "$FAKEBIN/curl" "$FAKEBIN/iptables" "$FAKEBIN/iptables-restore"
for t in cut cksum mv jq tar gzip cp chmod cmp dirname date; do
  p="$(command -v "$t")" || { echo "[devhost-selftest] $t が見つかりません" >&2; exit 1; }
  ln -s "$p" "$TOOLBIN/$t"
done
# ハッシュの道具は、sha256sum（GNU coreutils）が無い環境では shasum を使う（dev.sh と同じ分岐）。
for t in sha256sum shasum; do
  if p="$(command -v "$t")"; then ln -s "$p" "$TOOLBIN/$t"; fi
done

# ── 仕込み ────────────────────────────────────────────────────────────────────
PROJ="$WORK/projects"
mkdir -p "$PROJ/alpha/.devcontainer" "$PROJ/beta"
echo '{}' >"$PROJ/alpha/.devcontainer/devcontainer.json"
echo '{}' >"$PROJ/beta/.devcontainer.json"
CONF="$WORK/conf/projects"
mkdir -p "$WORK/conf"
cat >"$CONF" <<EOF
# 試験の設定
alpha  $PROJ/alpha   # 行末のコメント

beta   $PROJ/beta    tmux_session=work
EOF

# ── 回し方 ────────────────────────────────────────────────────────────────────
fail=0
n=0
ng() { echo "[devhost-selftest] FAIL: $*" >&2; fail=1; }

OUT="$WORK/out" ERR="$WORK/err" LOG="$WORK/calls"
STATE="$WORK/state"

reset_state() {
  rm -rf "$STATE"
  mkdir -p "$STATE"
  : >"$STATE/containers"
}

# run <期待する終了コード> <試験の名前> -- [VAR=値 ...] -- dev の引数 ...
# 呼び出しの記録は毎回空にしてから回す（コンテナの状態は reset_state までは持ち越す）。
run() {
  local want="$1" name="$2" code=0
  shift 2
  [[ "$1" == "--" ]] && shift
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ $# -gt 0 ]] && shift
  : >"$LOG"
  n=$((n + 1))
  CUR="$name"
  env -i HOME="$WORK/home" PATH="$FAKEBIN:$TOOLBIN" \
    DEV_PROJECTS_FILE="${T_CONF:-$CONF}" FAKE_LOG="$LOG" FAKE_STATE="$STATE" \
    DEV_PROC_ROOT="$WORK/proc" DEV_CGROUP_ROOT="$WORK/cg" \
    ${envs[@]+"${envs[@]}"} \
    "$BASH_BIN" "$DEV" "$@" >"$OUT" 2>"$ERR" <"${RUN_STDIN:-/dev/null}" || code=$?
  if [[ "$code" != "$want" ]]; then
    ng "$name: 終了コード want $want got $code"
    sed 's/^/    stderr: /' "$ERR" >&2
  fi
}

# 記録がこの並びと完全に一致すること。
expect_calls() {
  local want got
  want="$(printf '%s\n' "$@")"
  got="$(cat "$LOG")"
  if [[ "$got" != "$want" ]]; then
    ng "$CUR: 呼び出しの記録が違います"
    printf '    want:\n%s\n    got:\n%s\n' "$want" "$got" >&2
  fi
}

expect_no_calls() {
  if [[ -s "$LOG" ]]; then
    ng "$CUR: 下の道具を呼ばないはずが呼んでいます"
    sed 's/^/    /' "$LOG" >&2
  fi
}

expect_err() {
  grep -qF -- "$1" "$ERR" || { ng "$CUR: 標準エラーに「$1」がありません"; sed 's/^/    stderr: /' "$ERR" >&2; }
}

expect_out_line() {
  grep -qE -- "$1" "$OUT" || { ng "$CUR: 標準出力に /$1/ の行がありません"; sed 's/^/    stdout: /' "$OUT" >&2; }
}

A="$PROJ/alpha"
B="$PROJ/beta"

# ── 1. 設定ファイル ───────────────────────────────────────────────────────────
reset_state
T_CONF="$WORK/conf/none" run 2 "設定ファイルが無い" -- -- ls
expect_err "設定ファイルがありません: $WORK/conf/none"
expect_no_calls

bad() {
  local name="$1" body="$2" msg="$3"
  printf '%s\n' "$body" >"$WORK/conf/bad"
  T_CONF="$WORK/conf/bad" run 2 "壊れた設定: $name" -- -- up alpha
  expect_err "$msg"
  expect_no_calls
}
bad "パスが無い" "alpha" "$WORK/conf/bad:1: 「名前 絶対パス」の 2 つが要ります"
bad "相対パス" "alpha projects/alpha" "$WORK/conf/bad:1: パスは絶対パスで書きます"
bad "チルダ" "alpha ~/alpha" "$WORK/conf/bad:1: パスは絶対パスで書きます"
bad "知らないキー" "alpha $A aws_profile=x" "$WORK/conf/bad:1: 知らないキーです"
bad "キー=値でない" "alpha $A extra" "$WORK/conf/bad:1: 3 つ目以降は キー=値 で書きます"
bad "空の値" "alpha $A tmux_session=" "$WORK/conf/bad:1: 値が空です"
bad "名前の文字" "al/pha $A" "$WORK/conf/bad:1: 名前に使えるのは"
bad "重複" "$(printf '# c\nalpha %s\nalpha %s' "$A" "$B")" "$WORK/conf/bad:3: 名前が重複しています: alpha"
bad "空" "# だけ" "プロジェクトが 1 つもありません"

# CRLF で保存した設定でも読める（行末の CR がパスに混ざらない）。
printf 'alpha %s\r\n' "$A" >"$WORK/conf/crlf"
reset_state
T_CONF="$WORK/conf/crlf" run 0 "CRLF の設定" -- -- up alpha
expect_calls "devcontainer [up] [--workspace-folder] [$A]"

# パスの末尾の / は外して扱う（ラベルの照合で動いているコンテナを取り違えない）。
printf 'alpha %s//\n' "$A" >"$WORK/conf/slash"
reset_state
T_CONF="$WORK/conf/slash" run 0 "末尾に / のあるパス: up" -- -- up alpha
expect_calls "devcontainer [up] [--workspace-folder] [$A]"
T_CONF="$WORK/conf/slash" run 0 "末尾に / のあるパス: attach" -- -- attach alpha
expect_calls \
  "docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$A] [--format] [{{.ID}} {{.State}}]" \
  "devcontainer [exec] [--workspace-folder] [$A] [tmux] [new-session] [-A] [-s] [main]" \
  "tmux [new-session] [-A] [-s] [main]"

# ── 2. 未登録のプロジェクトを拒む ─────────────────────────────────────────────
for sub in up attach supervise rebuild doctor restart stop logs enable disable; do
  reset_state
  run 2 "未登録: $sub" -- -- "$sub" gamma
  expect_err "登録されていないプロジェクトです: gamma（登録済み: alpha beta）"
  expect_no_calls
done

# ── 3. up ─────────────────────────────────────────────────────────────────────
reset_state
run 0 "up alpha" -- -- up alpha
expect_calls "devcontainer [up] [--workspace-folder] [$A]"
expect_out_line '"outcome":"success"'
run 0 "up beta（.devcontainer.json の形）" -- -- up beta
expect_calls "devcontainer [up] [--workspace-folder] [$B]"
run 1 "up が失敗したら 1" -- FAKE_UP_FAIL=1 -- up alpha
expect_calls "devcontainer [up] [--workspace-folder] [$A]"
printf 'ghost %s/ghost\n' "$PROJ" >"$WORK/conf/ghost"
T_CONF="$WORK/conf/ghost" run 1 "ディレクトリが無いプロジェクト" -- -- up ghost
expect_err "プロジェクトのディレクトリがありません: $PROJ/ghost"
expect_no_calls
run 2 "up の引数が多い" -- -- up alpha beta
expect_no_calls

# ── 4. attach ─────────────────────────────────────────────────────────────────
reset_state
run 1 "attach: 止まっていたら入らない" -- -- attach alpha
expect_err "alpha のコンテナが動いていません。dev up alpha"
expect_calls "docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$A] [--format] [{{.ID}} {{.State}}]"
run 0 "up してから" -- -- up alpha
run 0 "attach alpha" -- -- attach alpha
expect_calls \
  "docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$A] [--format] [{{.ID}} {{.State}}]" \
  "devcontainer [exec] [--workspace-folder] [$A] [tmux] [new-session] [-A] [-s] [main]" \
  "tmux [new-session] [-A] [-s] [main]"
run 0 "up beta" -- -- up beta
run 0 "attach beta（tmux_session=work）" -- -- attach beta
expect_calls \
  "docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$B] [--format] [{{.ID}} {{.State}}]" \
  "devcontainer [exec] [--workspace-folder] [$B] [tmux] [new-session] [-A] [-s] [work]" \
  "tmux [new-session] [-A] [-s] [work]"

# ── 5. ls ─────────────────────────────────────────────────────────────────────
reset_state
run 0 "up alpha（ls の仕込み）" -- -- up alpha
run 0 "ls" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_TMUX_SESSIONS=main -- ls
expect_out_line '^NAME +CONTAINER +UNIT +TMUX$'
expect_out_line '^alpha +running +active +main$'
expect_out_line '^beta +none +inactive +-$'
expect_calls \
  "docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$A] [--format] [{{.ID}} {{.State}}]" \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "devcontainer [exec] [--workspace-folder] [$A] [tmux] [has-session] [-t] [=main]" \
  "tmux [has-session] [-t] [=main]" \
  "docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$B] [--format] [{{.ID}} {{.State}}]" \
  "systemctl [--user] [is-active] [dev-up@beta.service]"
run 0 "ls（tmux 無し）" -- -- ls
expect_out_line '^alpha +running +inactive +none$'
# systemctl の無い機械（ユニットを使わない）では UNIT を - にする。
mv "$FAKEBIN/systemctl" "$WORK/systemctl.off"
run 0 "ls（systemctl が無い）" -- -- ls
expect_out_line '^alpha +running +- +none$'
mv "$WORK/systemctl.off" "$FAKEBIN/systemctl"
run 2 "ls に余分な引数" -- -- ls alpha

# ── 6. supervise（ユニットの ExecStart）─────────────────────────────────────
reset_state
run 1 "supervise: 起こして、止まったら 0 以外で抜ける" -- FAKE_WAIT_CODE=0 -- supervise alpha
id_a="$(grep -F "$A	" "$STATE/containers" | cut -f 2)"
expect_calls \
  "devcontainer [up] [--workspace-folder] [$A]" \
  "docker [wait] [$id_a]"
expect_err "コンテナ $id_a が止まりました（終了コード 0）"
grep -qF "$A	$id_a	exited" "$STATE/containers" || ng "supervise: 待った後のコンテナが exited になっていません"
run 1 "supervise: 2 回目（止まったコンテナを同じ ID で起こし直す）" -- -- supervise alpha
expect_calls \
  "devcontainer [up] [--workspace-folder] [$A]" \
  "docker [wait] [$id_a]"
expect_err "（終了コード 137）"
run 1 "supervise: up が失敗したら待たない" -- FAKE_UP_FAIL=1 -- supervise alpha
expect_calls "devcontainer [up] [--workspace-folder] [$A]"
expect_err "devcontainer up が失敗しました"

# ── 6a. attach: exec が通らなければ、doctor と rebuild を案内して 1 で終わる ──
DOCKER_PS_A="docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$A] [--format] [{{.ID}} {{.State}}]"
reset_state
run 0 "up alpha（attach の失敗の仕込み）" -- -- up alpha
run 1 "attach: exec が通らない" -- FAKE_EXEC_FAIL=1 -- attach alpha
expect_calls \
  "$DOCKER_PS_A" \
  "devcontainer [exec] [--workspace-folder] [$A] [tmux] [new-session] [-A] [-s] [main]"
expect_err "dev doctor alpha"
expect_err "dev rebuild alpha"
# 入れたあとにセッションが異常終了した場合も、dev は 1 で終わり（0/1/2 の取り決め）、
# 元の終了コードは文面に出す（区別できないと言う）。
run 1 "attach: 1 以外のコードでも 1 で終わり、元のコードを文面に出す" -- FAKE_TMUX_EXIT=7 -- attach alpha
expect_err "dev doctor alpha"
expect_err "終了コード 7"
expect_err "区別できません"

# ── 6b. rebuild ───────────────────────────────────────────────────────────────
UP_RM="devcontainer [up] [--workspace-folder] [$A] [--remove-existing-container]"
reset_state
run 0 "up alpha（rebuild の仕込み）" -- -- up alpha
id_old="$(cut -f 2 "$STATE/containers")"
run 0 "rebuild: 動いているユニットを止め → 作り直し → 起こし直す" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service -- rebuild alpha
expect_calls \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "systemctl [--user] [stop] [dev-up@alpha.service]" \
  "$UP_RM" \
  "systemctl [--user] [start] [dev-up@alpha.service]"
id_new="$(cut -f 2 "$STATE/containers")"
[[ -n "$id_new" && "$id_new" != "$id_old" ]] || ng "rebuild: コンテナの ID が変わっていません（作り直していない）"
run 0 "rebuild: 動いていないユニットは止めも起こしもしない" -- -- rebuild alpha
expect_calls \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "$UP_RM"
run 1 "rebuild: 作り直しが失敗しても、止めたユニットは起こし直す" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_UP_FAIL=1 -- rebuild alpha
expect_calls \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "systemctl [--user] [stop] [dev-up@alpha.service]" \
  "$UP_RM" \
  "systemctl [--user] [start] [dev-up@alpha.service]"
expect_err "作り直しが失敗しました"
run 1 "rebuild: 作り直しが失敗し、ユニットも動いていなければ起こさない" -- FAKE_UP_FAIL=1 -- rebuild alpha
expect_calls \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "$UP_RM"
run 1 "rebuild: ユニットを止められなければ作り直さない" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_SYSTEMCTL_FAIL=stop -- rebuild alpha
expect_calls \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "systemctl [--user] [stop] [dev-up@alpha.service]"
run 1 "rebuild: 起こし直しに失敗したら 1" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_SYSTEMCTL_FAIL=start -- rebuild alpha
expect_err "を起こせませんでした"
mv "$FAKEBIN/systemctl" "$WORK/systemctl.off"
run 0 "rebuild: systemctl が無い機械ではユニットに触らない" -- -- rebuild alpha
expect_calls "$UP_RM"
mv "$WORK/systemctl.off" "$FAKEBIN/systemctl"
run 0 "rebuild --pull: 先に pull してから作り直す" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service -- rebuild alpha --pull
expect_calls \
  "git [-C] [$A] [pull] [--ff-only]" \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "systemctl [--user] [stop] [dev-up@alpha.service]" \
  "$UP_RM" \
  "systemctl [--user] [start] [dev-up@alpha.service]"
run 0 "rebuild --pull（オプションが先でも同じ）" -- -- rebuild --pull alpha
expect_calls \
  "git [-C] [$A] [pull] [--ff-only]" \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "$UP_RM"
run 1 "rebuild --pull: pull が失敗したら作り直さない（ユニットにも触らない）" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_GIT_FAIL=1 -- rebuild alpha --pull
expect_calls "git [-C] [$A] [pull] [--ff-only]"
expect_err "作り直しません"
# Restart= の待機中（activating）のユニットも止める。failed は止めない。
STOP_FLOW=(
  "systemctl [--user] [is-active] [dev-up@alpha.service]"
  "systemctl [--user] [stop] [dev-up@alpha.service]"
  "$UP_RM"
  "systemctl [--user] [start] [dev-up@alpha.service]"
)
run 0 "rebuild: activating のユニットも止めて、起こし直す" -- FAKE_ACTIVATING_UNITS=dev-up@alpha.service -- rebuild alpha
expect_calls "${STOP_FLOW[@]}"
run 0 "rebuild: failed のユニットは触らない" -- FAKE_FAILED_UNITS=dev-up@alpha.service -- rebuild alpha
expect_calls \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "$UP_RM"
# 作り直しの最中の中断（ssh の切断など）でも、止めたユニットは起こし直してから抜ける。
for sg in "TERM 143" "INT 130" "HUP 129"; do
  run "${sg#* }" "rebuild: ${sg% *} で中断されても起こし直す" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_UP_SIGNAL="${sg% *}" -- rebuild alpha
  expect_calls "${STOP_FLOW[@]}"
  expect_err "起こし直しました"
done
# ssh が切れると、標準出力・標準エラーが閉じる（#475）。閉じた出力への書き込みで抜けても、
# 止めたユニットは起こし直していること。終了コードは問わない（出力の失敗をどう返すかより、
# ユニットが戻ることが約束）。2 つの閉じ方を試す: fd を閉じる（EBADF）／読み手の居ないパイプ（SIGPIPE）。
run_closed() { # 閉じ方 名前 -- [環境変数...] -- 引数...
  local how="$1" name="$2"
  shift 2
  [[ "$1" == "--" ]] && shift
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ $# -gt 0 ]] && shift
  : >"$LOG"
  n=$((n + 1))
  CUR="$name"
  if [[ "$how" == "fd" ]]; then
    env -i HOME="$WORK/home" PATH="$FAKEBIN:$TOOLBIN" \
      DEV_PROJECTS_FILE="${T_CONF:-$CONF}" FAKE_LOG="$LOG" FAKE_STATE="$STATE" \
      ${envs[@]+"${envs[@]}"} \
      "$BASH_BIN" "$DEV" "$@" </dev/null >&- 2>&- || true
  else
    # shellcheck disable=SC2216 # sleep 0 は意図どおり stdin を読まない。読み手がすぐ閉じるパイプで EPIPE を起こすのが目的
    # 読み手（:）がすぐ終わるので、書き込みは SIGPIPE / EPIPE になる。標準エラーも同じパイプへ。
    { env -i HOME="$WORK/home" PATH="$FAKEBIN:$TOOLBIN" \
      DEV_PROJECTS_FILE="${T_CONF:-$CONF}" FAKE_LOG="$LOG" FAKE_STATE="$STATE" \
      ${envs[@]+"${envs[@]}"} \
      "$BASH_BIN" "$DEV" "$@" </dev/null 2>&1 || true; } | sleep 0
  fi
}
for how in fd pipe; do
  run_closed "$how" "rebuild: 出力が閉じていても（$how）、止めたユニットを起こし直す" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service -- rebuild alpha
  expect_calls "${STOP_FLOW[@]}"
  run_closed "$how" "rebuild: 出力が閉じたうえで HUP で中断されても（$how）、起こし直す" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_UP_SIGNAL=HUP -- rebuild alpha
  expect_calls "${STOP_FLOW[@]}"
done
run 0 "rebuild: unknown（ユニットを入れていない）は触らずに作り直す" -- FAKE_UNKNOWN_UNITS=dev-up@alpha.service -- rebuild alpha
expect_calls \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "$UP_RM"
# systemctl はあるのに状態を引けないときは、止めずに作り直さず、何も変えずに 1 で止まる。
run 1 "rebuild: 状態を引けなければ作り直さない" -- FAKE_SYSTEMCTL_FAIL=is-active -- rebuild alpha
expect_calls "systemctl [--user] [is-active] [dev-up@alpha.service]"
expect_err "状態が分からない"
expect_err "systemctl --user status dev-up@alpha.service"
run 2 "rebuild: 知らないオプション" -- -- rebuild alpha --force
expect_no_calls
run 2 "rebuild: 名前が無い" -- -- rebuild --pull
expect_no_calls
run 2 "rebuild: 名前が 2 つ" -- -- rebuild alpha beta
expect_no_calls

# ── 6c. doctor ────────────────────────────────────────────────────────────────
CG="/system.slice/docker-abc.scope"
# 偽の /proc と cgroup の木を作る。引数: コンテナの PID / cgroup のパス / pids.current / pids.max /
# pids.events の max / memory.events の oom_kill
mk_cg() {
  local cgdir="$WORK/cg$2"
  rm -rf "$WORK/proc" "$WORK/cg"
  rm -f "$STATE/ps"
  mkdir -p "$WORK/proc/$1" "$cgdir"
  printf '0::%s\n' "$2" >"$WORK/proc/$1/cgroup"
  printf '%s\n' "$3" >"$cgdir/pids.current"
  printf '%s\n' "$4" >"$cgdir/pids.max"
  printf 'max %s\n' "$5" >"$cgdir/pids.events"
  printf 'low 0\nhigh 0\nmax 0\noom 0\noom_kill %s\noom_group_kill 0\n' "$6" >"$cgdir/memory.events"
}
# ゾンビ（や他の状態）のタスクを足す。引数: PID / 状態 / cgroup のパス
add_task() {
  mkdir -p "$WORK/proc/$1"
  printf '0::%s\n' "$3" >"$WORK/proc/$1/cgroup"
  printf '%s %s\n' "$1" "$2" >>"$STATE/ps"
}
add_zombies() {
  local k
  for ((k = 0; k < $1; k++)); do add_task $((5000 + k)) Z "$2"; done
}
doctor_up() {
  reset_state
  run 0 "up alpha（doctor の仕込み）" -- -- up alpha
}

doctor_up
mk_cg 4242 "$CG" 20 1000 0 0
add_task 1 Ss /init.scope
add_task 4242 Ss "$CG"
add_task 4300 S "$CG/child"
add_zombies 3 "$CG"
add_task 4400 Z "$CG/child"
add_task 4401 Z "/system.slice/docker-abcdef.scope"   # 前方が同じだけの別の cgroup（数えない）
add_task 4402 Z /user.slice
run 0 "doctor: 正常" -- FAKE_ACTIVE_UNITS=dev-up@alpha.service FAKE_JOURNAL='Oct 07 12:00:00 host dev[1]: 起こしました' -- doctor alpha
expect_out_line '\[OK +\] コンテナ [0-9a-z]+ は running'
expect_out_line '\[OK +\] exec が通ります'
expect_out_line '\[OK +\] pids: 20 / 1000（2%）'
expect_out_line '\[OK +\] pids の上限に当たった回数: 0'
expect_out_line '\[OK +\] oom_kill: 0'
expect_out_line '\[OK +\] ゾンビ: 4$'
expect_out_line 'ユニット dev-up@alpha.service: active'
expect_out_line '^    Oct 07 12:00:00 host dev\[1\]: 起こしました'
expect_out_line '判定: OK'
id_a="$(cut -f 2 "$STATE/containers")"
expect_calls \
  "$DOCKER_PS_A" \
  "devcontainer [exec] [--workspace-folder] [$A] [true]" \
  "docker [inspect] [--format] [{{.State.Pid}}] [$id_a]" \
  "ps [-eo] [pid=,stat=]" \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "journalctl [--user] [-u] [dev-up@alpha.service] [-n] [10] [--no-pager]"

run 1 "doctor: exec が通らない" -- FAKE_EXEC_FAIL=1 -- doctor alpha
expect_out_line '\[FAIL\] exec が通りません（終了コード 1）: .*procReady not received'
expect_out_line '判定: FAIL'
expect_out_line 'dev rebuild alpha'
mk_cg 4242 "$CG" 18034 18039 5 0
run 1 "doctor: pids が上限に近い（issue の実測の値）" -- -- doctor alpha
expect_out_line '\[FAIL\] pids が上限に近づいています: 18034 / 18039（99%）'
expect_out_line '\[WARN\] pids の上限に当たった回数: 5'
mk_cg 4242 "$CG" 900 1000 0 0
run 1 "doctor: pids が上限のちょうど 90%" -- -- doctor alpha
expect_out_line '\[FAIL\] pids が上限に近づいています: 900 / 1000'
mk_cg 4242 "$CG" 899 1000 0 0
run 0 "doctor: pids が 90% 未満" -- -- doctor alpha
expect_out_line '\[OK +\] pids: 899 / 1000（89%）'
mk_cg 4242 "$CG" 899 max 0 0
run 0 "doctor: pids.max が max（上限なし）" -- -- doctor alpha
expect_out_line '上限なし'
mk_cg 4242 "$CG" 20 1000 0 0
add_zombies 100 "$CG"
run 3 "doctor: ゾンビが 100（WARN だけは 3）" -- -- doctor alpha
expect_out_line '\[WARN\] ゾンビ: 100（100 以上）'
expect_out_line '判定: WARN'
mk_cg 4242 "$CG" 20 1000 0 0
add_zombies 99 "$CG"
run 0 "doctor: ゾンビが 99" -- -- doctor alpha
expect_out_line '\[OK +\] ゾンビ: 99$'
mk_cg 4242 "$CG" 20 1000 1 0
run 3 "doctor: 上限に当たった回数が 1" -- -- doctor alpha
expect_out_line '\[WARN\] pids の上限に当たった回数: 1'
mk_cg 4242 "$CG" 20 1000 0 2
run 3 "doctor: oom_kill が 2" -- -- doctor alpha
expect_out_line '\[WARN\] OOM で殺された回数（oom_kill）: 2'
# pids.max が読めない・壊れている・0。「上限なし」の OK にしない。
mk_cg 4242 "$CG" 20 "" 0 0
run 3 "doctor: pids.max が空" -- -- doctor alpha
expect_out_line '\[WARN\] pids.max を読めません'
if grep -qF '上限なし' "$OUT"; then ng "pids.max が空なのに「上限なし」と出ています"; fi
mk_cg 4242 "$CG" 20 garbage 0 0
run 3 "doctor: pids.max が数でも max でもない" -- -- doctor alpha
expect_out_line '\[WARN\] pids.max が数でも max でもありません: garbage'
mk_cg 4242 "$CG" 0 0 0 0
run 1 "doctor: pids.max が 0" -- -- doctor alpha
expect_out_line '\[FAIL\] pids.max が 0 です'
# 上位の cgroup（systemd の slice の TasksMax など）の上限も見る。
set_pids() { # cgroup のパス pids.current pids.max
  mkdir -p "$WORK/cg$1"
  printf '%s\n' "$2" >"$WORK/cg$1/pids.current"
  printf '%s\n' "$3" >"$WORK/cg$1/pids.max"
}
mk_cg 4242 "$CG" 20 max 0 0
set_pids /system.slice 950 1000
run 1 "doctor: 上位の slice の上限に近い" -- -- doctor alpha
expect_out_line '\[FAIL\] pids が上限に近づいています: 950 / 1000（95%）（階層: /system.slice）'
mk_cg 4242 "$CG" 500 1000 0 0
set_pids /system.slice 960 10000
run 0 "doctor: 比が最大の階層を使う（自身 50% と上位 9%）" -- -- doctor alpha
expect_out_line "\\[OK +\\] pids: 500 / 1000（50%）（階層: $CG）"
mk_cg 4242 "$CG" 500 1000 0 0
set_pids / 2 2   # 根の pids.max は本物には無いが、あっても遡れること
run 1 "doctor: 根まで遡る" -- -- doctor alpha
expect_out_line '階層: /）'
# 上位の階層で pids.max が有限なのに pids.current が読めない／壊れているときは、黙って無視しない。
mk_cg 4242 "$CG" 20 max 0 0
mkdir -p "$WORK/cg/system.slice"
printf '1000\n' >"$WORK/cg/system.slice/pids.max"
run 3 "doctor: 上位の pids.current が読めない" -- -- doctor alpha
expect_out_line '\[WARN\] pids.current を読めません（階層: /system.slice。pids.max は 1000）'
if grep -qF '上限なし' "$OUT"; then ng "上位の pids.current が読めないのに「上限なし」と出ています"; fi
mk_cg 4242 "$CG" 20 max 0 0
mkdir -p "$WORK/cg/system.slice"
printf 'bogus\n' >"$WORK/cg/system.slice/pids.max"
run 3 "doctor: 上位の pids.max が壊れている" -- -- doctor alpha
expect_out_line '\[WARN\] pids.max が数でも max でもありません: bogus（階層: /system.slice）'
# TERM を無視する exec でも、猶予のあとに KILL して、doctor が時間内に FAIL で返る。
mk_cg 4242 "$CG" 20 1000 0 0
kstart=$SECONDS
run 1 "doctor: TERM を無視する exec" -- FAKE_EXEC_HANG=ignoreterm DEV_EXEC_TIMEOUT=1 DEV_EXEC_KILL_GRACE=1 -- doctor alpha
expect_out_line '\[FAIL\] exec が 1 秒で返りません'
if [[ $((SECONDS - kstart)) -ge 10 ]]; then ng "doctor: TERM を無視する exec で $((SECONDS - kstart)) 秒かかりました（KILL で止まるはず）"; fi
run 2 "doctor: DEV_EXEC_KILL_GRACE=0 は使い方の誤り" -- DEV_EXEC_KILL_GRACE=0 -- doctor alpha
expect_err "DEV_EXEC_KILL_GRACE は 1 以上の整数"
expect_no_calls
# DEV_EXEC_TIMEOUT は 1 以上の整数だけ（GNU の timeout 0 は無制限になり、返らなくなる）。
for tv in 0 abc -5 1.5; do
  run 2 "doctor: DEV_EXEC_TIMEOUT=$tv は使い方の誤り" -- DEV_EXEC_TIMEOUT="$tv" -- doctor alpha
  expect_err "DEV_EXEC_TIMEOUT は 1 以上の整数"
  expect_no_calls
done
# ゾンビが多い環境（issue の実測は 18000 超）でも、ゾンビの数に比例してプロセスを起こさず、
# 短い時間で終わる（1 個ごとにサブシェルを起こすと数十秒かかる）。
mk_cg 4242 "$CG" 20 1000 0 0
# mkdir の引数が長くなりすぎないよう（macOS の上限を超えうる）、1000 個ずつ作る。
zdirs=()
for ((zk = 20000; zk < 38000; zk++)); do
  zdirs+=("$WORK/proc/$zk")
  if [[ ${#zdirs[@]} -ge 1000 ]]; then
    mkdir -p "${zdirs[@]}"
    zdirs=()
  fi
done
for ((zk = 20000; zk < 38000; zk++)); do
  printf '0::%s\n' "$CG" >"$WORK/proc/$zk/cgroup"
  printf '%s Z\n' "$zk" >>"$STATE/ps"
done
zstart=$SECONDS
run 3 "doctor: ゾンビが 18000" -- -- doctor alpha
expect_out_line '\[WARN\] ゾンビ: 18000（100 以上）'
echo "[devhost-selftest] ゾンビ 18000 の doctor: $((SECONDS - zstart)) 秒" >&2
if [[ $((SECONDS - zstart)) -ge "${DEVHOST_ZOMBIE_LIMIT:-2}" ]]; then ng "doctor: ゾンビ 18000 の処理に $((SECONDS - zstart)) 秒かかりました（${DEVHOST_ZOMBIE_LIMIT:-2} 秒未満のはず）"; fi
# exec が返らないとき、timeout が無い環境でも時間で切る（この試験の PATH に timeout は無い）。
mk_cg 4242 "$CG" 20 1000 0 0
run 1 "doctor: exec が返らない（timeout 無し）" -- FAKE_EXEC_HANG=1 DEV_EXEC_TIMEOUT=1 -- doctor alpha
expect_out_line '\[FAIL\] exec が 1 秒で返りません'
mk_cg 4242 "$CG" 20 1000 1 0
run 1 "doctor: WARN と FAIL が混ざれば FAIL（1）" -- FAKE_EXEC_FAIL=1 -- doctor alpha
rm -rf "$WORK/proc" "$WORK/cg"
run 3 "doctor: cgroup を読めない（偽の木が空）は WARN" -- -- doctor alpha
expect_out_line '\[WARN\] .*cgroup v2 のパスを読めません'
# 止まっているコンテナと、無いコンテナ。
reset_state
run 1 "doctor: コンテナが無い" -- -- doctor alpha
expect_out_line '\[FAIL\] コンテナがありません'
expect_calls \
  "$DOCKER_PS_A" \
  "systemctl [--user] [is-active] [dev-up@alpha.service]" \
  "journalctl [--user] [-u] [dev-up@alpha.service] [-n] [10] [--no-pager]"
printf '%s\tdead01\texited\n' "$A" >"$STATE/containers"
run 1 "doctor: コンテナが止まっている" -- -- doctor alpha
expect_out_line '\[FAIL\] コンテナ dead01 の状態が exited です'
run 2 "doctor: 引数なし" -- -- doctor
expect_no_calls

# ── 6c'. restart ──────────────────────────────────────────────────────────────
UNIT_A="dev-up@alpha.service"
# compose の label を引く docker inspect の記録（restart / stop / disable は、まず app のコンテナの label を見る）。
insp() { printf 'docker [inspect] [--format] [{{index .Config.Labels "com.docker.compose.project"}}] [%s]' "$1"; }
IS_ACTIVE="systemctl [--user] [is-active] [$UNIT_A]"
reset_state
run 0 "up alpha（restart の仕込み）" -- -- up alpha
id_a="$(cut -f 2 "$STATE/containers")"
DOCKER_RESTART="docker [restart] [$id_a]"
RESTART_FLOW=(
  "$DOCKER_PS_A" "$(insp "$id_a")"
  "$IS_ACTIVE"
  "systemctl [--user] [stop] [$UNIT_A]"
  "$DOCKER_RESTART"
  "systemctl [--user] [start] [$UNIT_A]"
)
run 0 "restart: 動いているユニットを止め → docker restart → 起こし直す" -- FAKE_ACTIVE_UNITS="$UNIT_A" -- restart alpha
expect_calls "${RESTART_FLOW[@]}"
expect_out_line '再起動しました'
run 0 "restart: 動いていないユニットは止めも起こしもしない" -- -- restart alpha
expect_calls "$DOCKER_PS_A" "$(insp "$id_a")" "$IS_ACTIVE" "$DOCKER_RESTART"
run 0 "restart: failed のユニットは触らない" -- FAKE_FAILED_UNITS="$UNIT_A" -- restart alpha
expect_calls "$DOCKER_PS_A" "$(insp "$id_a")" "$IS_ACTIVE" "$DOCKER_RESTART"
run 0 "restart: unknown（ユニットを入れていない）は触らない" -- FAKE_UNKNOWN_UNITS="$UNIT_A" -- restart alpha
expect_calls "$DOCKER_PS_A" "$(insp "$id_a")" "$IS_ACTIVE" "$DOCKER_RESTART"
run 0 "restart: activating のユニットも止めて、起こし直す" -- FAKE_ACTIVATING_UNITS="$UNIT_A" -- restart alpha
expect_calls "${RESTART_FLOW[@]}"
mv "$FAKEBIN/systemctl" "$WORK/systemctl.off"
run 0 "restart: systemctl が無い機械ではユニットに触らない" -- -- restart alpha
expect_calls "$DOCKER_PS_A" "$(insp "$id_a")" "$DOCKER_RESTART"
mv "$WORK/systemctl.off" "$FAKEBIN/systemctl"
run 1 "restart: docker restart が失敗しても、止めたユニットは起こし直す" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_DOCKER_FAIL=restart -- restart alpha
expect_calls "${RESTART_FLOW[@]}"
expect_err "再起動が失敗しました"
run 1 "restart: ユニットを止められなければ再起動しない" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_SYSTEMCTL_FAIL=stop -- restart alpha
expect_calls "$DOCKER_PS_A" "$(insp "$id_a")" "$IS_ACTIVE" "systemctl [--user] [stop] [$UNIT_A]"
run 1 "restart: 起こし直しに失敗したら 1" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_SYSTEMCTL_FAIL=start -- restart alpha
expect_err "を起こせませんでした"
run 1 "restart: ユニットの状態を引けなければ再起動しない" -- FAKE_SYSTEMCTL_FAIL=is-active -- restart alpha
expect_calls "$DOCKER_PS_A" "$(insp "$id_a")" "$IS_ACTIVE"
expect_err "状態が分からない"
# 再起動の最中の中断（ssh の切断など）でも、止めたユニットは起こし直してから抜ける。
for sg in "TERM 143" "INT 130" "HUP 129"; do
  run "${sg#* }" "restart: ${sg% *} で中断されても起こし直す" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_DOCKER_SIGNAL="${sg% *}" -- restart alpha
  expect_calls "${RESTART_FLOW[@]}"
  expect_err "起こし直しました"
done
for how in fd pipe; do
  run_closed "$how" "restart: 出力が閉じていても（$how）、止めたユニットを起こし直す" -- FAKE_ACTIVE_UNITS="$UNIT_A" -- restart alpha
  expect_calls "${RESTART_FLOW[@]}"
  run_closed "$how" "restart: 出力が閉じたうえで HUP で中断されても（$how）、起こし直す" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_DOCKER_SIGNAL=HUP -- restart alpha
  expect_calls "${RESTART_FLOW[@]}"
done
reset_state
run 1 "restart: コンテナが無ければ、ユニットにも触らず止まる" -- FAKE_ACTIVE_UNITS="$UNIT_A" -- restart alpha
expect_calls "$DOCKER_PS_A"
expect_err "dev up alpha"
run 2 "restart: 引数が多い" -- -- restart alpha beta
expect_no_calls

# ── 6c''. stop ────────────────────────────────────────────────────────────────
reset_state
run 0 "up alpha（stop の仕込み）" -- -- up alpha
id_a="$(cut -f 2 "$STATE/containers")"
run 0 "stop: ユニットを先に止めてから、コンテナを止める（起こし直さない）" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_ENABLED_UNITS="$UNIT_A" -- stop alpha
expect_calls \
  "$IS_ACTIVE" \
  "systemctl [--user] [stop] [$UNIT_A]" \
  "$DOCKER_PS_A" "$(insp "$id_a")" \
  "docker [stop] [$id_a]"
grep -qF "$A	$id_a	exited" "$STATE/containers" || ng "stop: コンテナが exited になっていません"
# 戻す案内は dev enable に統一する（dev up ではユニットが起き直らない）。
expect_out_line '戻す: dev enable alpha'
if grep -qF '戻す: dev up' "$OUT"; then ng "stop: 戻す手段として dev up を案内しています（ユニットが起き直らない）"; fi
run 0 "stop: 止まっているコンテナには docker stop しない" -- -- stop alpha
expect_calls "$IS_ACTIVE" "$DOCKER_PS_A" "$(insp "$id_a")"
for st in paused restarting; do
  printf '%s\t%s\t%s\n' "$A" "$id_a" "$st" >"$STATE/containers"
  run 0 "stop: running でなくても $st のコンテナは止める" -- -- stop alpha
  expect_calls "$IS_ACTIVE" "$DOCKER_PS_A" "$(insp "$id_a")" "docker [stop] [$id_a]"
  grep -qF "$A	$id_a	exited" "$STATE/containers" || ng "stop: $st のコンテナが exited になっていません"
done
run 0 "up alpha（stop の仕込み 2）" -- -- up alpha
run 0 "stop: 動いていないユニットは止めない" -- -- stop alpha
expect_calls "$IS_ACTIVE" "$DOCKER_PS_A" "$(insp "$id_a")" "docker [stop] [$id_a]"
run 0 "up alpha（stop の仕込み 3）" -- -- up alpha
run 0 "stop: unknown（ユニットを入れていない）は触らずにコンテナを止める" -- FAKE_UNKNOWN_UNITS="$UNIT_A" -- stop alpha
expect_calls "$IS_ACTIVE" "$DOCKER_PS_A" "$(insp "$id_a")" "docker [stop] [$id_a]"
run 0 "up alpha（stop の仕込み 4）" -- -- up alpha
# ユニットを止めた直後に HUP（ssh の切断）を受けても、docker stop まで走る。
run 0 "stop: HUP を受けても docker stop まで走らせる" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_SYSTEMCTL_STOP_SIGNAL=HUP -- stop alpha
expect_calls "$IS_ACTIVE" "systemctl [--user] [stop] [$UNIT_A]" "$DOCKER_PS_A" "$(insp "$id_a")" "docker [stop] [$id_a]"
for how in fd pipe; do
  run 0 "up alpha（stop の閉じた出力の仕込み）" -- -- up alpha
  run_closed "$how" "stop: 出力が閉じていても（$how）、docker stop まで走らせる" -- FAKE_ACTIVE_UNITS="$UNIT_A" -- stop alpha
  expect_calls "$IS_ACTIVE" "systemctl [--user] [stop] [$UNIT_A]" "$DOCKER_PS_A" "$(insp "$id_a")" "docker [stop] [$id_a]"
done
run 0 "up alpha（stop の仕込み 4b）" -- -- up alpha
run 1 "stop: ユニットを止められなければ、コンテナには触らない" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_SYSTEMCTL_FAIL=stop -- stop alpha
expect_calls "$IS_ACTIVE" "systemctl [--user] [stop] [$UNIT_A]"
run 1 "stop: ユニットの状態を引けなければ止めない" -- FAKE_SYSTEMCTL_FAIL=is-active -- stop alpha
expect_calls "$IS_ACTIVE"
run 1 "stop: docker stop が失敗したら 1（ユニットは止めたまま）" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_DOCKER_FAIL=stop -- stop alpha
expect_calls "$IS_ACTIVE" "systemctl [--user] [stop] [$UNIT_A]" "$DOCKER_PS_A" "$(insp "$id_a")" "docker [stop] [$id_a]"
expect_err "戻す: dev enable alpha"
run 1 "stop: docker ps が失敗したら「コンテナが無い」にせず 1（ユニットは止めたあと）" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_DOCKER_FAIL=ps -- stop alpha
expect_calls "$IS_ACTIVE" "systemctl [--user] [stop] [$UNIT_A]" "$DOCKER_PS_A"
expect_err "コンテナの状態を引けませんでした"
if grep -qF '止めるものはありません' "$OUT"; then ng "stop: docker ps の失敗を「コンテナが無い」と取り違えています"; fi
run 1 "restart: docker ps が失敗したら 1（ユニットにも触らない）" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_DOCKER_FAIL=ps -- restart alpha
expect_calls "$DOCKER_PS_A"
expect_err "コンテナの状態を引けませんでした"
reset_state
run 0 "stop: コンテナが無ければ止めるものは無い（ユニットは止める）" -- FAKE_ACTIVE_UNITS="$UNIT_A" -- stop alpha
expect_calls "$IS_ACTIVE" "systemctl [--user] [stop] [$UNIT_A]" "$DOCKER_PS_A"
expect_out_line '止めるものはありません'
run 2 "stop: 名前が無い" -- -- stop
expect_no_calls
run 0 "stop: ユニットを入れていない機械では、戻し方に dev up を案内する" -- FAKE_UNKNOWN_UNITS="$UNIT_A" -- stop alpha
expect_out_line '戻す: dev up alpha'
if grep -qF 'dev enable' "$OUT"; then ng "stop: ユニットが無いのに dev enable を案内しています"; fi
# 登録先のディレクトリを動かした・消したあとでも、止められる（コンテナはパスのラベルで探す）。
printf 'ghost %s/ghost\n' "$PROJ" >"$WORK/conf/ghost"
DOCKER_PS_G="docker [ps] [-a] [--filter] [label=devcontainer.local_folder=$PROJ/ghost] [--format] [{{.ID}} {{.State}}]"
T_CONF="$WORK/conf/ghost" run 0 "stop: ディレクトリが無くても、ユニットを止めてコンテナを探す" -- FAKE_ACTIVE_UNITS="dev-up@ghost.service" -- stop ghost
expect_calls "systemctl [--user] [is-active] [dev-up@ghost.service]" "systemctl [--user] [stop] [dev-up@ghost.service]" "$DOCKER_PS_G"
T_CONF="$WORK/conf/ghost" run 0 "disable: ディレクトリが無くても、ユニットを無効にする" -- -- disable ghost
expect_calls "systemctl [--user] [disable] [--now] [dev-up@ghost.service]" "$DOCKER_PS_G"

# ── 6c'''-b. compose のプロジェクト全体（stop / disable / restart）──────────────
# app のコンテナの label com.docker.compose.project で、同じプロジェクトのコンテナを列挙する。
# 別のプロジェクトのコンテナ（other1）には触らない。cache1 は止まりきっている（exited）。
PS_PROJ="docker [ps] [-a] [--filter] [label=com.docker.compose.project=proj] [--format] [{{.ID}} {{.State}}]"
mk_compose() {
  reset_state
  printf '%s\tapp1\trunning\tproj\n-\tdb1\trunning\tproj\n-\tcache1\texited\tproj\n-\tother1\trunning\totherproj\n' "$A" >"$STATE/containers"
}
state_of() { grep -F "	$1	" "$STATE/containers" | cut -f 3; }
mk_compose
run 0 "stop(compose): ユニットを先に止め、プロジェクト全体の動いているコンテナをまとめて止める" -- FAKE_ACTIVE_UNITS="$UNIT_A" -- stop alpha
expect_calls \
  "$IS_ACTIVE" \
  "systemctl [--user] [stop] [$UNIT_A]" \
  "$DOCKER_PS_A" "$(insp app1)" "$PS_PROJ" \
  "docker [stop] [app1] [db1]"
[[ "$(state_of app1)" == exited && "$(state_of db1)" == exited ]] || ng "stop(compose): app1 / db1 が止まっていません"
[[ "$(state_of other1)" == running ]] || ng "stop(compose): 別のプロジェクトのコンテナを止めています"
expect_out_line 'コンテナ cache1 は動いていません（exited）'
mk_compose
run 0 "disable(compose): disable --now のあと、プロジェクト全体を止める" -- -- disable alpha
expect_calls \
  "systemctl [--user] [disable] [--now] [$UNIT_A]" \
  "$DOCKER_PS_A" "$(insp app1)" "$PS_PROJ" \
  "docker [stop] [app1] [db1]"
[[ "$(state_of other1)" == running ]] || ng "disable(compose): 別のプロジェクトのコンテナを止めています"
mk_compose
RESTART_COMPOSE=(
  "$DOCKER_PS_A" "$(insp app1)" "$PS_PROJ"
  "$IS_ACTIVE"
  "systemctl [--user] [stop] [$UNIT_A]"
  "docker [restart] [app1] [db1] [cache1]"
  "systemctl [--user] [start] [$UNIT_A]"
)
run 0 "restart(compose): ユニットを止め、プロジェクト全体を再起動して、起こし直す" -- FAKE_ACTIVE_UNITS="$UNIT_A" -- restart alpha
expect_calls "${RESTART_COMPOSE[@]}"
[[ "$(state_of cache1)" == running && "$(state_of other1)" == running ]] || ng "restart(compose): 再起動後の状態が違います"
for sg in "TERM 143" "HUP 129"; do
  mk_compose
  run "${sg#* }" "restart(compose): ${sg% *} で中断されても起こし直す" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_DOCKER_SIGNAL="${sg% *}" -- restart alpha
  expect_calls "${RESTART_COMPOSE[@]}"
  expect_err "起こし直しました"
done
mk_compose
run 1 "restart(compose): 再起動が失敗しても起こし直す" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_DOCKER_FAIL=restart -- restart alpha
expect_calls "${RESTART_COMPOSE[@]}"
mk_compose
run 1 "stop(compose): label を引けなければ「無い」にせず 1（ユニットは止めたまま）" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_DOCKER_FAIL=inspect -- stop alpha
expect_calls "$IS_ACTIVE" "systemctl [--user] [stop] [$UNIT_A]" "$DOCKER_PS_A" "$(insp app1)"
expect_err "コンテナの状態を引けませんでした"
run 1 "restart(compose): label を引けなければ、ユニットにも触らず 1" -- FAKE_ACTIVE_UNITS="$UNIT_A" FAKE_DOCKER_FAIL=inspect -- restart alpha
expect_calls "$DOCKER_PS_A" "$(insp app1)"
# compose の label が無いコンテナは、これまでどおり 1 つだけ（同じ名前のプロジェクトの列挙はしない）。
reset_state
printf '%s\tsolo1\trunning\n-\tdb9\trunning\tproj\n' "$A" >"$STATE/containers"
run 0 "stop(label なし): コンテナ 1 つだけ止める" -- -- stop alpha
expect_calls "$IS_ACTIVE" "$DOCKER_PS_A" "$(insp solo1)" "docker [stop] [solo1]"
[[ "$(state_of db9)" == running ]] || ng "stop(label なし): 関係ないコンテナを止めています"

# ── 6c'''. logs / enable / disable ────────────────────────────────────────────
reset_state
JOURNAL_PREFIX="journalctl [--user] [-u] [$UNIT_A] [-n]"
run 0 "logs: 既定は末尾 50 行" -- FAKE_JOURNAL='Oct 07 host dev[1]: ログ' -- logs alpha
expect_calls "$JOURNAL_PREFIX [50] [--no-pager]"
expect_out_line 'ログ'
run 0 "logs: -n で行数を変える" -- -- logs alpha -n 7
expect_calls "$JOURNAL_PREFIX [7] [--no-pager]"
run 0 "logs: -n が名前より前でも同じ" -- -- logs -n 3 alpha
expect_calls "$JOURNAL_PREFIX [3] [--no-pager]"
for bad_n in 0 abc -2 1.5 08 007; do
  run 2 "logs: -n $bad_n は使い方の誤り" -- -- logs alpha -n "$bad_n"
  expect_no_calls
done
run 2 "logs: -n に行数が無い" -- -- logs alpha -n
expect_no_calls
run 2 "logs: 知らないオプション" -- -- logs alpha --since today
expect_no_calls
run 0 "enable" -- -- enable alpha
expect_calls "systemctl [--user] [enable] [--now] [$UNIT_A]"
# disable は disable --now のあと、stop と同じ順番でコンテナまで止める（ユニットが先）。
reset_state
run 0 "up alpha（disable の仕込み）" -- -- up alpha
id_a="$(cut -f 2 "$STATE/containers")"
run 0 "disable: disable --now がコンテナの停止より先" -- -- disable alpha
expect_calls \
  "systemctl [--user] [disable] [--now] [$UNIT_A]" \
  "$DOCKER_PS_A" "$(insp "$id_a")" \
  "docker [stop] [$id_a]"
grep -qF "$A	$id_a	exited" "$STATE/containers" || ng "disable: コンテナが exited になっていません"
expect_out_line '戻す: dev enable alpha'
run 0 "disable: 止まっているコンテナには docker stop しない" -- -- disable alpha
expect_calls "systemctl [--user] [disable] [--now] [$UNIT_A]" "$DOCKER_PS_A" "$(insp "$id_a")"
run 1 "disable: ユニットを無効にできなければ、コンテナには触らない" -- FAKE_SYSTEMCTL_FAIL=disable -- disable alpha
expect_calls "systemctl [--user] [disable] [--now] [$UNIT_A]"
run 0 "up alpha（disable の仕込み 2）" -- -- up alpha
run 1 "disable: docker ps が失敗したら「コンテナが無い」にせず 1" -- FAKE_DOCKER_FAIL=ps -- disable alpha
expect_calls "systemctl [--user] [disable] [--now] [$UNIT_A]" "$DOCKER_PS_A"
expect_err "コンテナの状態を引けませんでした"
run 0 "disable: ユニットを止めた直後に HUP を受けても、docker stop まで走らせる" -- FAKE_SYSTEMCTL_STOP_SIGNAL=HUP -- disable alpha
expect_calls "systemctl [--user] [disable] [--now] [$UNIT_A]" "$DOCKER_PS_A" "$(insp "$id_a")" "docker [stop] [$id_a]"
reset_state
run 0 "disable: コンテナが無ければ止めるものは無い" -- -- disable alpha
expect_calls "systemctl [--user] [disable] [--now] [$UNIT_A]" "$DOCKER_PS_A"
expect_out_line '止めるものはありません'
run 1 "enable: systemctl が失敗したら 1" -- FAKE_SYSTEMCTL_FAIL=enable -- enable alpha
run 1 "disable: systemctl が失敗したら 1" -- FAKE_SYSTEMCTL_FAIL=disable -- disable alpha
run 2 "enable: 引数が多い" -- -- enable alpha beta
expect_no_calls

# ── 6c''''. exec ──────────────────────────────────────────────────────────────
reset_state
run 1 "exec: コンテナが動いていなければ止まる（コマンドは呼ばない）" -- -- exec alpha -- codex login
expect_calls "$DOCKER_PS_A"
expect_err "alpha のコンテナが動いていません。dev up alpha"
run 0 "up alpha（exec の仕込み）" -- -- up alpha
run 0 "exec: -- より後ろをそのまま devcontainer exec に渡す" -- -- exec alpha -- codex login --device-auth "a b" -- x
expect_calls \
  "$DOCKER_PS_A" \
  "devcontainer [exec] [--workspace-folder] [$A] [codex] [login] [--device-auth] [a b] [--] [x]" \
  "codex [login] [--device-auth] [a b] [--] [x]"
run 5 "exec: コマンドの終了コードをそのまま返す" -- FAKE_CODEX_EXIT=5 -- exec alpha -- codex login
run 2 "exec: -- が無い" -- -- exec alpha codex login
expect_no_calls
run 2 "exec: コマンドが無い" -- -- exec alpha --
expect_no_calls
run 2 "exec: 名前だけ" -- -- exec alpha
expect_no_calls
run 2 "exec: コマンドの先頭が -" -- -- exec alpha -- --help
expect_no_calls
run 2 "exec: 未登録" -- -- exec gamma -- true
expect_no_calls

# ── 6c'''''. self-update ──────────────────────────────────────────────────────
# 偽のリリース: 先頭 2 行が devhost の dev.sh のものである「新しい dev」を、個別の資産 dev.sh として置き、
# マニフェストの checksums["dev.sh"] にそのハッシュを記録する（本物のリリースと同じ形。アーカイブは取らない）。
REL="$WORK/release"
SELFDIR="$WORK/selfdir"
SELF="$SELFDIR/dev"
HDR1="$(sed -n '1p' "$DEV")"
HDR2="$(sed -n '2p' "$DEV")"
mkdir -p "$REL" "$SELFDIR"
printf '%s\n%s\necho new\n' "$HDR1" "$HDR2" >"$REL/dev.sh"
if command -v sha256sum >/dev/null 2>&1; then sum_cmd="sha256sum"; else sum_cmd="shasum -a 256"; fi
good_sum="$($sum_cmd "$REL/dev.sh" | awk '{ print $1 }')"
zero_sum="$(printf '%064d' 0)"
write_manifest() { printf '{\n  "package": "devcontainer-host",\n  "version": "0.0.0",\n  "checksums": {\n    "PACKAGE_ARCHIVE.tar.gz": "%s",\n    "SHA256SUMS": "%s",\n    "dev.sh": "%s"\n  }\n}\n' "$zero_sum" "$zero_sum" "$1" >"$REL/RELEASE-MANIFEST.json"; }
write_manifest "$good_sum"
mk_self() { printf '%s\n%s\necho old\n' "$HDR1" "$HDR2" >"$SELF"; chmod 0644 "$SELF"; }
expect_log_has() { grep -qF -- "$1" "$LOG" || { ng "$CUR: 呼び出しの記録に「$1」がありません"; sed 's/^/    /' "$LOG" >&2; }; }
expect_log_lacks() { if grep -qF -- "$1" "$LOG"; then ng "$CUR: 呼び出しの記録に「$1」があります（取らないはず）"; fi; }
expect_self_unchanged() { [[ "$(cat "$SELF")" == "$(printf '%s\n%s\necho old' "$HDR1" "$HDR2")" ]] || ng "$CUR: 置き換えないはずが、置き換え先が変わっています"; }
RELEASES="https://github.com/ojos/devcontainer-host/releases"

mk_self
run 0 "self-update: 照合が合えば、最新の dev.sh で置き換える" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_log_has "curl [-fsSL] [$RELEASES/latest/download/RELEASE-MANIFEST.json] [-o]"
expect_log_has "curl [-fsSL] [$RELEASES/download/v0.0.0/dev.sh] [-o]"
if grep -qF "latest/download/dev.sh" "$LOG"; then ng "self-update: dev.sh を latest から取っています（マニフェストの版から取るはず）"; fi
expect_log_lacks "PACKAGE_ARCHIVE"
expect_log_lacks "devcontainer-bootstrap"
cmp -s "$REL/dev.sh" "$SELF" || ng "self-update: 置き換え先が新しい dev.sh になっていません"
[[ -x "$SELF" ]] || ng "self-update: 置き換え後の dev に実行権限がありません"
[[ "$(ls -A "$SELFDIR")" == "dev" ]] || ng "self-update: 置き換え先のディレクトリに一時ファイルが残っています: $(ls -A "$SELFDIR")"
expect_out_line '置き換えました'
mk_self
run 0 "self-update --version: 版を固定した取得先から取る" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update --version v9.8.7
expect_log_has "curl [-fsSL] [$RELEASES/download/v9.8.7/RELEASE-MANIFEST.json] [-o]"
expect_log_has "curl [-fsSL] [$RELEASES/download/v9.8.7/dev.sh] [-o]"
cmp -s "$REL/dev.sh" "$SELF" || ng "self-update --version: 置き換え先が新しい dev.sh になっていません"
run 0 "self-update: すでに同じなら置き換えない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_out_line 'すでにこの版です'

mk_self
write_manifest "$(printf '%064d' 1)"
run 1 "self-update: ハッシュが合わなければ置き換えない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_err "ハッシュがマニフェストと合いません"
expect_self_unchanged
write_manifest "not-a-hash"
run 1 "self-update: マニフェストのハッシュが 64 桁の 16 進でなければ置き換えない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_self_unchanged
printf '{ "version": "0.0.0", "checksums": {} }\n' >"$REL/RELEASE-MANIFEST.json"
run 1 "self-update: マニフェストに dev.sh のハッシュが無ければ置き換えない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_err "checksums の dev.sh"
expect_log_lacks "/dev.sh] [-o]"
expect_self_unchanged
# archive のハッシュだけを持つ形（個別の資産を持たない版のマニフェスト）では、dev.sh を取らずに止まる。
printf '{ "version": "0.0.0", "checksums": { "PACKAGE_ARCHIVE.tar.gz": "%s" } }\n' "$good_sum" >"$REL/RELEASE-MANIFEST.json"
run 1 "self-update: archive のハッシュしか無いマニフェストでは置き換えない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_self_unchanged
write_manifest "$good_sum"

# ユニットのファイルの差の案内。ユニットは書き換えず、install.sh の再実行を案内する。
# 置き換えたあとは、動いているユニットの起こし直しも案内する。
UNIT_PATH="$WORK/home/.config/systemd/user/dev-up@.service"
printf '[Unit]\nDescription=リリースのユニット\n' >"$REL/dev-up@.service"
unit_good_sum="$($sum_cmd "$REL/dev-up@.service" | awk '{ print $1 }')"
write_manifest_unit() { printf '{\n  "package": "devcontainer-host",\n  "version": "0.0.0",\n  "checksums": {\n    "dev.sh": "%s",\n    "dev-up@.service": "%s"\n  }\n}\n' "$good_sum" "$1" >"$REL/RELEASE-MANIFEST.json"; }
put_unit() { mkdir -p "$(dirname "$UNIT_PATH")"; printf '%s' "$1" >"$UNIT_PATH"; }
expect_out_lacks() { if grep -qF -- "$1" "$OUT"; then ng "$CUR: 標準出力に「$1」があります（出さないはず）"; fi; }
write_manifest_unit "$unit_good_sum"

mk_self
put_unit $'[Unit]\nDescription=古いユニット\n'
run 0 "self-update: ユニットのファイルがリリースと違えば、install.sh の再実行を案内する" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_out_line 'install.sh を再実行してユニットを更新してください'
expect_out_line '置いてあるユニット（.*dev-up@.service）が、リリース（v0.0.0）の dev-up@.service と違います'
[[ "$(cat "$UNIT_PATH")" == "$(printf '[Unit]\nDescription=古いユニット')" ]] || ng "self-update: ユニットのファイルが書き換わっています"
expect_log_lacks "systemctl"
expect_log_lacks "dev-up@.service] [-o]"
cmp -s "$REL/dev.sh" "$SELF" || ng "self-update: ユニットが違っても dev.sh は置き換えるはずです"
expect_out_line '起こし直すまで古い dev のまま動き続けます'
expect_out_line 'dev restart <名前>'
expect_out_line 'systemctl --user restart dev-up@<名前>.service'

mk_self
cp "$REL/dev-up@.service" "$UNIT_PATH"
run 0 "self-update: ユニットのファイルがリリースと同じなら、install.sh の再実行は案内しない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_out_lacks 'install.sh を再実行'
expect_out_line '起こし直すまで古い dev のまま動き続けます'
cmp -s "$REL/dev-up@.service" "$UNIT_PATH" || ng "self-update: ユニットのファイルが書き換わっています"

put_unit $'[Unit]\nDescription=古いユニット\n'
run 0 "self-update: すでに同じ dev でも、ユニットが違えば install.sh の再実行を案内する（起こし直しは案内しない）" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_out_line 'すでにこの版です'
expect_out_line 'install.sh を再実行してユニットを更新してください'
expect_out_lacks '起こし直すまで'

rm -f "$UNIT_PATH"
mk_self
run 0 "self-update: ユニットのファイルを置いていなければ、ユニットの案内はしない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_out_lacks 'install.sh を再実行'
[[ ! -e "$UNIT_PATH" ]] || ng "self-update: ユニットのファイルを作っています"

mk_self
put_unit $'[Unit]\nDescription=古いユニット\n'
run 0 "self-update --version: ユニットの差の案内に --version を引き継ぐ" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update --version v9.8.7
expect_out_line 'bash install.sh --version v9.8.7'
mk_self
run 0 "self-update（版の指定なし）: 案内に --version は付けない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_out_line 'install.sh を再実行してユニットを更新してください'
expect_out_lacks 'bash install.sh --version'

mk_self
put_unit $'[Unit]\nDescription=古いユニット\n'
write_manifest "$good_sum"
run 0 "self-update: マニフェストにユニットのハッシュが無ければ、ユニットの案内はしない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_out_lacks 'install.sh を再実行'
rm -f "$UNIT_PATH"
write_manifest "$good_sum"
rm -f "$REL/dev-up@.service"
mk_self

# 版のないマニフェスト（最新を指定したとき）では、dev.sh をどの版から取るか決められないので止まる。
printf '{ "checksums": { "dev.sh": "%s" } }\n' "$good_sum" >"$REL/RELEASE-MANIFEST.json"
run 1 "self-update: 最新で、マニフェストに版が無ければ置き換えない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_err "--version vX.Y.Z で版を指定"
expect_self_unchanged
write_manifest "$good_sum"
# 版を固定したときは、マニフェストに版が無くても取れる。
printf '{ "checksums": { "dev.sh": "%s" } }\n' "$good_sum" >"$REL/RELEASE-MANIFEST.json"
run 0 "self-update --version: マニフェストに版が無くても固定した版で取る" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update --version v1.2.3
write_manifest "$good_sum"
mk_self

# git で追跡されている dev.sh（リポジトリのチェックアウト）は置き換えない。追跡されていなければ、
# 作業ツリーの中（ホームを ~/.git で管理している機械など）でも置き換える。
# 偽の git ではなく本物の git が要るので、PATH に本物の git を足した実行環境を作る（git が無い環境では飛ばす）。
if REAL_GIT="$(command -v git)"; then
  GITPATH="$WORK/gitpath"
  mkdir -p "$GITPATH"
  ln -s "$REAL_GIT" "$GITPATH/git"
  ln -s "$FAKEBIN/curl" "$GITPATH/curl"
  ln -s "$BASH_BIN" "$GITPATH/bash"  # git がラッパー（#!/usr/bin/env bash）でも動くように
  GITDIR="$WORK/checkout"
  mkdir -p "$GITDIR/packages/devcontainer-host"
  printf '%s\n%s\necho old\n' "$HDR1" "$HDR2" >"$GITDIR/packages/devcontainer-host/dev.sh"
  "$REAL_GIT" -C "$GITDIR" init -q
  "$REAL_GIT" -C "$GITDIR" add packages/devcontainer-host/dev.sh
  run 1 "self-update: git で追跡されている dev.sh は置き換えない" -- PATH="$GITPATH:$TOOLBIN" DEV_SELF_PATH="$GITDIR/packages/devcontainer-host/dev.sh" FAKE_CURL_DIR="$REL" -- self-update
  expect_err "git で追跡されているファイルです"
  expect_no_calls
  [[ "$(cat "$GITDIR/packages/devcontainer-host/dev.sh")" == "$(printf '%s\n%s\necho old' "$HDR1" "$HDR2")" ]] || ng "self-update: git で追跡されている dev.sh が書き換わっています"
  # ホームが git の作業ツリーでも、置いた dev（追跡されていない）は更新できる。
  GITHOME="$WORK/githome"
  mkdir -p "$GITHOME/.local/bin"
  "$REAL_GIT" -C "$GITHOME" init -q
  printf '%s\n%s\necho old\n' "$HDR1" "$HDR2" >"$GITHOME/.local/bin/dev"
  run 0 "self-update: ~/.git があるホームでも、追跡されていない dev は更新できる" -- PATH="$GITPATH:$TOOLBIN" DEV_SELF_PATH="$GITHOME/.local/bin/dev" FAKE_CURL_DIR="$REL" -- self-update
  cmp -s "$REL/dev.sh" "$GITHOME/.local/bin/dev" || ng "self-update: ~/.git があるホームの dev が更新されていません"
else
  echo "[devhost-selftest] git が無いので、追跡されているファイルの試験を飛ばします" >&2
fi
# ディレクトリは置き換えない。
mkdir -p "$WORK/dirdev"
run 1 "self-update: 置き換え先がディレクトリなら止まる" -- DEV_SELF_PATH="$WORK/dirdev" FAKE_CURL_DIR="$REL" -- self-update
expect_err "ディレクトリです"
expect_no_calls

# 置き換え先は、2 行目が説明文の全文と違っても「# dev — 」で始まれば devhost の dev.sh とみなす（版をまたいで更新できる）。
printf '%s\n%s\necho old\n' "$HDR1" '# dev — 別の版の説明文' >"$SELF"
run 0 "self-update: 置き換え先の 2 行目が別の版の説明文でも、更新できる" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
cmp -s "$REL/dev.sh" "$SELF" || ng "self-update: 別の版の説明文の dev が更新されていません"
mk_self

# devhost の dev.sh でない置き場所には、取得もせずに止まる。
printf '#!/bin/sh\necho other tool\n' >"$SELF"
run 1 "self-update: 置き換え先が devhost の dev.sh でなければ、取得もしない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_err "devhost の dev.sh だと確かめられません"
expect_no_calls
[[ "$(cat "$SELF")" == "$(printf '#!/bin/sh\necho other tool')" ]] || ng "self-update: devhost の dev.sh でない置き換え先が書き換わっています"
run 1 "self-update: 置き換え先が無ければ止まる" -- DEV_SELF_PATH="$SELFDIR/none" FAKE_CURL_DIR="$REL" -- self-update
expect_no_calls
mk_self
ln -s "$SELF" "$SELFDIR/link"
run 1 "self-update: 置き換え先がリンクなら止まる" -- DEV_SELF_PATH="$SELFDIR/link" FAKE_CURL_DIR="$REL" -- self-update
expect_err "リンクです"
expect_no_calls
expect_self_unchanged
rm -f "$SELFDIR/link"

# 取得した dev.sh が devhost のものでなければ（ハッシュは合っていても）置き換えない。
BADREL="$WORK/release-bad"
mkdir -p "$BADREL"
# bad_release <dev.sh の中身を書く関数の出力先>: $BADREL/dev.sh のハッシュを記録したマニフェストを書く。
write_bad_manifest() { printf '{ "version": "1.0.0", "checksums": { "dev.sh": "%s" } }\n' "$($sum_cmd "$BADREL/dev.sh" | awk '{ print $1 }')" >"$BADREL/RELEASE-MANIFEST.json"; }
printf '%s\n%s\nif then fi (\n' "$HDR1" "$HDR2" >"$BADREL/dev.sh"
write_bad_manifest
mk_self
run 1 "self-update: 取得した dev.sh に構文の誤りがあれば置き換えない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$BADREL" -- self-update
expect_err "構文の誤り"
expect_self_unchanged
# 取得物も、bash の shebang と「# dev — 」で始まる 2 行目が要る（sh や無関係なスクリプトは置かない）。
for badhead in '#!/bin/sh' '#!/bin/false'; do
  printf '%s\n%s\necho x\n' "$badhead" "$HDR2" >"$BADREL/dev.sh"
  write_bad_manifest
  run 1 "self-update: 取得物の 1 行目が $badhead なら置き換えない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$BADREL" -- self-update
  expect_err "devhost の dev.sh だと確かめられません"
  expect_self_unchanged
done
printf '%s\n%s\necho x\n' "$HDR1" '# 別のスクリプト' >"$BADREL/dev.sh"
write_bad_manifest
run 1 "self-update: 取得物の 2 行目が「# dev — 」で始まらなければ置き換えない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$BADREL" -- self-update
expect_self_unchanged
# 2 行目の説明文が違っても、「# dev — 」で始まれば置き換わる（将来の版が説明文を変えても更新できる）。
printf '%s\n%s\necho future\n' "$HDR1" '# dev — 将来の版の説明文' >"$BADREL/dev.sh"
write_bad_manifest
run 0 "self-update: 取得物の 2 行目の説明文が違っても、「# dev — 」で始まれば置き換える" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$BADREL" -- self-update
cmp -s "$BADREL/dev.sh" "$SELF" || ng "self-update: 2 行目の説明文が違う取得物で置き換わっていません"
mk_self
# マニフェストにはハッシュがあるのに、リリースに dev.sh の資産が無いとき（取得できない）。
NOREL="$WORK/release-none"
mkdir -p "$NOREL"
printf '{ "version": "1.0.0", "checksums": { "dev.sh": "%s" } }\n' "$good_sum" >"$NOREL/RELEASE-MANIFEST.json"
run 1 "self-update: リリースに dev.sh の資産が無ければ置き換えない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$NOREL" -- self-update
expect_err "dev.sh を取得できません"
expect_self_unchanged
run 1 "self-update: 取得に失敗したら置き換えない" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" FAKE_CURL_FAIL=1 -- self-update
expect_err "取得できません"
expect_self_unchanged
run 2 "self-update: 版の形が違う" -- DEV_SELF_PATH="$SELF" -- self-update --version latest
expect_no_calls
run 2 "self-update: 版に URL の区切りが混ざる" -- DEV_SELF_PATH="$SELF" -- self-update --version 'v1.0.0/../x'
expect_no_calls
run 2 "self-update: --version に値が無い" -- DEV_SELF_PATH="$SELF" -- self-update --version
run 2 "self-update: --version の値が空" -- DEV_SELF_PATH="$SELF" -- self-update --version ""
expect_no_calls
run 2 "self-update: 知らない引数" -- DEV_SELF_PATH="$SELF" -- self-update alpha
expect_no_calls

# ── 6c''''''. version ─────────────────────────────────────────────────────────
# 版は dev.sh の DEV_VERSION から出す。設定ファイルが無くても出せる（外部の機械に入れた直後に確かめるため）。
WANT_VERSION="$(sed -n 's/^DEV_VERSION="\(v[0-9][0-9.]*\)"$/\1/p' "$DEV")"
[[ "$(printf '%s\n' "$WANT_VERSION" | wc -l | tr -d ' ')" == "1" && -n "$WANT_VERSION" ]] || ng "dev.sh の DEV_VERSION=\"vX.Y.Z\" の行が 1 つではありません（リリースの手順が書き換えられなくなります）: $WANT_VERSION"
run 0 "version: 版を出す" -- DEV_PROJECTS_FILE="$WORK/conf/none" -- version
expect_out_line "^dev $WANT_VERSION\$"
expect_no_calls
run 0 "--version: version と同じ" -- DEV_PROJECTS_FILE="$WORK/conf/none" -- --version
expect_out_line "^dev $WANT_VERSION\$"
expect_no_calls
run 2 "version: 引数は受け付けない" -- -- version x
expect_err "使い方: dev version"
expect_no_calls
# 公開物の版の書き込み: リリースの手順（stamp_host_version）が置き換えるのと同じ形の行を、別の版に差し替えても出せる。
STAMPED="$WORK/dev-stamped.sh"
sed 's/^DEV_VERSION=".*"$/DEV_VERSION="v7.8.9"/' "$DEV" >"$STAMPED"
if [[ "$("$BASH_BIN" "$STAMPED" --version)" != "dev v7.8.9" ]]; then ng "version: 書き換えた版を出していません"; fi

# ── 6d. help ──────────────────────────────────────────────────────────────────
for sub in ls up attach supervise rebuild doctor runner restart stop logs enable disable exec self-update version help; do
  run 0 "help $sub" -- -- help "$sub"
  expect_no_calls
  expect_out_line "^dev $sub — "
  expect_out_line '^終了コード: '
done
run 0 "help（引数なし）は使い方の一覧" -- -- help
expect_out_line "^プロジェクトの一覧は $CONF から読む。\$"
run 0 "help: 設定ファイルの既定のパスを展開して出す" -- XDG_CONFIG_HOME=/xdg DEV_PROJECTS_FILE= -- help
expect_out_line '^プロジェクトの一覧は /xdg/dev/projects から読む。$'
# shellcheck disable=SC2016 # 展開されない ${ がリテラルで出ていないことを見る検査なので、単一引用符が意図
if grep -qF '${' "$OUT"; then ng "help の出力に未展開の \${...} があります"; fi
expect_out_line '^  dev rebuild <名前> \[--pull\]$'
expect_out_line '^  dev doctor <名前>$'
run 2 "help: 知らないサブコマンド" -- -- help bogus
expect_err "知らないサブコマンドです: bogus"
expect_no_calls
run 2 "help: 引数が多い" -- -- help ls up
expect_no_calls
run 0 "rebuild の説明にユニットの扱いがある" -- -- help rebuild
expect_out_line 'ユニット dev-up@<名前> が inactive / failed / unknown（ユニットを入れていない）でなければ止める'
expect_out_line '3 が失敗しても、INT / HUP / TERM で中断されても'

# ── 6d'. 新しい版の知らせ（dev up / dev attach） ─────────────────────────────
# 端末が付いているときだけ聞く。試験では端末を付けられないので、DEV_UPDATE_CHECK_FORCE_TTY=1 で端末の判定だけを差し替え、
# 答えは標準入力（RUN_STDIN のファイル）から渡す。キャッシュは HOME の下（$WORK/home/.cache/dev/update-check）。
UREL="$WORK/urelease"
UCSTATE="$WORK/home/.cache/dev/update-check"
mkdir -p "$UREL"
# shellcheck disable=SC2016 # 偽の install.sh の本文。ここでは展開しない（実行時に展開される）
printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" >"$FAKE_STATE/install-args"' >"$UREL/install.sh"
uc_sum="$($sum_cmd "$UREL/install.sh" | awk '{ print $1 }')"
write_uc_manifest() { printf '{\n  "package": "devcontainer-host",\n  "version": "99.0.0",\n  "checksums": {\n    "install.sh": "%s"\n  }\n}\n' "$1" >"$UREL/RELEASE-MANIFEST.json"; }
write_uc_manifest "$uc_sum"
UAPI="https://api.github.com/repos/ojos/devcontainer-host/releases/latest"
NOTES_MIG='### Summary\n- 変更\n\n### 移行\n- 手作業が要る'
NOTES_NONE='### Summary\n- 変更'
uc_latest() { printf '{"tag_name":"%s","prerelease":%s,"draft":false,"body":"%s"}' "$1" "${2:-false}" "${3:-$NOTES_NONE}"; }
# 配布先の CHANGELOG.md（版の知らせが「移行」の節を探す）。CL_MIG は、途中の版 v50.0.0 に「移行」があり、今より古い v0.0.1 の「移行」は数えない形。
CL_NONE="$WORK/changelog-none.md"
CL_MIG="$WORK/changelog-mig.md"
printf '%s\n' '# devcontainer-host Release Notes' '## v99.0.0' '### Summary' '- 変更' '## v0.0.1' '### Summary' >"$CL_NONE"
printf '%s\n' '# devcontainer-host Release Notes' '## v99.0.0' '### Summary' '- 変更' '## v50.0.0' '### Summary' '### 移行' '- 手作業' '## v0.0.1' '### 移行' '- 古い' >"$CL_MIG"
# install.sh が置く ~/.local/bin/dev から動いている形にする（別の場所の dev からは追従しない）。
mkdir -p "$WORK/home/.local/bin"
: >"$WORK/home/.local/bin/dev"
UC_TTY=(DEV_UPDATE_CHECK_FORCE_TTY=1 FAKE_CURL_DIR="$UREL" FAKE_DH_CHANGELOG="$CL_NONE" DEV_SELF_PATH="$WORK/home/.local/bin/dev")
printf 'y\n' >"$WORK/ans-y"
printf 'n\n' >"$WORK/ans-n"
uc_reset() { rm -f "$UCSTATE"; rm -f "$STATE/install-args" "$WORK/uc-off"; }
uc_asked() { grep -qF "追従しますか" "$ERR"; }
expect_asked() { uc_asked || { ng "$CUR: 追従の質問が出ていません"; sed 's/^/    stderr: /' "$ERR" >&2; }; }
expect_not_asked() { if uc_asked; then ng "$CUR: 質問が出ないはずが出ています"; fi; }
expect_attached() { expect_log_has "tmux [new-session] [-A] [-s] [main]"; }
expect_api_called() { expect_log_has "$UAPI"; }
expect_api_not_called() { expect_log_lacks "$UAPI"; }

reset_state
run 0 "知らせ: 仕込み（up alpha。端末なし）" -- -- up alpha
expect_log_lacks "$UAPI"
uc_reset

# 端末なし（既定の試験の呼び出しと同じ）: 何も聞かず、何も取得せず、何も出さない。
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: 端末なしの attach は何もしない" -- FAKE_CURL_DIR="$UREL" FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- attach alpha
expect_api_not_called
expect_not_asked
expect_attached
[[ ! -e "$UCSTATE" ]] || ng "知らせ: 端末なしでキャッシュを書いています"
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: 端末なしの up も何もしない" -- FAKE_CURL_DIR="$UREL" FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- up alpha
expect_api_not_called
expect_not_asked
# 端末が付いていても、dev supervise からは聞かない。
RUN_STDIN="$WORK/ans-y" run 1 "知らせ: supervise は端末の判定が通っても聞かない" -- "${UC_TTY[@]}" FAKE_DH_LATEST="$(uc_latest v99.0.0)" FAKE_WAIT_CODE=0 -- supervise alpha
expect_api_not_called
expect_not_asked
run 0 "知らせ: 仕込み（supervise が止めたコンテナを起こし直す。端末なし）" -- -- up alpha

# 新しい版あり + n: 今の版・最新の版を示し、attach は続け、N を記録する。
uc_reset
RUN_STDIN="$WORK/ans-n" run 0 "知らせ: 新しい版があれば聞く（n）" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- attach alpha
expect_api_called
expect_asked
expect_err "今 $(bash "$DEV" version | awk '{ print $2 }') → 最新 v99.0.0"
expect_attached
[[ ! -e "$STATE/install-args" ]] || ng "知らせ: n なのに install.sh を実行しています"
expect_log_lacks "install.sh"
grep -qx 'declined=v99.0.0' "$UCSTATE" || ng "知らせ: N の版を記録していません"
if [[ -s "$STATE/fd8-leak" ]]; then ng "知らせ: ロックの記述子（8）が、あとに起動する道具へ漏れています: $(tr '\n' ' ' <"$STATE/fd8-leak")"; fi
expect_err "「移行」の節はありません"
# 1 日 1 回: 同じ日にもう一度打っても、問い合わせない。
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: 同じ日は問い合わせない（1 日 1 回）" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- attach alpha
expect_api_not_called
expect_not_asked
expect_attached
# 次の日: 問い合わせるが、N と答えた版は聞かない。
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: 次の日は問い合わせるが、N の版は聞かない" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-17 FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- attach alpha
expect_api_called
expect_not_asked
[[ ! -e "$STATE/install-args" ]] || ng "知らせ: N の版で install.sh を実行しています"
grep -qx 'declined=v99.0.0' "$UCSTATE" || ng "知らせ: 問い合わせの後に N の記録が消えています"
# さらに新しい版が出たら、また聞く。
RUN_STDIN="$WORK/ans-n" run 0 "知らせ: さらに新しい版が出たらまた聞く" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-18 FAKE_DH_LATEST="$(uc_latest v99.1.0)" -- attach alpha
expect_asked
grep -qx 'declined=v99.1.0' "$UCSTATE" || ng "知らせ: 新しい版の N を記録していません"

# 新しい版なし（同じ版・古い版）・プレリリース: 聞かない。
cur_ver="$(bash "$DEV" version | awk '{ print $2 }')"
uc_reset
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: 同じ版なら聞かない" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST="$(uc_latest "$cur_ver")" -- attach alpha
expect_api_called
expect_not_asked
expect_attached
uc_reset
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: 古い版なら聞かない" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST="$(uc_latest v0.0.1)" -- attach alpha
expect_not_asked
uc_reset
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: プレリリースは聞かない" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST="$(uc_latest v99.0.0 true)" -- attach alpha
expect_not_asked
expect_attached

# API の失敗・通信の失敗・読めない応答: 黙って通す（attach は続く。1 日 1 回には数える）。
uc_reset
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: API が HTTP エラーなら黙って通す" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST_FAIL=500 -- attach alpha
expect_api_called
expect_not_asked
expect_attached
[[ ! -s "$ERR" ]] || { ng "知らせ: API の失敗で標準エラーに出力しています"; sed 's/^/    stderr: /' "$ERR" >&2; }
grep -qx 'checked=2026-10-16' "$UCSTATE" || ng "知らせ: 失敗した日を 1 日 1 回に数えていません"
uc_reset
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: 通信の失敗なら黙って通す" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_API_NETFAIL=1 -- attach alpha
expect_not_asked
expect_attached
[[ ! -s "$ERR" ]] || ng "知らせ: 通信の失敗で標準エラーに出力しています"
uc_reset
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: 版を読めない応答なら黙って通す" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST='{"tag_name":"not-a-version"}' -- attach alpha
expect_not_asked
expect_attached
uc_reset
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: 本文が JSON でない応答なら黙って通す" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST='<html>' -- attach alpha
expect_not_asked
expect_attached

# 止める設定: 環境変数・設定ファイル。どちらも問い合わせ自体をしない。
uc_reset
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: DEV_UPDATE_CHECK=off で止まる" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK=off FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- attach alpha
expect_api_not_called
expect_not_asked
expect_attached
printf '# 新しい版の知らせを止める\n  off  # 理由\n' >"$WORK/uc-off"
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: 設定ファイルの off で止まる" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_FILE="$WORK/uc-off" FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- up alpha
expect_api_not_called
expect_not_asked
RUN_STDIN="$WORK/ans-n" run 0 "知らせ: 環境変数が設定ファイルより優先する（on 側）" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK=on DEV_UPDATE_CHECK_FILE="$WORK/uc-off" FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- attach alpha
expect_asked
printf '# 止めていない\n' >"$WORK/uc-off"
uc_reset
RUN_STDIN="$WORK/ans-n" run 0 "知らせ: 設定ファイルに off が無ければ止まらない" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_FILE="$WORK/uc-off" FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- attach alpha
expect_asked

# 答えが来ない（入力の終端）: N とみなして先へ進むが、N の版としては記録しない（次の日にまた聞く）。
uc_reset
run 0 "知らせ: 答えが来なければ先へ進み、N は記録しない" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- attach alpha
expect_asked
expect_attached
if grep -q declined "$UCSTATE"; then ng "知らせ: 答えていないのに N を記録しています"; fi
[[ ! -e "$STATE/install-args" ]] || ng "知らせ: 答えが無いのに install.sh を実行しています"

# y: 「移行」の節がある版は目立たせる。最新の版のマニフェストと install.sh を取得し、照合してから install.sh --version <最新> を呼ぶ。
uc_reset
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: y なら照合済みの install.sh を呼び、attach は続ける" -- "${UC_TTY[@]}" FAKE_DH_CHANGELOG="$CL_MIG" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST="$(uc_latest v99.0.0 false "$NOTES_MIG")" -- attach alpha
expect_asked
expect_err "★★ 移行の手順のある版を含みます（v50.0.0）"
expect_log_has "curl [-fsSL] [$RELEASES/download/v99.0.0/RELEASE-MANIFEST.json] [-o]"
expect_log_has "curl [-fsSL] [$RELEASES/download/v99.0.0/install.sh] [-o]"
[[ "$(cat "$STATE/install-args" 2>/dev/null)" == "--version v99.0.0" ]] || ng "知らせ: install.sh が --version v99.0.0 で呼ばれていません: $(cat "$STATE/install-args" 2>/dev/null)"
expect_err "dev restart <名前>"
expect_err "dev runner build"
expect_err "systemctl --user restart"
expect_attached
# up でも同じ。
uc_reset
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: dev up でも y で追従して up を続ける" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- up alpha
[[ "$(cat "$STATE/install-args" 2>/dev/null)" == "--version v99.0.0" ]] || ng "知らせ: up で install.sh が呼ばれていません"
expect_log_has "devcontainer [up] [--workspace-folder] [$A]"
# 本文が空なら、移行の節を判定できないと伝える。
uc_reset
RUN_STDIN="$WORK/ans-n" run 0 "知らせ: CHANGELOG.md を読めなければ判定できないと伝える" -- "${UC_TTY[@]}" FAKE_DH_CHANGELOG= DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST='{"tag_name":"v99.0.0","prerelease":false,"draft":false}' -- attach alpha
expect_err "移行の節があるかは判定できませんでした"
# ~/.local/bin/dev ではない dev からは追従しない（install.sh が置くのは ~/.local/bin/dev だけなので、この dev は古いまま残る）。
uc_reset
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: ~/.local/bin/dev ではない dev からは追従せず、手順を案内する" -- "${UC_TTY[@]}" DEV_SELF_PATH="$WORK/elsewhere-dev" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- attach alpha
expect_err "ここからは追従しません"
expect_not_asked
if grep -q '^declined=' "$UCSTATE" 2>/dev/null; then ng "知らせ: 聞いていないのに N の記録（declined）を付けています"; fi
[[ ! -e "$STATE/install-args" ]] || ng "知らせ: 別の場所の dev なのに install.sh を実行しています"
expect_attached
# 同時に打った dev up / dev attach は、ロックを取れたほうだけが確かめる（取れなければ黙って先へ進む）。
uc_reset
mkdir -p "$(dirname "$UCSTATE")"
exec 9>>"$UCSTATE.lock"
if command -v flock >/dev/null 2>&1 && flock -n 9; then
  RUN_STDIN="$WORK/ans-y" run 0 "知らせ: もう一方がロックを持っていれば、問い合わせずに先へ進む" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- attach alpha
  expect_api_not_called
  expect_not_asked
  expect_attached
  flock -u 9
fi
exec 9>&-
# CHANGELOG.md に最新の版の節が無ければ、「移行は無い」と言わず、判定できないと伝える。
CL_STALE="$WORK/changelog-stale.md"
printf '%s\n' '## v50.0.0' '### Summary' >"$CL_STALE"
uc_reset
RUN_STDIN="$WORK/ans-n" run 0 "知らせ: CHANGELOG.md に最新の版の節が無ければ判定できないと伝える" -- "${UC_TTY[@]}" FAKE_DH_CHANGELOG="$CL_STALE" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- attach alpha
expect_err "移行の節があるかは判定できませんでした"
# 止める値は大文字・小文字を区別しない。
uc_reset
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: DEV_UPDATE_CHECK=OFF（大文字）でも止まる" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK=OFF FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- attach alpha
expect_not_asked
expect_api_not_called
# 失敗の理由をキャッシュに残す（黙って通すが、痕跡は残す）。
uc_reset
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: API の失敗の理由をキャッシュに残す" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST_FAIL=500 -- attach alpha
grep -q '^last_error=HTTP 500' "$UCSTATE" || ng "知らせ: 失敗の理由（last_error）を残していません"
expect_not_asked

# 照合が合わなければ install.sh を実行しない（attach は続く）。
uc_reset
write_uc_manifest "$zero_sum"
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: install.sh のハッシュが合わなければ実行しない" -- "${UC_TTY[@]}" DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- attach alpha
expect_err "install.sh のハッシュがマニフェストと合わない"
[[ ! -e "$STATE/install-args" ]] || ng "知らせ: ハッシュが合わないのに install.sh を実行しています"
expect_attached
write_uc_manifest "$uc_sum"
# 取得に失敗したら実行しない（attach は続く）。
uc_reset
RUN_STDIN="$WORK/ans-y" run 0 "知らせ: 取得に失敗したら実行しない" -- "${UC_TTY[@]}" FAKE_CURL_FAIL=1 DEV_UPDATE_CHECK_TODAY=2026-10-16 FAKE_DH_LATEST="$(uc_latest v99.0.0)" -- attach alpha
expect_err "取得できないので、追従しません"
[[ ! -e "$STATE/install-args" ]] || ng "知らせ: 取得に失敗したのに install.sh を実行しています"
expect_attached
uc_reset

# ── 6e. README の「コマンドの説明」と dev help の照合 ─────────────────────────
# README の各サブコマンドのブロック（### dev <名前> の次の ```text ... ```）が dev help <名前> の
# 出力と一致すること、README のサブコマンドの集合が dev の受け付ける集合と一致することを確かめる。
# dev の受け付ける集合は、dev help の一覧から取り、さらに 1 つずつ実際に受け付けることを確かめる。
README="${DEV_README:-$HERE/README.md}"
readme_check() {
  local readme="$1" bad=0 usage_set help_set readme_set s want got
  # dev が受け付ける集合は、dev help が判定に使う help_<名前> の定義（dev.sh）から取る。
  # usage の一覧（dev help）も同じ集合でなければ落とす。
  help_set="$(sed -n 's/^help_\([a-z][a-z-]*\)() {$/\1/p' "$DEV" | sort -u)"
  usage_set="$("$BASH_BIN" "$DEV" help | sed -n 's/^  dev \([a-z][a-z-]*\).*/\1/p' | sort -u)"
  readme_set="$(sed -n 's/^### dev \([a-z][a-z-]*\)$/\1/p' "$readme" | sort -u)"
  if [[ -z "$help_set" || "$help_set" != "$readme_set" || "$help_set" != "$usage_set" ]]; then
    echo "サブコマンドの集合が違います" >&2
    # shellcheck disable=SC2116,SC2086 # 改行区切りの集合を、語分割で 1 行にして出す意図（echo $x）
    printf '  help_ 関数: %s\n  usage:      %s\n  README:     %s\n' "$(echo $help_set)" "$(echo $usage_set)" "$(echo $readme_set)" >&2
    bad=1
  fi
  for s in $help_set; do
    # 実際に受け付ける（知らないサブコマンドなら help が 2 で落ちる）。
    "$BASH_BIN" "$DEV" help "$s" >/dev/null 2>&1 || { echo "dev help $s が通りません" >&2; bad=1; }
    want="$("$BASH_BIN" "$DEV" help "$s" 2>&1 || true)"
    got="$(awk -v h="### dev $s" '
      $0 == h { f = 1; next }
      f && !b && $0 == "```text" { b = 1; next }
      f && b && $0 == "```" { exit }
      f && b { print }
    ' "$readme")"
    if [[ -z "$got" || "$got" != "$want" ]]; then
      echo "README の dev $s のブロックが dev help $s の出力と違います" >&2
      bad=1
    fi
  done
  return "$bad"
}
CUR="README の照合"
n=$((n + 1))
if ! readme_check "$README"; then ng "README が dev help と一致しません"; fi
# dev が実際に受け付けるサブコマンドの確認: 一覧の各名前を引数なしで呼ぶと、使い方の誤り（2）で
# 「使い方: dev <名前>」と返る（知らないサブコマンドなら一覧の usage が出る）。help だけは 0。
for sub in ls up attach supervise rebuild doctor runner restart stop logs enable disable exec; do
  if [[ "$sub" == "ls" ]]; then
    run 2 "$sub は引数を受け付けない（使い方の誤り）" -- -- "$sub" x
  else
    run 2 "引数なしの $sub は使い方の誤り" -- -- "$sub"
  fi
  expect_err "使い方: dev $sub"
  expect_no_calls
done
# 検査が死んでいないこと: 1 行を書き換えた README では落ちる。
M="$WORK/readme.mut"
sed 's/^dev ls — /dev ls ー /' "$README" >"$M"
if readme_check "$M" >/dev/null 2>&1; then ng "README の説明の 1 行を書き換えても照合が通ります"; fi
sed 's/^終了コード: 0 = 作り直した/終了コード: 9 = 作り直した/' "$README" >"$M"
if readme_check "$M" >/dev/null 2>&1; then ng "README の終了コードの行を書き換えても照合が通ります"; fi
sed '/^### dev doctor$/d' "$README" >"$M"
if readme_check "$M" >/dev/null 2>&1; then ng "README からサブコマンドの見出しを消しても照合が通ります"; fi
# shellcheck disable=SC2016 # README へ足すのは展開しないリテラルのコードフェンス
{ cat "$README"; printf '\n### dev bogus\n\n```text\nx\n```\n'; } >"$M"
if readme_check "$M" >/dev/null 2>&1; then ng "README へ dev に無いサブコマンドを足しても照合が通ります"; fi
# 検査が元の README では通ること（変異のたびに通らなくなっただけ、を除く）。
readme_check "$README" >/dev/null 2>&1 || ng "README の照合が、変異の後で通らなくなりました"

# ── 6f. runner（自前のランナー）──────────────────────────────────────────────
# 偽の docker / curl で、登録用トークンの取得・--ephemeral かつ --rm のコンテナ・PAT を出さないこと・
# 権限の拒否・Docker のソケットの扱い・止めたときの登録の削除を見る。実機の API には出ない。
PATV="github_pat_TESTSECRET0123456789"
RCONF="$WORK/conf/runners"
printf '%s\n' "$PATV" >"$WORK/conf/runner-pat"
chmod 600 "$WORK/conf/runner-pat"
cp "$WORK/conf/runner-pat" "$WORK/conf/pat-loose"
chmod 644 "$WORK/conf/pat-loose"
cp "$WORK/conf/runner-pat" "$WORK/conf/pat-ro"
chmod 400 "$WORK/conf/pat-ro"
: >"$WORK/docker.sock"
cat >"$RCONF" <<EOF
# 試験のランナー
r1  my-org  labels=devhost,x   # 行末のコメント
r2  my-org  docker=yes
r3  my-org  pat_file=$WORK/conf/pat-loose
r4  my-org  pat_file=$WORK/conf/pat-ro
r5  my-org  docker=yes
r6  my-org  lan=allow
r7  my-org  lan=allow  docker=yes
g1  my-org  group=my-group
g2  my-org  labels=devhost,x  group=my-group
EOF
mkdir -p "$WORK/lock"
# 規則の印（root のスクリプトが置くもの）。ブリッジ名が合う印を既定で置き、個別の試験が差し替える。
NETMARK="$WORK/netmark/ready"
mkdir -p "$WORK/netmark"
printf 'bridge=dev-runner0\n' >"$NETMARK"
log_has() { grep -qE -- "$1" "$LOG" || { ng "$CUR: 呼び出しの記録に /$1/ がありません"; sed 's/^/    /' "$LOG" >&2; }; }
log_lacks() { if grep -qE -- "$1" "$LOG"; then ng "$CUR: 呼び出しの記録に /$1/ があってはなりません"; fi; }
# PAT の値が、どこにも出ていないこと（呼び出しの記録＝引数、docker へ渡った環境、標準出力・標準エラー）。
no_pat_leak() {
  local f
  for f in "$LOG" "$OUT" "$ERR" "$STATE/run-env" "$STATE/curl-env"; do
    if [[ -f "$f" ]] && grep -qF -- "TESTSECRET" "$f"; then ng "$CUR: PAT の値が $f に出ています"; fi
  done
}
# rrun <期待する終了コード> <名前> [VAR=値 ...] -- dev の引数 ...
rrun() {
  local want="$1" rname="$2" ev=()
  shift 2
  while [[ $# -gt 0 && "$1" != "--" ]]; do ev+=("$1"); shift; done
  [[ $# -gt 0 ]] && shift
  reset_state
  [[ " ${ev[*]-} " == *" FAKE_NET_EXISTS=1 "* ]] && : >"$STATE/network"
  run "$want" "$rname" -- DEV_RUNNER_NET_MARKER="$NETMARK" DEV_RUNNER_NET_WAIT=0 DEV_RUNNERS_FILE="$RCONF" DEV_RUNNER_HOSTNAME=h DEV_RUNNER_DOCKER_SOCK="$WORK/docker.sock" DEV_RUNNER_LOCK_DIR="$WORK/lock" \
    FAKE_PAT_EXPECT="$PATV" ${ev[@]+"${ev[@]}"} -- "$@"
}

rrun 0 "runner run: 登録用のトークンを取り、--ephemeral のランナーを --rm のコンテナで起こす" -- runner run r1
log_has '^curl \[-sSL\] \[-K\] \[-\] \[-X\] \[POST\] .*\[https://api.github.com/orgs/my-org/actions/runners/registration-token\]$'
log_has '^docker \[run\] \[--rm\] \[--name\] \[dev-runner-r1\] \[-e\] \[RUNNER_TOKEN\] \[--network\] \[dev-runner\] \[dev-runner:local\] \[bash\] \[-c\]'
log_has '\-\-ephemeral'
log_has '\[runner\] \[https://github.com/my-org\] \[h-r1\] \[devhost,x\]$'
grep -q '^RUNNER_TOKEN=REGTOKEN123$' "$STATE/run-env" || ng "$CUR: docker へ登録用のトークンが環境変数で渡っていません"
grep -qF "Bearer $PATV" "$STATE/curl-config" || ng "$CUR: PAT が curl の標準入力の設定で渡っていません"
no_pat_leak
log_lacks 'REGTOKEN123'
log_lacks 'docker.sock'
log_lacks '\-\-group-add'
log_lacks '\[DELETE\]'
# ジョブが正常に終わったときは、GitHub 側で外れているので、後始末(停止と一覧・削除の API)を呼ばない。
log_lacks '^docker \[stop\]'
log_lacks '\[GET\]'

rrun 0 "runner run: 親の環境で RUNNER_PAT が export されていても、PAT は curl / docker の環境に現れない" RUNNER_PAT=placeholder -- runner run r1
no_pat_leak
for f in "$STATE/run-env" "$STATE/curl-env"; do
  if grep -q '^RUNNER_PAT=' "$f"; then ng "$CUR: $f に RUNNER_PAT が環境変数として渡っています"; fi
done
[[ -s "$STATE/curl-env" && -s "$STATE/run-env" ]] || ng "$CUR: 環境の記録が空です(検査が働いていません)"

rrun 0 "runner run: 動いている前回のコンテナがあれば、殺さずに終わるまで待ってから起動する" FAKE_PREV=running -- runner run r1
log_has '^docker \[wait\] \[dev-runner-r1\]$'
log_has '^docker \[run\]'
log_lacks '^docker \[stop\]'
w="$(grep -n '^docker \[wait\]' "$LOG" | sed -n 1p | cut -d: -f1)"
r="$(grep -n '^docker \[rm\]' "$LOG" | sed -n 1p | cut -d: -f1)"
u="$(grep -n '^docker \[run\]' "$LOG" | sed -n 1p | cut -d: -f1)"
if [[ -z "$w" || -z "$r" || -z "$u" ]] || ! (( w < r && r < u )); then ng "$CUR: 待つ → 片づける → 起動、の順になっていません(wait=$w rm=$r run=$u)"; fi

rrun 143 "runner run: 前回のコンテナを待っているあいだに止められたら、前回のコンテナを止めて登録を外す" FAKE_PREV=running FAKE_WAIT_SIGNAL=TERM FAKE_REGISTERED_NAME=h-r1 -- runner run r1
log_has '^docker \[stop\] \[dev-runner-r1\]$'
log_has '\[DELETE\] .*runners/77\]$'
log_lacks '^docker \[run\]'

rrun 1 "runner run: 前回のコンテナの docker wait が失敗したら、rm も stop もせずに一時的な失敗(1)で抜ける" FAKE_PREV=running FAKE_WAIT_FAIL=1 -- runner run r1
log_lacks '^docker \[(rm|stop|run)\]'
log_lacks '\[DELETE\]'
expect_err "終了を待てませんでした"

rrun 0 "runner run: 止まっている前回のコンテナは待たずに消して起動する" FAKE_PREV=exited -- runner run r1
log_has '^docker \[rm\] \[-f\] \[dev-runner-r1\]$'
log_lacks '^docker \[wait\]'
log_has '^docker \[run\]'

rrun 0 "runner run: 前回のコンテナが無ければ、rm も wait も呼ばない" -- runner run r1
log_lacks '^docker \[(rm|wait)\]'

rrun 0 "runner run: docker=yes のときだけ、ソケットをグループ付きで渡す" -- runner run r2
log_has '^docker \[run\] \[--rm\] \[--name\] \[dev-runner-r2\] \[-e\] \[RUNNER_TOKEN\] \[--network\] \[dev-runner\] \[-v\] \[.*/docker.sock:/var/run/docker.sock\] \[--group-add\] \[[0-9]+\] \[dev-runner:local\]'
no_pat_leak

# ロックの置き場所(c)。
LK="$WORK/lk-open"
mkdir -p "$LK"
chmod 777 "$LK"
# ── 出口の制限（専用ネットワークと規則の印）──
rrun 0 "runner run: lan 指定なしのランナーは、専用ネットワークを指定して docker run される" -- runner run r1
log_has '^docker \[run\] .*\[--network\] \[dev-runner\] \[dev-runner:local\]'
rrun 0 "runner run: 専用ネットワークが無ければ作る。IPv6 は無効、ブリッジ名は固定" -- runner run r1
log_has '^docker \[network\] \[create\] \[--driver\] \[bridge\] \[--ipv6=false\] \[-o\] \[com.docker.network.bridge.name=dev-runner0\] \[dev-runner\]$'
log_has '^docker \[network\] \[inspect\] '
rrun 0 "runner run: 専用ネットワークが既にあれば（ブリッジ名と IPv6 が合うとき）作り直さず、そこで動かす" FAKE_NET_EXISTS=1 -- runner run r1
log_lacks '^docker \[network\] \[create\]'
log_has '^docker \[run\] .*\[--network\] \[dev-runner\]'
rrun 78 "runner run: 既存の専用ネットワークのブリッジ名が違えば拒む(78)" FAKE_NET_EXISTS=1 FAKE_NET_BRIDGE=br-abc -- runner run r1
log_lacks '^docker \[run\]'
rrun 78 "runner run: 既存の専用ネットワークで IPv6 が有効なら拒む(78)" FAKE_NET_EXISTS=1 FAKE_NET_IPV6=true -- runner run r1
log_lacks '^docker \[run\]'
rrun 1 "runner run: 専用ネットワークを作れなければ一時的な失敗(1)" FAKE_NET_CREATE_FAIL=1 -- runner run r1
log_lacks '^docker \[run\]'

rrun 1 "runner run: 印のファイルが無ければ、docker run せずに一時的な失敗(1)で抜ける（ユニットが起こし直す）" DEV_RUNNER_NET_MARKER="$WORK/netmark/none" -- runner run r1
expect_err "出口の規則の印がありません"
# 1 は dev-runner@.service の RestartPreventExitStatus に含まれない（含まれると二度と起き直らない）。
RPES="$(sed -n 's/^RestartPreventExitStatus=//p' "${DEV_RUNNER_UNIT:-$HERE/dev-runner@.service}")"
case " $RPES " in *" 1 "*) ng "印が無いときの終了コード 1 が RestartPreventExitStatus（$RPES）に含まれています" ;; esac
log_lacks '^docker \[run\]'
log_lacks '^docker \[network\]'
log_lacks 'registration-token'
printf 'bridge=br-other\n' >"$WORK/netmark/other"
rrun 78 "runner run: 印のブリッジ名が違えば、docker run せずに 78 で抜ける" DEV_RUNNER_NET_MARKER="$WORK/netmark/other" -- runner run r1
expect_err "ブリッジ名が"
log_lacks '^docker \[run\]'
printf 'bridge=dev-runner0-x\n' >"$WORK/netmark/prefix"
rrun 78 "runner run: 印のブリッジ名は完全一致で見る（前方一致では通さない）" DEV_RUNNER_NET_MARKER="$WORK/netmark/prefix" -- runner run r1
log_lacks '^docker \[run\]'

rrun 0 "runner run: lan=allow のランナーは、ネットワークを指定せず、印も確かめずに動く" DEV_RUNNER_NET_MARKER="$WORK/netmark/none" -- runner run r6
log_has '^docker \[run\] \[--rm\] \[--name\] \[dev-runner-r6\] \[-e\] \[RUNNER_TOKEN\] \[dev-runner:local\] \[bash\]'
log_lacks '\[--network\]'
log_lacks '^docker \[network\]'
rrun 0 "runner run: lan=allow かつ docker=yes は、ソケットだけを渡し、ネットワークは指定しない" -- runner run r7
log_lacks '\[--network\]'
log_has '\[-v\] \[.*/docker.sock:/var/run/docker.sock\]'

# ── ランナーグループ（group=）──
# config.sh（偽物）が実際に受け取った引数を、1 行 1 引数の記録から 1 行へ並べて見る。
cfg_args() { tr '\n' ' ' <"$STATE/config-args"; }
cfg_want() {
  local got
  got="$(cfg_args)"
  [[ "$got" == "$1" ]] || ng "$CUR: config.sh の引数が違います: 期待「$1」 実際「$got」"
  if grep -qF -- "REGTOKEN" "$STATE/config-args"; then ng "$CUR: 引数の記録にトークンの値が残っています"; fi
}
BASEARGS='--unattended --ephemeral --disableupdate --replace --url https://github.com/my-org --token <伏せ字>'
rrun 0 "runner run: group=<名前> の行は、config.sh へ --runnergroup <名前> を渡す（ラベルがあるとき）" FAKE_CONFIG_MSG=ok FAKE_CONFIG_RC=0 -- runner run g2
cfg_want "$BASEARGS --name h-g2 --labels devhost,x --runnergroup my-group "
# shellcheck disable=SC2016 # 展開前の ${4:+...} をリテラルとして照合する
log_has '\$\{4:\+--runnergroup "\$4"\}'
log_has '\[runner\] \[https://github.com/my-org\] \[h-g2\] \[devhost,x\] \[my-group\]$'
rrun 0 "runner run: group=<名前> の行は、ラベルが無くても 4 つ目の引数に名前が入る（3 つ目は空）" FAKE_CONFIG_MSG=ok FAKE_CONFIG_RC=0 -- runner run g1
cfg_want "$BASEARGS --name h-g1 --runnergroup my-group "
log_has '\[runner\] \[https://github.com/my-org\] \[h-g1\] \[\] \[my-group\]$'
expect_out_line 'group=my-group'
no_pat_leak
rrun 0 "runner run: group を書かない行の config.sh の引数は変わらない（--runnergroup の名前を渡さない）" FAKE_CONFIG_MSG=ok FAKE_CONFIG_RC=0 -- runner run r1
cfg_want "$BASEARGS --name h-r1 --labels devhost,x "
if grep -qF -- "--runnergroup" "$STATE/config-args"; then ng "$CUR: group なしの行に --runnergroup が渡っています"; fi
log_has '\[runner\] \[https://github.com/my-org\] \[h-r1\] \[devhost,x\]$'
log_lacks '\[my-group\]'
rrun 0 "runner run: group を書かず、ラベルも無い行は 3 つの引数のまま" FAKE_CONFIG_MSG=ok FAKE_CONFIG_RC=0 -- runner run r2
cfg_want "$BASEARGS --name h-r2 "
log_has '\[runner\] \[https://github.com/my-org\] \[h-r2\] \[\]$'
# コンテナを起こす前に、組織のランナーグループの一覧で有無を確かめる。
rrun 0 "runner run: group があれば、コンテナを起こす前にグループの一覧を引く" -- runner run g1
log_has '^curl .*\[GET\] .*\[https://api.github.com/orgs/my-org/actions/runner-groups\?per_page=100&page=1\]$'
a="$(grep -n 'runner-groups' "$LOG" | sed -n 1p | cut -d: -f1)"
b="$(grep -n '^docker \[run\]' "$LOG" | sed -n 1p | cut -d: -f1)"
if [[ -z "$a" || -z "$b" ]] || ! (( a < b )); then ng "$CUR: グループの一覧が docker run より前ではありません"; fi
rrun 78 "runner run: グループが組織に無ければ 78（既定のグループで登録し直さない。docker run もトークンの取得もしない）" FAKE_GROUPS=Default,other -- runner run g1
expect_err "ランナーグループ my-group が組織 my-org にありません"
expect_err "既定のグループへは入りません"
log_lacks '^docker \[run\]'
log_lacks 'registration-token'
log_lacks '^docker \[stop\]'
log_lacks '\[DELETE\]'
no_pat_leak
for code in 401 403 404; do
  rrun 78 "runner run: グループの一覧が HTTP $code なら、直らない失敗(78)" FAKE_API_FAIL=groups FAKE_API_CODE=$code -- runner run g1
  expect_err "ランナーグループの一覧を取得できませんでした"
  log_lacks '^docker \[run\]'
  no_pat_leak
done
for code in 429 500 503; do
  rrun 1 "runner run: グループの一覧が HTTP $code なら、一時的な失敗(1。ユニットが起こし直す)" FAKE_API_FAIL=groups FAKE_API_CODE=$code -- runner run g1
  expect_err "ランナーグループの一覧を取得できませんでした"
  log_lacks '^docker \[run\]'
  no_pat_leak
done
rrun 1 "runner run: 通信の失敗でグループの一覧を引けなければ 1" FAKE_API_NETFAIL=1 -- runner run g1
log_lacks '^docker \[run\]'
rrun 1 "runner run: グループはあるが config.sh（コンテナ）が失敗したら 1（78 にしない。起こし直す）" FAKE_RUN_EXIT=1 FAKE_REGISTERED_NAME=h-g1 -- runner run g1
expect_err "終了コード 1"
log_has '^docker \[stop\] \[dev-runner-g1\]$'
rrun 1 "runner run: group を書かない行は、コンテナの終了コードが 78 でも 1（78 にしない）" FAKE_RUN_EXIT=78 -- runner run r1
expect_err "終了コード 78"
# 事前確認は通ったが、登録の時点で config.sh がグループ不在で失敗する。偽の config.sh を実際に走らせる。
GMSG='Could not find any self-hosted runner group named my-group.'
rrun 78 "runner run: 確認は通ったが config.sh がグループ不在のメッセージで失敗したら 78" FAKE_CONFIG_MSG="$GMSG" FAKE_REGISTERED_NAME=h-g1 -- runner run g1
expect_err "登録の時点で見つかりませんでした"
log_has '^curl .*runner-groups'
no_pat_leak
rrun 1 "runner run: config.sh がそれ以外のメッセージで失敗したら 1" FAKE_CONFIG_MSG="Http response code: 503" -- runner run g1
expect_err "終了コード 1"
rrun 1 "runner run: group なしで同じメッセージが出ても 78 にしない（1）" FAKE_CONFIG_MSG="$GMSG" -- runner run r1
expect_err "終了コード 1"
rrun 0 "runner run: config.sh が成功すれば run.sh へ進んで 0" FAKE_CONFIG_MSG="ok" FAKE_CONFIG_RC=0 -- runner run g1
rrun 0 "runner run: group を書かない行は、グループの一覧を引かない" -- runner run r1
log_lacks 'runner-groups'
T="$WORK/conf/runners-group"
# shellcheck disable=SC2016 # 'a\$b' は「\$ を含む値」そのものを渡す試験で、展開させない
for bad in 'a/b' 'a;b' '../x' 'a\$b'; do
  printf 'z my-org group=%s\n' "$bad" >"$T"
  run 2 "runners: group に許可外の文字（$bad）があれば設定の誤り" -- DEV_RUNNERS_FILE="$T" -- runner run z
  expect_err "group に使えるのは英数字と . _ - だけです"
  expect_no_calls
done
printf 'z my-org group=a b\n' >"$T"
run 2 "runners: group に空白があれば設定の誤り（キー=値の形でない）" -- DEV_RUNNERS_FILE="$T" -- runner run z
expect_no_calls
printf 'z my-org group=\n' >"$T"
run 2 "runners: group の値が空なら設定の誤り" -- DEV_RUNNERS_FILE="$T" -- runner run z
expect_no_calls

rrun 78 "runner run: ロックの置き場所に group / other の書き込み権限があれば拒む(78)" DEV_RUNNER_LOCK_DIR="$LK" -- runner run r1
expect_err "書き込み権限があります"
log_lacks '^docker \[run\]'
LK="$WORK/lk-link"
mkdir -p "$LK"
chmod 700 "$LK"
printf 'victim\n' >"$WORK/victim"
ln -s "$WORK/victim" "$LK/dev-runner-r1.lock"
rrun 78 "runner run: ロックのファイルがリンクなら辿らずに拒む(78。リンク先を切り詰めない)" DEV_RUNNER_LOCK_DIR="$LK" -- runner run r1
expect_err "リンクです"
[[ "$(cat "$WORK/victim")" == "victim" ]] || ng "$CUR: リンク先が書き換わっています"
log_lacks '^docker \[run\]'
rrun 0 "runner run: 既定の置き場所(XDG_RUNTIME_DIR が無ければ XDG_CACHE_HOME の下)を、権限 700 で作る" DEV_RUNNER_LOCK_DIR= XDG_CACHE_HOME="$WORK/xdgcache" -- runner run r1
if [[ "$(stat -c %a "$WORK/xdgcache/dev" 2>/dev/null)" != "700" ]]; then ng "$CUR: ロックのディレクトリが権限 700 で作られていません"; fi  # bsd-ok: 試験は Linux で回す
[[ -f "$WORK/xdgcache/dev/dev-runner-r1.lock" ]] || ng "$CUR: ロックのファイルが既定の置き場所にありません"
rrun 78 "runner run: PAT ファイルの group / other に権限があれば、読まずに拒む（直らない失敗の 78）" -- runner run r3
expect_err "権限が緩すぎます（644"
log_lacks '^curl '
log_lacks '^docker \[run\]'
no_pat_leak

rrun 0 "runner run: 権限 400 の PAT ファイルは通す（group / other のビットが無ければよい）" -- runner run r4
log_has '^docker \[run\]'
no_pat_leak

rrun 78 "runner run: イメージが無ければ拒む（直らない失敗の 78）" FAKE_IMAGE_MISSING=1 -- runner run r1
expect_err "ランナーのイメージがありません"
log_lacks '^curl '
log_lacks '^docker \[run\]'

rrun 1 "runner run: Docker のデーモンに届かないときは、一時的な失敗（1。ユニットが起こし直す）" FAKE_IMAGE_MISSING=daemon -- runner run r1
expect_err "docker に問い合わせられません"
log_lacks '^docker \[run\]'

rm -f "$WORK/docker.sock"
rrun 78 "runner run: docker=yes なのにソケットが無ければ拒む（78）" -- runner run r5
expect_err "Docker のソケットがありません"
log_lacks '^docker \[run\]'
: >"$WORK/docker.sock"

for code in 401 403 404; do
  rrun 78 "runner run: 登録用のトークンが HTTP $code なら、直らない失敗(78。ユニットは起こし直さない)" FAKE_API_FAIL=token FAKE_API_CODE=$code -- runner run r1
  expect_err "Self-hosted runners: Read and write"
  expect_err "HTTP $code"
  log_lacks '^docker \[run\]'
  no_pat_leak
done
for code in 429 500 503; do
  rrun 1 "runner run: 登録用のトークンが HTTP $code なら、一時的な失敗(1。ユニットが起こし直す)" FAKE_API_FAIL=token FAKE_API_CODE=$code -- runner run r1
  expect_err "登録用のトークンを取得できませんでした"
  log_lacks '^docker \[run\]'
  no_pat_leak
done
rrun 1 "runner run: 通信の失敗は一時的な失敗(1)" FAKE_API_NETFAIL=1 -- runner run r1
log_lacks '^docker \[run\]'
rrun 78 "runner run: PAT が違えば(API が 401)、直らない失敗(78)" FAKE_PAT_EXPECT=github_pat_OTHER -- runner run r1
log_lacks '^docker \[run\]'
no_pat_leak

rrun 1 "runner run: コンテナが失敗して止まれば 1（ユニットが起こし直す）。正常でないので後始末をする" FAKE_RUN_EXIT=3 FAKE_REGISTERED_NAME=h-r1 -- runner run r1
expect_err "終了コード 3"
log_has '^docker \[stop\] \[dev-runner-r1\]$'
log_has '\[DELETE\]'

# 同じ名前がすでに動いている(ロックを別のファイル記述子で持つ)ときは、何も消さずに 75 で拒む。
exec 8>"$WORK/lock/dev-runner-r1.lock"
flock -n 8 || ng "試験の準備: ロックを取れません"
rrun 75 "runner run: 同じ名前がすでに動いていれば、何も消さずに拒む" -- runner run r1
expect_err "すでに動いています"
log_lacks '^docker \[(rm|stop|run)\]'
log_lacks '^curl '
exec 8>&-
rrun 0 "runner run: 別の名前のロックは邪魔しない" -- runner run r2
log_has '^docker \[run\]'

rrun 143 "runner run: 止められたら、コンテナを止めて組織から登録を外す（自分の名前のランナーだけ）" FAKE_RUN_SIGNAL=TERM FAKE_REGISTERED_NAME=h-r1 -- runner run r1
log_has '^docker \[stop\] \[dev-runner-r1\]$'
log_has '^curl \[-sSL\] \[-K\] \[-\] \[-X\] \[GET\] .*actions/runners\?per_page=100&page=1\]$'
log_has '^curl \[-sSL\] \[-K\] \[-\] \[-X\] \[DELETE\] .*\[https://api.github.com/orgs/my-org/actions/runners/77\]$'
log_lacks 'runners/11\]'
expect_out_line '組織から登録を外しました: h-r1'
no_pat_leak

rrun 143 "runner run: 一覧が複数ページでも、2 ページ目の自分のランナーを外す" FAKE_RUN_SIGNAL=TERM FAKE_REGISTERED_NAME=h-r1 FAKE_PAGES=2 -- runner run r1
log_has 'per_page=100&page=1\]$'
log_has 'per_page=100&page=2\]$'
log_has '\[DELETE\] .*runners/77\]$'

rrun 143 "runner run: 止められたとき、登録が無ければ削除は呼ばない" FAKE_RUN_SIGNAL=TERM -- runner run r1
log_lacks '\[DELETE\]'

rrun 2 "runner run: 未登録の名前" -- runner run nope
expect_err "登録されていないランナーです: nope"
expect_no_calls
rrun 2 "runner: 引数なし" -- runner
expect_err "使い方: dev runner"
expect_no_calls
rrun 2 "runner: 知らないサブコマンド" -- runner bogus
expect_no_calls
rrun 2 "runner run: 名前が無い" -- runner run
expect_no_calls
T="$WORK/conf/runners.bad"
printf 'z my-org lan=maybe\n' >"$T"
run 2 "runners: lan は allow か deny" -- DEV_RUNNERS_FILE="$T" -- runner run x
expect_err "lan は allow か deny です"
printf 'x my-org bogus=1\n' >"$T"
run 2 "runners: 知らないキーは設定の誤り" -- DEV_RUNNERS_FILE="$T" -- runner run x
expect_err "知らないキーです"
printf 'x my-org docker=maybe\n' >"$T"
run 2 "runners: docker は yes か no" -- DEV_RUNNERS_FILE="$T" -- runner run x
expect_err "docker は yes か no です"
printf 'x my-org\nx my-org\n' >"$T"
run 2 "runners: 名前の重複" -- DEV_RUNNERS_FILE="$T" -- runner run x
expect_err "名前が重複しています"
run 2 "runners: 設定ファイルが無い" -- DEV_RUNNERS_FILE="$WORK/conf/none" -- runner run x
expect_err "設定ファイルがありません"
expect_no_calls

cp "$HERE/runner.Dockerfile" "$WORK/conf/runner.Dockerfile"
rrun 0 "runner build: 版を決めなければ Dockerfile の ARG の既定値を --build-arg とラベルの両方へ渡す。Dockerfile を標準入力で渡す（ビルドの文脈を作らない）" DEV_RUNNER_DOCKERFILE="$WORK/conf/runner.Dockerfile" -- runner build
expect_calls 'docker [build] [--build-arg] [RUNNER_VERSION=2.338.0] [--label] [devhost.runner-version=2.338.0] [-t] [dev-runner:local] [-]'
cmp -s "$WORK/conf/runner.Dockerfile" "$STATE/build-stdin" || ng "$CUR: Dockerfile が標準入力で渡っていません"
rrun 0 "runner build: 環境変数の版を --build-arg で渡す（Dockerfile は編集しない）" DEV_RUNNER_DOCKERFILE="$WORK/conf/runner.Dockerfile" DEV_RUNNER_VERSION=2.999.0 -- runner build
expect_calls 'docker [build] [--build-arg] [RUNNER_VERSION=2.999.0] [--label] [devhost.runner-version=2.999.0] [-t] [dev-runner:local] [-]'
printf 'runner_version=2.888.1\nz my-org\n' >"$T"
run 0 "runner build: 設定ファイルの runner_version を --build-arg で渡す" -- DEV_RUNNERS_FILE="$T" DEV_RUNNER_DOCKERFILE="$WORK/conf/runner.Dockerfile" -- runner build
expect_calls 'docker [build] [--build-arg] [RUNNER_VERSION=2.888.1] [--label] [devhost.runner-version=2.888.1] [-t] [dev-runner:local] [-]'
printf 'runner_version=latest\nz my-org\n' >"$T"
run 2 "runner build: runner_version が X.Y.Z でなければ拒む" -- DEV_RUNNERS_FILE="$T" DEV_RUNNER_DOCKERFILE="$WORK/conf/runner.Dockerfile" -- runner build
expect_no_calls
rrun 1 "runner build: Dockerfile が無ければ拒む" DEV_RUNNER_DOCKERFILE="$WORK/conf/none.Dockerfile" -- runner build
expect_no_calls

rrun 0 "doctor --runner: 問題なし" FAKE_ACTIVE_UNITS=dev-runner@r1.service -- doctor --runner r1
expect_out_line '\[OK  \] イメージ dev-runner:local があります'
expect_out_line '\[OK  \] PAT ファイル .*（権限 600）'
expect_out_line '\[OK  \] ユニット dev-runner@r1.service: active'
expect_out_line '判定: OK'
rrun 1 "doctor --runner: PAT の権限が緩ければ FAIL" -- doctor --runner r3
expect_out_line '\[FAIL\] PAT ファイルの権限が緩すぎます（644'
rrun 3 "doctor --runner: 権限 400 の PAT は FAIL にしない（ユニットが止まっている WARN だけ）" -- doctor --runner r4
expect_out_line '\[OK  \] PAT ファイル .*（権限 400）'
no_pat_leak
rrun 1 "doctor --runner: イメージが無ければ FAIL" FAKE_IMAGE_MISSING=1 -- doctor --runner r1
expect_out_line '\[FAIL\] イメージ dev-runner:local がありません'
rrun 3 "doctor --runner: ユニットが止まっていれば WARN。docker=yes は INFO で知らせる" -- doctor --runner r2
expect_out_line '\[INFO\] docker=yes: ジョブがホストの Docker を自由に操作できます'
expect_out_line '\[WARN\] ユニット dev-runner@r2.service: inactive'
# group を書いたランナー: 組織のランナーグループの一覧を引く。
rrun 0 "doctor --runner: group がグループの一覧にあれば OK" FAKE_ACTIVE_UNITS=dev-runner@g1.service -- doctor --runner g1
expect_out_line '\[OK  \] ランナーグループ my-group が組織 my-org にあります'
log_has '^curl \[-sSL\] \[-K\] \[-\] \[-X\] \[GET\] .*\[https://api.github.com/orgs/my-org/actions/runner-groups\?per_page=100&page=1\]$'
no_pat_leak
rrun 1 "doctor --runner: group が一覧に無ければ FAIL" FAKE_GROUPS=Default,other FAKE_ACTIVE_UNITS=dev-runner@g1.service -- doctor --runner g1
expect_out_line '\[FAIL\] ランナーグループ my-group が組織 my-org にありません'
no_pat_leak
rrun 1 "doctor --runner: グループ名は完全一致で見る（部分一致では OK にしない）" FAKE_GROUPS=Default,my-group-2 FAKE_ACTIVE_UNITS=dev-runner@g1.service -- doctor --runner g1
expect_out_line '\[FAIL\] ランナーグループ my-group が組織 my-org にありません'
for code in 401 403 404; do
  rrun 3 "doctor --runner: グループの一覧が HTTP $code で読めなければ WARN（理由を出す）" FAKE_API_FAIL=groups FAKE_API_CODE=$code FAKE_ACTIVE_UNITS=dev-runner@g1.service -- doctor --runner g1
  expect_out_line '\[WARN\] ランナーグループ my-group: グループの一覧を読めませんでした（HTTP 401 / 403 / 404'
  no_pat_leak
done
rrun 3 "doctor --runner: グループの一覧が HTTP 500 で読めなければ WARN" FAKE_API_FAIL=groups FAKE_API_CODE=500 FAKE_ACTIVE_UNITS=dev-runner@g1.service -- doctor --runner g1
expect_out_line '\[WARN\] ランナーグループ my-group: グループの一覧を読めませんでした（API の不調'
no_pat_leak
rrun 3 "doctor --runner: 通信の失敗でグループの一覧を読めなければ WARN" FAKE_API_NETFAIL=1 FAKE_ACTIVE_UNITS=dev-runner@g1.service -- doctor --runner g1
expect_out_line '\[WARN\] ランナーグループ my-group'
no_pat_leak
rrun 0 "doctor --runner: group を書かないランナーは、グループの一覧を引かない" FAKE_ACTIVE_UNITS=dev-runner@r1.service -- doctor --runner r1
log_lacks 'runner-groups'
# ランナーの版の期限（自動更新を止めたランナーは、新しい版の公開から 30 日で止まる）。「今日」は DEV_TODAY で固定する。
REL_NEW='[{"tag_name":"v2.339.0","published_at":"2026-10-20T10:00:00Z","prerelease":false,"draft":false},{"tag_name":"v2.338.0","published_at":"2026-10-06T10:00:00Z","prerelease":false,"draft":false}]'
rrun 0 "doctor --runner: ランナーの版に新しい版が無ければ OK" DEV_TODAY=2026-11-30 FAKE_ACTIVE_UNITS=dev-runner@r1.service -- doctor --runner r1
expect_out_line '\[OK  \] ランナーの版 2.338.0 は、公開済みの最新です'
log_has '^curl \[-sSL\] \[-m\] \[20\] .*\[https://api.github.com/repos/actions/runner/releases\?per_page=100\]$'
log_lacks 'Bearer'
rrun 3 "doctor --runner: 新しい版が出て期限内なら WARN（期限の日付と残り日数）" DEV_TODAY=2026-11-01 FAKE_RELEASES="$REL_NEW" FAKE_ACTIVE_UNITS=dev-runner@r1.service -- doctor --runner r1
expect_out_line '\[WARN\] ランナーの版 2.338.0: 新しい版 v2.339.0 が 2026-10-20 に公開されています。期限は 2026-11-19 10:00 UTC（残り 18 日）'
expect_out_line 'runner_version= を新しい版へ変え、dev runner build'
rrun 3 "doctor --runner: 「今日」が日付として読めなければ、期限を計算できない WARN（関数ごと抜けない）" DEV_TODAY=not-a-date FAKE_RELEASES="$REL_NEW" FAKE_ACTIVE_UNITS=dev-runner@r1.service -- doctor --runner r1
expect_out_line '\[WARN\] ランナーの版 2.338.0: 新しい版 v2.339.0 がありますが、期限の日付を計算できませんでした'
expect_out_line 'ユニット dev-runner@r1.service: active'
rrun 3 "doctor --runner: 期限の当日でも、公開の時刻の前なら WARN（残り 0 日）" DEV_TODAY=2026-11-19 FAKE_RELEASES="$REL_NEW" FAKE_ACTIVE_UNITS=dev-runner@r1.service -- doctor --runner r1
expect_out_line '\[WARN\] ランナーの版 2.338.0: .*期限は 2026-11-19 10:00 UTC（残り 0 日）'
rrun 1 "doctor --runner: 期限の当日でも、公開の時刻を過ぎれば FAIL" DEV_TODAY='2026-11-19 12:00' FAKE_RELEASES="$REL_NEW" FAKE_ACTIVE_UNITS=dev-runner@r1.service -- doctor --runner r1
expect_out_line '\[FAIL\] ランナーの版 2.338.0: .*（期限 2026-11-19 10:00 UTC。0 日超過）'
rrun 1 "doctor --runner: 期限を過ぎていれば FAIL" DEV_TODAY=2026-11-21 FAKE_RELEASES="$REL_NEW" FAKE_ACTIVE_UNITS=dev-runner@r1.service -- doctor --runner r1
expect_out_line '\[FAIL\] ランナーの版 2.338.0: 新しい版 v2.339.0 の公開（2026-10-20）から 30 日を過ぎました（期限 2026-11-19 10:00 UTC。1 日超過）'
rrun 3 "doctor --runner: 版の一覧を HTTP エラーで読めなければ WARN" FAKE_RELEASES_FAIL=500 FAKE_ACTIVE_UNITS=dev-runner@r1.service -- doctor --runner r1
expect_out_line '\[WARN\] ランナーの版 2.338.0: 公開済みの版の一覧を読めませんでした'
rrun 3 "doctor --runner: 通信の失敗で版の一覧を読めなければ WARN" FAKE_API_NETFAIL=1 FAKE_ACTIVE_UNITS=dev-runner@r1.service -- doctor --runner r1
expect_out_line '\[WARN\] ランナーの版 2.338.0: 公開済みの版の一覧を読めませんでした'
rrun 3 "doctor --runner: ラベルの無いイメージは WARN（作り直しを案内）" FAKE_IMAGE_LABEL= FAKE_ACTIVE_UNITS=dev-runner@r1.service -- doctor --runner r1
expect_out_line '\[WARN\] ランナーの版: イメージ dev-runner:local に版のラベル.*dev runner build で作り直す'
log_lacks 'actions/runner/releases'
rrun 0 "doctor --runner: プレリリースと下書きだけが新しいなら OK" DEV_TODAY=2026-12-31 FAKE_RELEASES='[{"tag_name":"v2.340.0","published_at":"2026-10-01T00:00:00Z","prerelease":true,"draft":false},{"tag_name":"v2.341.0","published_at":"2026-10-01T00:00:00Z","prerelease":false,"draft":true},{"tag_name":"v2.338.0","published_at":"2026-10-06T10:00:00Z","prerelease":false,"draft":false}]' FAKE_ACTIVE_UNITS=dev-runner@r1.service -- doctor --runner r1
expect_out_line '\[OK  \] ランナーの版 2.338.0 は、公開済みの最新です'
rrun 3 "doctor --runner: 新しい版が複数あれば、最も早い公開日から数える" DEV_TODAY=2026-11-01 FAKE_RELEASES='[{"tag_name":"v2.340.0","published_at":"2026-10-30T00:00:00Z","prerelease":false,"draft":false},{"tag_name":"v2.339.0","published_at":"2026-10-20T10:00:00Z","prerelease":false,"draft":false}]' FAKE_ACTIVE_UNITS=dev-runner@r1.service -- doctor --runner r1
expect_out_line '新しい版 v2.339.0 が 2026-10-20 に公開されています。期限は 2026-11-19 10:00 UTC（残り 18 日）'
no_pat_leak

rrun 2 "doctor --runner: 名前が無い" -- doctor --runner
expect_no_calls
rrun 2 "doctor --runner: 未登録の名前" -- doctor --runner nope
expect_err "登録されていないランナーです: nope"

# group= の説明が、runners.example・README・dev help の 3 か所にあること。
CUR="group= の説明の照合"
n=$((n + 1))
GROUP_EXAMPLE="${DEV_RUNNERS_EXAMPLE:-$HERE/runners.example}"
if ! grep -qE '^#   group=<名前>' "$GROUP_EXAMPLE"; then ng "runners.example に group=<名前> の説明がありません"; fi
if ! grep -qE '^# [a-z0-9]+ +my-org +.*group=my-group' "$GROUP_EXAMPLE"; then ng "runners.example に group= を使った例の行がありません"; fi
if ! grep -qF -- 'ラベルは安全の境界になりません' "$README"; then ng "README に「ラベルは安全の境界になりません」がありません"; fi
# shellcheck disable=SC2016 # バッククォートは README の記法そのままのリテラル
if ! grep -qF -- '`group=<名前>`' "$README"; then ng "README に group=<名前> の説明がありません"; fi
run 0 "help runner: group= の説明がある" -- -- help runner
expect_out_line 'group=名前 は登録先のランナーグループ'
expect_out_line '\[group=名前\]'

# ── 7. 使い方 ─────────────────────────────────────────────────────────────────
run 2 "引数なし" -- --
expect_no_calls
run 2 "知らないサブコマンド" -- -- start alpha
expect_no_calls
run 2 "auth は受け付けない（特定クラウドへの認証は持たない）" -- -- auth aws alpha
expect_no_calls

# ── 8. ユニット（dev-up@.service）の要の行 ───────────────────────────────────
# systemd はこの環境に無いので読み込みは試せない。崩すと「戻らない」につながる行だけを綴りで見る。
UNIT="${DEV_UNIT:-$HERE/dev-up@.service}"
CUR="ユニット"
unit_has() { grep -qxF -- "$1" "$UNIT" || ng "ユニットに「$1」の行がありません（$2）"; }
unit_has 'ExecStart=%h/.local/bin/dev supervise %i' "起こして止まるまで待つ口。%I は - を / へ戻すので使わない"
unit_has 'Restart=always' "止まった理由を問わず起こし直す"
unit_has 'StartLimitIntervalSec=0' "起動の直後に Docker が遅れても諦めない"
unit_has 'WantedBy=default.target' "ユーザーのマネージャの起動（linger で起動時）に付く"
if grep -qE '^[^#]*%I' "$UNIT"; then ng "ユニットが %I を使っています（名前の - が / に化ける）"; fi

# ── 6g. runner の出口の規則（root のスクリプトとユニット）──────────────────────
# 実機の iptables は呼ばない。スクリプトの rules が出す規則の文面を突き合わせ、apply は偽の iptables で回す。
NETSH="$WORK/dev-runner-net.sh"
rrun 0 "runner net script: 規則を入れるスクリプトを出す（dev は何も呼ばない）" -- runner net script
expect_no_calls
cp "$OUT" "$NETSH"
"$BASH_BIN" -n "$NETSH" || ng "出力したスクリプトに構文の誤りがあります"
[[ "$(sed -n 1p "$NETSH")" == '#!/usr/bin/env bash' ]] || ng "出力したスクリプトの 1 行目が bash の shebang ではありません"
net_run() { # net_run <期待する終了コード> <説明> [VAR=値 ...] -- 引数
  local want="$1" what="$2" ev=() code=0
  shift 2
  while [[ $# -gt 0 && "$1" != "--" ]]; do ev+=("$1"); shift; done
  [[ $# -gt 0 ]] && shift
  : >"$LOG"
  n=$((n + 1))
  CUR="$what"
  env -i HOME="$WORK/home" PATH="$FAKEBIN:$TOOLBIN" FAKE_LOG="$LOG" FAKE_STATE="$STATE" \
    DEV_RUNNER_NET_STATE_DIR="$WORK/netstate" ${ev[@]+"${ev[@]}"} \
    "$BASH_BIN" "$NETSH" "$@" >"$OUT" 2>"$ERR" </dev/null || code=$?
  [[ "$code" == "$want" ]] || { ng "$what: 終了コード want $want got $code"; sed 's/^/    stderr: /' "$ERR" >&2; }
}
rules_has() { grep -qxF -- "$1" "$OUT" || { ng "$CUR: 規則に「$1」の行がありません"; sed 's/^/    rules: /' "$OUT" >&2; }; }
net_run 0 "net rules: FORWARD は、止める 5 つの帯への新しい接続を REJECT する" -- rules
for cidr in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do
  rules_has "-A DEV-RUNNER-FWD -d $cidr -m conntrack --ctstate NEW -j REJECT"
done
rules_has "-A DEV-RUNNER-IN -m conntrack --ctstate NEW -j REJECT"
rules_has "-I DOCKER-USER -i dev-runner0 -j DEV-RUNNER-FWD"
rules_has "-I INPUT -i dev-runner0 -j DEV-RUNNER-IN"
rules_has "*filter"
rules_has ":DEV-RUNNER-FWD - [0:0]"
rules_has ":DEV-RUNNER-IN - [0:0]"
rules_has "COMMIT"
if grep -qE -- '-j ACCEPT' "$OUT"; then ng "$CUR: 既定の規則に ACCEPT があります（許可は DEV_RUNNER_NET_ALLOW_DNS の指定時だけ）"; fi
if grep -qE -- '-d (0\.0\.0\.0/0|0/0)' "$OUT"; then ng "$CUR: 全宛先を止める規則があります（インターネットへ出られなくなる）"; fi
net_run 0 "net rules: DEV_RUNNER_NET_ALLOW_DNS の宛先の 53 番だけを、止める規則より前で通す" DEV_RUNNER_NET_ALLOW_DNS="192.168.1.1 10.0.0.2" -- rules
rules_has "-A DEV-RUNNER-FWD -d 192.168.1.1 -p udp --dport 53 -j ACCEPT"
rules_has "-A DEV-RUNNER-FWD -d 10.0.0.2 -p tcp --dport 53 -j ACCEPT"
rules_has "-A DEV-RUNNER-IN -d 192.168.1.1 -p udp --dport 53 -j ACCEPT"
a_line="$(grep -nF -- '-A DEV-RUNNER-FWD -d 192.168.1.1 -p udp --dport 53 -j ACCEPT' "$OUT" | cut -d: -f1)"
r_line="$(grep -nF -- '-A DEV-RUNNER-FWD -d 192.168.0.0/16' "$OUT" | cut -d: -f1)"
[[ -n "$a_line" && -n "$r_line" && "$a_line" -lt "$r_line" ]] || ng "$CUR: 許可が止める規則より後ろにあります"
net_run 1 "net rules: DEV_RUNNER_NET_ALLOW_DNS が IPv4 でなければ拒む" DEV_RUNNER_NET_ALLOW_DNS="1.2.3.4;reboot" -- rules
net_run 1 "net apply: DEV_RUNNER_NET_ALLOW_DNS が不正なら、規則を 1 つも入れず印も置かない" DEV_RUNNER_NET_ALLOW_DNS="bogus" -- apply
log_lacks '^iptables-restore'
log_lacks '^iptables \[-N\]'
[[ ! -e "$WORK/netstate/ready" ]] || ng "$CUR: 不正な指定なのに印が置かれています"

rm -rf "$WORK/netstate"
net_run 1 "net apply: FORWARD に DOCKER-USER への飛び先が無ければ、何も入れず印も置かずに失敗する" FAKE_IPT_FWD=1 -- apply
expect_err "FORWARD から DOCKER-USER への飛び先がありません"
log_lacks '^iptables-restore'
log_lacks '^iptables \[-N\]'
[[ ! -e "$WORK/netstate/ready" ]] || ng "$CUR: 飛び先が無いのに印が置かれています"
net_run 0 "net apply: 規則を入れ、印を置く（入れ替えは 1 回の iptables-restore）" -- apply
log_has '^iptables-restore \[--noflush\]$'
[[ "$(grep -c '^iptables-restore' "$LOG")" == "1" ]] || ng "$CUR: iptables-restore が 1 回ではありません"
# -F と -A と -I を iptables として別々に呼ばない（制限の無い瞬間を作らない）。規則は取り込みの内容にだけある。
log_lacks '^iptables \[-(F|A|I|X|D)\]'
log_lacks '^iptables \[-N\]'
log_has '^iptables \[-C\] \[FORWARD\] \[-j\] \[DOCKER-USER\]$'
grep -qxF -- '-A DEV-RUNNER-FWD -d 10.0.0.0/8 -m conntrack --ctstate NEW -j REJECT' "$STATE/restore-in" || ng "$CUR: 取り込みの内容に 10/8 の規則がありません"
grep -qxF -- '-A DEV-RUNNER-IN -m conntrack --ctstate NEW -j REJECT' "$STATE/restore-in" || ng "$CUR: 取り込みの内容に INPUT の規則がありません"
grep -qxF -- '-I DOCKER-USER -i dev-runner0 -j DEV-RUNNER-FWD' "$STATE/restore-in" || ng "$CUR: 取り込みの内容に DOCKER-USER の飛び先がありません"
grep -qxF -- '-I INPUT -i dev-runner0 -j DEV-RUNNER-IN' "$STATE/restore-in" || ng "$CUR: 取り込みの内容に INPUT の飛び先がありません"
grep -qxF -- ':DEV-RUNNER-FWD - [0:0]' "$STATE/restore-in" || ng "$CUR: 取り込みの内容に鎖の宣言がありません"
[[ "$(sed -n '$p' "$STATE/restore-in")" == "COMMIT" ]] || ng "$CUR: 取り込みの内容が COMMIT で終わっていません"
[[ "$(cat "$WORK/netstate/ready")" == "bridge=dev-runner0" ]] || ng "$CUR: 印の中身が bridge=dev-runner0 ではありません"
# 印は、dev が読む形と一致する（スクリプトの印で dev runner run が通る）。
cp "$WORK/netstate/ready" "$WORK/netmark/fromscript"
rrun 0 "runner run: スクリプトが置いた印で通る（ブリッジ名の綴りが dev と一致する）" DEV_RUNNER_NET_MARKER="$WORK/netmark/fromscript" -- runner run r1
net_run 0 "net apply: 飛び先が既にあれば（-C が 0）、取り込みに飛び先を含めない" FAKE_IPT_CHECK=0 -- apply
log_has '^iptables \[-C\] \[DOCKER-USER\] \[-i\] \[dev-runner0\] \[-j\] \[DEV-RUNNER-FWD\]$'
if grep -q '^-I ' "$STATE/restore-in"; then ng "$CUR: 飛び先が既にあるのに -I を含めています"; fi
grep -qxF -- '-A DEV-RUNNER-IN -m conntrack --ctstate NEW -j REJECT' "$STATE/restore-in" || ng "$CUR: 鎖の中身の入れ替えが取り込みにありません"
net_run 1 "net apply: 取り込みに失敗したら、前の印も消えていて、新しい印も置かない" FAKE_IPTR_FAIL=1 -- apply
[[ ! -e "$WORK/netstate/ready" ]] || ng "$CUR: 失敗したのに印が残っています"
net_run 0 "net clear: 印を消し、飛び先と鎖を 1 回の iptables-restore で外す" FAKE_IPT_CHECK=0 FAKE_IPT_LIST=0 -- clear
[[ ! -e "$WORK/netstate/ready" ]] || ng "$CUR: clear の後に印が残っています"
[[ "$(grep -c '^iptables-restore' "$LOG")" == "1" ]] || ng "$CUR: iptables-restore が 1 回ではありません"
log_lacks '^iptables \[-(F|A|I|X|D)\]'
for l in '-D DOCKER-USER -i dev-runner0 -j DEV-RUNNER-FWD' '-D INPUT -i dev-runner0 -j DEV-RUNNER-IN' '-F DEV-RUNNER-FWD' '-X DEV-RUNNER-FWD' '-F DEV-RUNNER-IN' '-X DEV-RUNNER-IN'; do
  grep -qxF -- "$l" "$STATE/restore-in" || ng "$CUR: 取り込みの内容に「$l」がありません"
done
net_run 0 "net clear: 何も入っていなければ（飛び先も鎖も無い）、iptables-restore を呼ばない" -- clear
log_lacks '^iptables-restore'
mkdir -p "$WORK/netstate"
printf 'bridge=dev-runner0\n' >"$WORK/netstate/ready"
net_run 0 "net unmark: 印だけを消し、iptables には触らない" -- unmark
[[ ! -e "$WORK/netstate/ready" ]] || ng "$CUR: unmark の後に印が残っています"
log_lacks '^iptables'
net_run 1 "net: 知らない操作は拒む" -- bogus

rrun 0 "runner net unit: 規則を入れるシステムのユニットを出す" -- runner net unit
expect_no_calls
NUNIT="$WORK/dev-runner-net.service"
cp "$OUT" "$NUNIT"
nunit_has() { grep -qxF -- "$1" "$NUNIT" || ng "規則のユニットに「$1」の行がありません（$2）"; }
nunit_has 'After=docker.service' "Docker の後に入れる"
nunit_has 'PartOf=docker.service' "Docker の再起動のたびに入れ直す"
nunit_has 'Type=oneshot' "規則を入れて終わる"
nunit_has 'RemainAfterExit=yes' "入れた状態を active で持つ"
nunit_has 'ExecStart=/usr/local/sbin/dev-runner-net apply' "スクリプトの apply"
nunit_has 'ExecStop=/usr/local/sbin/dev-runner-net unmark' "止めたら印だけを消す（live-restore で動き続けるコンテナの制限を外さない）"
if grep -qE '^ExecStop(Post)?=.*(clear|-F|-X|iptables)' "$NUNIT"; then ng "規則のユニットが、止めるときに規則を消しています"; fi
nunit_has 'WantedBy=multi-user.target' "起動時に入れる"
nunit_has 'WantedBy=docker.service' "Docker を停止してから起動したときも、規則のユニットが起動されて印が戻る（PartOf は停止と再起動しか伝えない）"
rrun 2 "runner net: 引数なし" -- runner net
expect_err "使い方: dev runner net script|unit"
rrun 2 "runner net: 知らない種類" -- runner net bogus
expect_err "使い方: dev runner net script|unit"

# ランナーのユニット（dev-runner@.service）。同じく要の行を綴りで見る。
UNIT="${DEV_RUNNER_UNIT:-$HERE/dev-runner@.service}"
CUR="ランナーのユニット"
unit_has 'ExecStart=%h/.local/bin/dev runner run %i' "ジョブを 1 つ受けて終わる口。%I は - を / へ戻すので使わない"
unit_has 'Restart=always' "コンテナが止まったら（ジョブごとに）新しいコンテナで起こし直す"
unit_has 'StartLimitIntervalSec=0' "起動の直後に Docker が遅れても諦めない"
unit_has 'WantedBy=default.target' "ユーザーのマネージャの起動（linger で起動時）に付く"
if grep -qE '^[^#]*%I' "$UNIT"; then ng "ランナーのユニットが %I を使っています（名前の - が / に化ける）"; fi
unit_has 'SuccessExitStatus=143' "止めたときの 143 を成功として扱う"
unit_has 'RestartPreventExitStatus=2 78' "設定の誤り・PAT の権限・イメージ無しは起こし直さない"
grep -qE '^TimeoutStopSec=[0-9]+' "$UNIT" || ng "ランナーのユニットに TimeoutStopSec がありません（止めるときに登録を外す時間）"
# Dockerfile: 公式のランナーのイメージを、版を固定して使う（latest は使わない）。
DF="${DEV_RUNNER_DF:-$HERE/runner.Dockerfile}"
CUR="ランナーの Dockerfile"
grep -qE '^FROM ghcr\.io/actions/actions-runner:\$\{RUNNER_VERSION\}$' "$DF" || ng "Dockerfile が公式のランナーのイメージを ARG の版で使っていません"
grep -qE '^ARG RUNNER_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$DF" || ng "Dockerfile のランナーの版が固定されていません（ARG RUNNER_VERSION=X.Y.Z）"
if grep -qF 'download.docker.com' "$DF"; then ng "Dockerfile が Docker のリポジトリを足しています（公式のイメージが docker の CLI と buildx を持つ）"; fi
if grep -qE '^(COPY|ADD) ' "$DF"; then ng "Dockerfile が COPY / ADD を使っています（ビルドの文脈は渡さない）"; fi
# Dockerfile の apt の一覧と、README の「イメージ」の列挙（runner-apt の印の間）が一致すること。
# README は一覧の写しなので、片方だけに道具を足すと食い違う。その食い違いをここで落とす。
# 使い方: apt_list_check <Dockerfile> <README>。食い違えば理由を標準エラーへ出して 1 を返す。
apt_list_check() {
  local df="$1" readme="$2" df_set readme_set
  # Dockerfile: 継続行（\ で終わる行）をつないで && で区切り、apt-get install の区切りごとに、オプション（- で始まる語）を除いた語を取る。
  # 区切りの数・オプションの順番・パッケージの並びに依らない。
  df_set="$(sed -e ':a' -e '/\\$/{N;s/\\\n/ /;ba' -e '}' "$df" | sed 's/&&/\n/g' |
    awk '{ for (i = 1; i < NF; i++) if ($i == "apt-get" && $(i + 1) == "install") { for (j = i + 2; j <= NF; j++) if ($j !~ /^-/) print $j } }' | sort -u)"
  # README: 印の間を、改行をまたいでも読む。
  readme_set="$(tr '\n' ' ' <"$readme" | sed -n 's/.*<!-- runner-apt:begin -->\(.*\)<!-- runner-apt:end -->.*/\1/p' | tr -d '`' | tr ' ' '\n' | sed '/^$/d' | sort -u)"
  if [[ -z "$df_set" || -z "$readme_set" ]]; then
    echo "apt の一覧を取り出せません（Dockerfile の apt-get install、または README の runner-apt の印が見つかりません）" >&2
    return 1
  fi
  if [[ "$df_set" != "$readme_set" ]]; then
    # shellcheck disable=SC2116,SC2086 # 改行区切りの集合を、語分割で 1 行にして出す意図（echo $x）
    printf 'apt の一覧が違います\n  Dockerfile: %s\n  README:     %s\n' "$(echo $df_set)" "$(echo $readme_set)" >&2
    return 1
  fi
}
apt_list_check "$DF" "$README" || ng "Dockerfile の apt の一覧と README の列挙（runner-apt）が違います"
# 照合が、片方だけに足した道具で落ちることも確かめる（照合が常に通る形に壊れていないこと）。
# 足す位置は、一覧の並びに依らない所（最初の apt-get install の直後 / 終わりの印の直前）にする。
sed '0,/apt-get install /s//apt-get install extra-tool /' "$DF" >"$WORK/apt.Dockerfile"
grep -qF 'extra-tool' "$WORK/apt.Dockerfile" || ng "照合の試験の前提: Dockerfile の apt-get install を書き換えられません"
if apt_list_check "$WORK/apt.Dockerfile" "$README" 2>/dev/null; then ng "Dockerfile だけに足した道具を、照合が見逃しました"; fi
# shellcheck disable=SC2016 # バッククォートは Markdown の文字で、展開する意図は無い
sed 's/<!-- runner-apt:end -->/ `extra-tool`<!-- runner-apt:end -->/' "$README" >"$WORK/apt.README.md"
grep -qF 'extra-tool' "$WORK/apt.README.md" || ng "照合の試験の前提: README の列挙を書き換えられません"
if apt_list_check "$DF" "$WORK/apt.README.md" 2>/dev/null; then ng "README だけに足した道具を、照合が見逃しました"; fi

# ── 6g. runner route（ACTIONS_RUNS_ON をランナーのラベルへ向ける）────────────────
# 偽の curl（変数・ランナーグループ・ランナーの一覧）と偽の systemctl で、ネットワークを使わずに見る。
# 変数は $WORK/fakevars に、キャッシュとロックは $WORK/routestate に置く（呼び出しをまたいで持ち越す試験は RT_KEEP=1）。
ROUTES="$WORK/conf/routes"
cp "$WORK/conf/runner-pat" "$WORK/conf/route-pat"
chmod 600 "$WORK/conf/route-pat"
cat >"$ROUTES" <<EOF
# 試験の routes
rt1  my-org  group=my-group      # 行末のコメント
rt2  my-org  group=grp2  pat_file=$WORK/conf/pat-ro
rt3  my-org  group=my-group  pat_file=$WORK/conf/pat-loose
rt4  my-org  group=my-group  pat_file=$WORK/conf/no-such-pat
EOF
ROUTE_RCONF="$WORK/conf/runners-route"
cat >"$ROUTE_RCONF" <<EOF
q1  my-org  labels=devhost,rt1  group=my-group
q2  my-org  labels=rt2  group=other-group
q3  my-org  labels=rt3  group=my-group
q4  my-org  labels=rt4  group=my-group
q5  other-org  labels=rt1  group=my-group
EOF
mkdir -p "$WORK/fakevars"
# flock だけを外した道具の置き場（flock が無い機械の動き）
mkdir -p "$WORK/toolbin-noflock"
for tool in "$TOOLBIN"/*; do
  [[ "${tool##*/}" == "flock" ]] || ln -s "$(readlink "$tool")" "$WORK/toolbin-noflock/${tool##*/}"
done

RT_VARS="" RT_KEEP=0 RT_CACHE=""
# rt <期待する終了コード> <名前> [VAR=値 ...] -- dev の引数 ...
# 直前に RT_VARS="リポジトリ=値 ..."（初期の変数）、RT_CACHE="a,b"（rt1 のキャッシュ。EMPTY なら空のファイル）、RT_KEEP=1（前の呼び出しの変数・キャッシュを持ち越す）を置ける。
rt() {
  local want="$1" rname="$2" ev=() kv
  shift 2
  while [[ $# -gt 0 && "$1" != "--" ]]; do ev+=("$1"); shift; done
  [[ $# -gt 0 ]] && shift
  if [[ "$RT_KEEP" -ne 1 ]]; then
    rm -rf "$WORK/fakevars" "$WORK/routestate"
    mkdir -p "$WORK/fakevars"
    for kv in $RT_VARS; do printf '%s' "${kv#*=}" >"$WORK/fakevars/${kv%%=*}"; done
    if [[ "$RT_CACHE" == "EMPTY" ]]; then
      mkdir -m 700 "$WORK/routestate"
      : >"$WORK/routestate/route-my-org.rt1"
    elif [[ -n "$RT_CACHE" ]]; then
      mkdir -m 700 "$WORK/routestate"
      printf '%s\n' "$RT_CACHE" | tr ',' '\n' >"$WORK/routestate/route-my-org.rt1"
    fi
  fi
  RT_VARS="" RT_KEEP=0 RT_CACHE=""
  reset_state
  run "$want" "$rname" -- PATH="$ROUTEBIN:$FAKEBIN:$TOOLBIN" DEV_ROUTES_FILE="$ROUTES" DEV_RUNNERS_FILE="$ROUTE_RCONF" DEV_ROUTE_STATE_DIR="$WORK/routestate" \
    DEV_RUNNER_HOSTNAME=h FAKE_VARS_DIR="$WORK/fakevars" FAKE_PAT_EXPECT="$PATV" DEV_ROUTE_RECHECK_WAIT=0 ${ev[@]+"${ev[@]}"} -- "$@"
}
writes_has() { grep -qxF -- "$1" "$STATE/writes" 2>/dev/null || { ng "$CUR: 書き込みの記録に「$1」がありません"; sed 's/^/    /' "$STATE/writes" 2>/dev/null >&2 || true; }; }
writes_lack() { if grep -qE -- "$1" "$STATE/writes" 2>/dev/null; then ng "$CUR: 書き込みの記録に /$1/ があってはなりません"; sed 's/^/    /' "$STATE/writes" >&2; fi; }
no_writes() { if [[ -s "$STATE/writes" ]]; then ng "$CUR: 書かないはずが書いています"; sed 's/^/    /' "$STATE/writes" >&2; fi; }
var_is() {
  local f="$WORK/fakevars/$1"
  if [[ ! -f "$f" ]]; then ng "$CUR: 変数 $1 が未設定です（期待: $2）"; return; fi
  [[ "$(cat "$f")" == "$2" ]] || ng "$CUR: 変数 $1 の値が違います（期待: $2、実際: $(cat "$f")）"
}
var_unset() { if [[ -e "$WORK/fakevars/$1" ]]; then ng "$CUR: 変数 $1 は未設定のままのはずが、作られています"; fi; }
cache_is() {
  local got
  got="$(tr '\n' ' ' <"$WORK/routestate/route-my-org.rt1" 2>/dev/null || echo '(無し)')"
  [[ "$got" == "$1" ]] || ng "$CUR: キャッシュの中身が違います（期待: [$1]、実際: [$got]）"
}
# 変数 ACTIONS_RUNS_ON の読み取り（GET）が、そのリポジトリに何回あったか。
var_gets() { grep -cE "\[GET\].*repos/my-org/$1/actions/variables/ACTIONS_RUNS_ON\]\$" "$LOG" || true; }

# ── 設定の誤りは API を呼ばずに 2 ──
rt 2 "route: 引数なし" -- runner route
expect_err "使い方: dev runner route up|down|sync|show"
expect_no_calls
rt 2 "route: 知らないサブコマンド" -- runner route bogus rt1
expect_err "知らない route のサブコマンドです"
expect_no_calls
rt 2 "route: ラベルが無い" -- runner route up
expect_err "使い方: dev runner route up"
expect_no_calls
rt 2 "route: 余分な引数" -- runner route up rt1 rt2
expect_err "ラベルは 1 つだけ指定します"
expect_no_calls
rt 2 "route: routes に無いラベル" -- runner route up nope
expect_err "routes に無いラベルです: nope（登録済み: rt1 rt2 rt3 rt4）"
expect_no_calls
rt 2 "route: routes が無い" DEV_ROUTES_FILE="$WORK/conf/none" -- runner route up rt1
expect_err "設定ファイルがありません"
expect_no_calls
rt 2 "route: --retries が整数でない" -- runner route up rt1 --retries abc
expect_err "--retries には 0 から 10 の整数が要ります"
expect_no_calls
rt 2 "route: --retries が大きすぎる" -- runner route up rt1 --retries 11
expect_no_calls
rt 2 "route: --retry-wait が負" -- runner route up rt1 --retry-wait -1
expect_no_calls
rt 2 "route: --retry-wait に値が無い" -- runner route up rt1 --retry-wait
expect_no_calls
rt 2 "route: 知らないオプション" -- runner route up rt1 --bogus
expect_err "知らないオプションです"
expect_no_calls
rt 2 "route: show はオプションを取らない（書かないので）" -- runner route show rt1 --retries 1
expect_no_calls
rt 2 "route: DEV_ROUTE_PARALLEL が 0" DEV_ROUTE_PARALLEL=0 -- runner route up rt1
expect_err "DEV_ROUTE_PARALLEL は 1 から 32"
expect_no_calls
rt 2 "route: DEV_ROUTE_PARALLEL が 33" DEV_ROUTE_PARALLEL=33 -- runner route up rt1
expect_no_calls
rt 2 "route: DEV_ROUTE_RECHECK_WAIT が整数でない" DEV_ROUTE_RECHECK_WAIT=x -- runner route sync rt1
expect_err "DEV_ROUTE_RECHECK_WAIT"
expect_no_calls
T="$WORK/conf/routes.bad"
printf 'x my-org group=g bogus=1\n' >"$T"
rt 2 "routes: 知らないキーは設定の誤り" DEV_ROUTES_FILE="$T" -- runner route up x
expect_err "知らないキーです（group / pat_file）"
printf 'x my-org\n' >"$T"
rt 2 "routes: group の無い行は設定の誤り" DEV_ROUTES_FILE="$T" -- runner route up x
expect_err "「ラベル 組織 group=<名前>」の 3 つが要ります"
printf 'x my-org pat_file=/p\n' >"$T"
rt 2 "routes: group= が無い（pat_file だけ）行は設定の誤り" DEV_ROUTES_FILE="$T" -- runner route up x
expect_err "group=<名前> は必須です"
printf 'x my-org group=g pat_file=rel/path\n' >"$T"
rt 2 "routes: pat_file が相対パスなら設定の誤り" DEV_ROUTES_FILE="$T" -- runner route up x
expect_err "pat_file は絶対パスで書きます"
printf 'x my-org group=\n' >"$T"
rt 2 "routes: 値が空なら設定の誤り" DEV_ROUTES_FILE="$T" -- runner route up x
expect_err "値が空です"
printf 'x my-org group=a/b\n' >"$T"
rt 2 "routes: group に許可外の文字があれば設定の誤り" DEV_ROUTES_FILE="$T" -- runner route up x
expect_err "group に使えるのは"
printf 'x my-org g\n' >"$T"
rt 2 "routes: 3 つ目が キー=値 でなければ設定の誤り" DEV_ROUTES_FILE="$T" -- runner route up x
expect_err "キー=値 で書きます"
# shellcheck disable=SC2016 # 展開しない文字列として渡す
for bad in 'a/b' 'a b' '-x' '.x' 'a$b' 'a"b'; do
  printf '%s my-org group=g\n' "$bad" >"$T"
  rt 2 "routes: ラベルに許可外の文字（$bad）があれば設定の誤り" DEV_ROUTES_FILE="$T" -- runner route up x
done
printf 'x bad_org group=g\n' >"$T"
rt 2 "routes: 組織名に許可外の文字があれば設定の誤り" DEV_ROUTES_FILE="$T" -- runner route up x
expect_err "組織名に使えるのは"
printf 'x my-org group=g\nx my-org group=g\n' >"$T"
rt 2 "routes: ラベルの重複" DEV_ROUTES_FILE="$T" -- runner route up x
expect_err "ラベルが重複しています"
printf '# だけ\n' >"$T"
rt 2 "routes: 行が 1 つも無い" DEV_ROUTES_FILE="$T" -- runner route up x
expect_err "行が 1 つもありません"
expect_no_calls
rt 2 "route: PAT の権限が緩ければ（644）API を呼ばずに 2" -- runner route up rt3
expect_err "PAT ファイルの権限が緩すぎます"
expect_no_calls
no_pat_leak
rt 2 "route: PAT のファイルが無ければ 2" -- runner route up rt4
expect_err "PAT ファイルがありません"
expect_no_calls
rt 2 "route: show でも、PAT の権限が緩ければ 2" -- runner route show rt3
expect_no_calls

# ── up: 混在からそろえる・冪等 ──
RT_VARS="r-a=ubuntu-latest r-c=rt1"
rt 0 "route up: 混在（更新・作成・変更なし）から、ラベルへそろえる" -- runner route up rt1
writes_has "PATCH r-a rt1"
writes_has "POST r-b rt1"
writes_lack " r-c "
var_is r-a rt1
var_is r-b rt1
var_is r-c rt1
expect_out_line 'r-a: rt1 へ更新しました'
expect_out_line 'r-b: rt1 で作りました'
expect_out_line 'r-c: 変更なし（rt1）'
log_has '^curl \[-sSL\] \[-K\] \[-\] \[-X\] \[PATCH\] .*\[-d\] \[\{"name":"ACTIONS_RUNS_ON","value":"rt1"\}\] .*repos/my-org/r-a/actions/variables/ACTIONS_RUNS_ON\]$'
log_has '^curl \[-sSL\] \[-K\] \[-\] \[-X\] \[POST\] .*\[-d\] \[\{"name":"ACTIONS_RUNS_ON","value":"rt1"\}\] .*repos/my-org/r-b/actions/variables\]$'
grep -qF "Bearer $PATV" "$STATE/curl-config" || ng "$CUR: PAT が curl の標準入力の設定で渡っていません"
no_pat_leak
cache_is "r-a r-b r-c "
mode="$(stat -c %a "$WORK/routestate/route-my-org.rt1" 2>/dev/null || stat -f %Lp "$WORK/routestate/route-my-org.rt1")"
[[ "$mode" == "600" ]] || ng "$CUR: キャッシュの権限が 600 ではありません（$mode）"
mode="$(stat -c %a "$WORK/routestate" 2>/dev/null || stat -f %Lp "$WORK/routestate")"
[[ "$mode" == "700" ]] || ng "$CUR: 状態のディレクトリの権限が 700 ではありません（$mode）"
RT_KEEP=1 rt 0 "route up: 2 回目は冪等（もう揃っているので何も書かない）" -- runner route up rt1
no_writes
log_lacks '\[PATCH\]'
log_lacks '\[POST\]'
RT_VARS="r-a= r-b=rt1 r-c=rt1"
rt 0 "route up: 値が空の既存の変数は設定済みとして扱う（POST でなく PATCH）" -- runner route up rt1
writes_has "PATCH r-a rt1"
writes_lack '^POST'
var_is r-a rt1
printf 'x.y_z-1 my-org group=my-group\n' >"$WORK/conf/routes-dots"
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 0 "route up: ラベルに . _ - を含む値もそのまま書く" DEV_ROUTES_FILE="$WORK/conf/routes-dots" -- runner route up x.y_z-1
writes_has "PATCH r-a x.y_z-1"

# ── 一部の失敗・やり直し ──
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 1 "route up: 一部が失敗しても、残りは続けて書き、失敗が残れば 1" FAKE_WRITE_FAIL=r-b -- runner route up rt1 --retries 0
writes_has "PATCH r-a rt1"
writes_has "PATCH r-c rt1"
writes_lack ' r-b '
var_is r-b ubuntu-latest
expect_err "r-b: 失敗しました"
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 0 "route up: 失敗した分だけやり直し（成功した分は読み直さない）、直れば 0" FAKE_WRITE_FAIL_ONCE=r-b -- runner route up rt1 --retries 2 --retry-wait 5
var_is r-b rt1
[[ "$(var_gets r-a)" == "1" ]] || ng "$CUR: 成功した r-a を読み直しています（GET が $(var_gets r-a) 回）"
[[ "$(var_gets r-b)" == "2" ]] || ng "$CUR: r-b は 2 回読むはずです（GET が $(var_gets r-b) 回）"
log_has '^sleep \[5\]$'
expect_err "失敗が 1 件あります。5 秒後にやり直します（1/2）"
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 1 "route up: やり直しの回数を使い切ったら 1" FAKE_WRITE_FAIL=r-b -- runner route up rt1 --retries 2 --retry-wait 7
[[ "$(var_gets r-b)" == "3" ]] || ng "$CUR: r-b は 1 回 + やり直し 2 回の 3 回読むはずです（GET が $(var_gets r-b) 回）"
[[ "$(var_gets r-a)" == "1" ]] || ng "$CUR: 成功した r-a を読み直しています"
[[ "$(grep -c '^sleep \[7\]$' "$LOG")" == "2" ]] || ng "$CUR: 待ちが 2 回のはずです"
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 1 "route up: 読み取りが 403 のリポジトリは失敗として数え、残りは続ける" FAKE_VAR_403=r-a -- runner route up rt1 --retries 0
writes_has "PATCH r-b rt1"
writes_has "PATCH r-c rt1"
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 1 "route up: 読み取りが 500 のリポジトリは失敗として数える" FAKE_VAR_FAIL=r-c -- runner route up rt1 --retries 0
writes_has "PATCH r-a rt1"
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 1 "route up: 通信の失敗は 1（PAT を出さない）" FAKE_API_NETFAIL=1 -- runner route up rt1 --retries 0
no_writes
no_pat_leak

# ── 対象の読み方（グループ・ページ送り・空・selected 以外）──
RT_VARS=""
rt 0 "route up: グループの一覧が複数ページでも、2 ページ目のグループを引く" FAKE_GROUPS_PAD=100 -- runner route up rt1
log_has 'runner-groups\?per_page=100&page=1\]$'
log_has 'runner-groups\?per_page=100&page=2\]$'
writes_has "POST r-a rt1"
rt 0 "route up: 対象が複数ページ（105 件）でも全件を書く" FAKE_GROUP_REPOS_GEN=105 DEV_ROUTE_PARALLEL=16 -- runner route up rt1 --retries 0
log_has 'runner-groups/[0-9]+/repositories\?per_page=100&page=2\]$'
[[ "$(grep -c '^POST ' "$STATE/writes")" == "105" ]] || ng "$CUR: 105 件を作るはずが $(grep -c '^POST ' "$STATE/writes") 件です"
writes_has "POST gen-105 rt1"
rt 0 "route up: 0 件のグループは失敗でなく正しい空の一覧（何も書かず、キャッシュも空）" FAKE_GROUP_REPOS= -- runner route up rt1
no_writes
log_lacks 'actions/variables'
cache_is ""
rt 2 "route up: 使えるリポジトリが selected でなければ設定の誤り(2)。何も書かない" FAKE_GROUP_VIS=all -- runner route up rt1
expect_err "selected ではありません（all）"
log_lacks 'actions/variables'
log_lacks 'repositories'
rt 2 "route up: グループが無ければ設定の誤り(2)" FAKE_GROUPS=Default -- runner route up rt1
expect_err "ランナーグループ my-group が組織 my-org にありません"
log_lacks 'actions/variables'
RT_VARS="r-a=rt1" RT_CACHE="r-a"
rt 2 "route down: グループが無くても、前回の一覧で戻してから設定の誤り(2)（ラベルを指したまま残さない）" FAKE_GROUPS=Default -- runner route down rt1
writes_has "PATCH r-a ubuntu-latest"
expect_err "routes かグループの設定を直してください"
RT_VARS="r-a=rt1" RT_CACHE="r-a"
rt 2 "route down: selected でなくても、前回の一覧で戻してから 2" FAKE_GROUP_VIS=all -- runner route down rt1
writes_has "PATCH r-a ubuntu-latest"
rt 2 "route down: グループが無く、前回の一覧も無ければ、何も書かず 2" FAKE_GROUPS=Default -- runner route down rt1
no_writes
for code in 403 500; do
  rt 1 "route up: グループの一覧が HTTP $code で読めなければ、何も書かず 1" FAKE_API_FAIL=groups FAKE_API_CODE=$code -- runner route up rt1
  expect_err "対象の一覧を読めないので、up では何も書きません"
  log_lacks 'actions/variables'
done
rt 1 "route up: 対象のリポジトリの一覧を読めなければ、何も書かず 1" FAKE_API_FAIL=group-repos -- runner route up rt1
log_lacks 'actions/variables'

# ── ロックを取ったあとの読み直し（ロックの外で読んでから書くまでにグループが変わる）──
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 0 "route up: ロックの外で読んだあとにグループから外れたものは、読み直した一覧で書かず向けない" FAKE_GROUP_REPOS_AFTER=r-a,r-c -- runner route up rt1
writes_has "PATCH r-a rt1"
writes_has "PATCH r-c rt1"
writes_lack ' r-b '
var_is r-b ubuntu-latest
cache_is "r-a r-c "
expect_out_line "ロックを取るまでにグループの対象が変わったので、読み直した一覧で書きます"
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 0 "route up: ロックの外で読んだあとにグループへ足されたものも、読み直した一覧で書く" FAKE_GROUP_REPOS_AFTER=r-a,r-b,r-c,r-d -- runner route up rt1
writes_has "POST r-d rt1"
cache_is "r-a r-b r-c r-d "
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 1 "route up: 読み直せなければ、ロックの外で読んだ一覧を使わず、何も書かず 1" FAKE_GROUP_REPOS_AFTER_FAIL=1 -- runner route up rt1
no_writes
expect_err "ロックを取った後に対象の一覧を読み直せないので、up では何も書きません"
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 0 "route sync: ロックの外で読んだあとにグループから外れたものは、読み直した一覧で書かず向けない" FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS=h-q1:online:rt1 FAKE_GROUP_REPOS_AFTER=r-a,r-c -- runner route sync rt1
writes_has "PATCH r-a rt1"
writes_lack ' r-b '
var_is r-b ubuntu-latest
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 1 "route sync: 読み直せなければ、何も書かず 1" FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS=h-q1:online:rt1 FAKE_GROUP_REPOS_AFTER_FAIL=1 -- runner route sync rt1
no_writes
RT_CACHE="r-a,r-b,r-c" RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route down: 読み直せなければ、今までどおりキャッシュの一覧で ubuntu-latest へ戻す" FAKE_GROUP_REPOS_AFTER_FAIL=1 -- runner route down rt1
writes_has "PATCH r-a ubuntu-latest"
writes_has "PATCH r-b ubuntu-latest"
writes_has "PATCH r-c ubuntu-latest"
expect_err "キャッシュ"
RT_CACHE="r-a,r-b,r-c" RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route down: 読み直した一覧が違えば、それで書く（外れたものはキャッシュから戻す）" FAKE_GROUP_REPOS_AFTER=r-a,r-b -- runner route down rt1
writes_has "PATCH r-a ubuntu-latest"
writes_has "PATCH r-b ubuntu-latest"
writes_has "PATCH r-c ubuntu-latest"

# ── グループから外したリポジトリの扱い・キャッシュ ──
RT_CACHE="r-a,r-b,r-x" RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1 r-x=rt1"
rt 0 "route up: キャッシュにあってグループに無い（外した）リポジトリは ubuntu-latest へ戻す" -- runner route up rt1
writes_has "PATCH r-x ubuntu-latest"
var_is r-x ubuntu-latest
cache_is "r-a r-b r-c "
RT_KEEP=1 rt 0 "route up: 戻したあとの 2 回目は、外したリポジトリに触らない" -- runner route up rt1
no_writes
[[ "$(var_gets r-x)" == "0" ]] || ng "$CUR: 外したあとの r-x を読んでいます"
RT_CACHE="r-a,r-x" RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1 r-x=rt1"
rt 0 "route up: 外したリポジトリが自分のラベルを指していれば ubuntu-latest へ戻す" -- runner route up rt1
writes_has "PATCH r-x ubuntu-latest"
RT_CACHE="r-a,r-x" RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1 r-x=custom-value"
rt 0 "route up: 外したリポジトリが別の値（ほかの切り替え・手の設定）なら触らない" -- runner route up rt1
var_is r-x custom-value
expect_out_line 'r-x: 別の値を指しているので触りません'
cache_is "r-a r-b r-c "
RT_CACHE="r-a,r-x" RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route up: 外したリポジトリの変数が未設定なら、作らずに済ませる" -- runner route up rt1
var_unset r-x
cache_is "r-a r-b r-c "
RT_CACHE="r-a,r-x" RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1 r-x=rt1"
rt 1 "route up: 戻せなかった外したリポジトリはキャッシュに残し、1" FAKE_WRITE_FAIL=r-x -- runner route up rt1 --retries 0
cache_is "r-a r-b r-c r-x "
RT_KEEP=1 rt 0 "route up: 持ち越したものを、次の実行で戻す" -- runner route up rt1
writes_has "PATCH r-x ubuntu-latest"
cache_is "r-a r-b r-c "
RT_CACHE="r-a" RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 1 "route up: 一部が失敗しても、読めた一覧はキャッシュへ足す（途中で切れても戻し先を失わない）" FAKE_WRITE_FAIL=r-b -- runner route up rt1 --retries 0
cache_is "r-a r-b r-c "

# ── 読めないときの向き ──
RT_CACHE="r-a,r-b" RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route down: グループを読めなければ、キャッシュの一覧で ubuntu-latest へ戻す" FAKE_API_FAIL=groups -- runner route down rt1
writes_has "PATCH r-a ubuntu-latest"
writes_has "PATCH r-b ubuntu-latest"
writes_lack ' r-c '
expect_err "キャッシュ"
var_is r-c rt1
cache_is "r-a r-b "
RT_CACHE="r-a,r-b" RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest"
rt 1 "route up: グループを読めなければ、キャッシュがあっても何も書かず 1（古い一覧で向け直さない）" FAKE_API_FAIL=groups -- runner route up rt1
no_writes
log_lacks 'actions/variables'
rt 1 "route down: グループを読めず、キャッシュも無ければ 1" FAKE_API_FAIL=groups -- runner route down rt1
expect_err "キャッシュも無い"
log_lacks 'actions/variables'
RT_CACHE="r-a,r-b" RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest"
rt 1 "route sync: グループを読めなければ、キャッシュがあっても何も書かず 1" FAKE_API_FAIL=groups FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS=h-q1:online:rt1 -- runner route sync rt1
no_writes
log_lacks 'actions/variables'
RT_CACHE=EMPTY RT_VARS=""
rt 0 "route down: 前回が 0 件(空のキャッシュ)なら、グループを読めなくても何も書かず 0" FAKE_API_FAIL=group-repos -- runner route down rt1
log_lacks 'actions/variables'
rt 0 "route up: 既定の置き場所は XDG_CACHE_HOME の下の dev（権限 700）" DEV_ROUTE_STATE_DIR= XDG_CACHE_HOME="$WORK/xdgc" -- runner route up rt1
[[ -f "$WORK/xdgc/dev/route-my-org.rt1" ]] || ng "$CUR: キャッシュが既定の置き場所にありません"
mode="$(stat -c %a "$WORK/xdgc/dev" 2>/dev/null || stat -f %Lp "$WORK/xdgc/dev")"
[[ "$mode" == "700" ]] || ng "$CUR: 既定の置き場所の権限が 700 ではありません（$mode）"
mkdir -p "$WORK/loose-state"
chmod 777 "$WORK/loose-state"
# キャッシュを書けない（状態のディレクトリに書き込めない）ときは、ラベルへ向けない。ロックのファイルは先に置いておく。
rm -rf "$WORK/ro-state"; mkdir -m 700 "$WORK/ro-state"; : >"$WORK/ro-state/route-rt1.lock"; chmod 500 "$WORK/ro-state"
if [[ -w "$WORK/ro-state" ]]; then
  echo "[devhost-selftest] キャッシュを書けない試験は、書き込み権限を外せない環境（root など）なので飛ばします"
else
  RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
  rt 1 "route up: キャッシュを書けなければ、ラベルへ向けずに 1（停止のときに戻す対象を失わないため）" DEV_ROUTE_STATE_DIR="$WORK/ro-state" -- runner route up rt1
  no_writes
  expect_err "キャッシュを書けないので、rt1 へは向けません"
fi
chmod 700 "$WORK/ro-state"
RT_CACHE="r-a,r-b,r-c" RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 1 "route up: 対象の一覧の応答に配列のキーが無ければ、0 件と読まず 1（キャッシュの全件を外れたものとして戻さない）" FAKE_API_BADBODY=group-repos -- runner route up rt1
no_writes
cache_is "r-a r-b r-c "
RT_CACHE="r-a,r-b,r-c" RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 1 "route up: 対象の一覧に名前の無い要素が混ざれば、欠けた一覧と読まず 1（欠けたものを外れたとして戻さない）" FAKE_API_BADBODY=group-repos-item -- runner route up rt1
no_writes
cache_is "r-a r-b r-c "
expect_err "名前を読めない要素があります"
# キャッシュは組織ごと。同じラベルでも、別の組織のキャッシュにあるリポジトリは「外れた」として扱わない。
rm -rf "$WORK/fakevars" "$WORK/routestate"; mkdir -p "$WORK/fakevars"; mkdir -m 700 "$WORK/routestate"
for kv in r-a=rt1 r-b=rt1 r-c=rt1 r-x=rt1; do printf '%s' "${kv#*=}" >"$WORK/fakevars/${kv%%=*}"; done
printf 'r-x\n' >"$WORK/routestate/route-old-org.rt1"; chmod 600 "$WORK/routestate/route-old-org.rt1"
RT_KEEP=1 rt 0 "route up: 別の組織のキャッシュ（route-<組織>.<ラベル>）は混ぜない" -- runner route up rt1
var_is r-x rt1
cache_is "r-a r-b r-c "
rt 2 "route up: 状態のディレクトリに group / other の書き込み権限があれば 2" DEV_ROUTE_STATE_DIR="$WORK/loose-state" -- runner route up rt1
expect_err "group / other の書き込み権限があります"
expect_no_calls
rm -rf "$WORK/loose-state"

# ── down ──
RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route down: 対象を ubuntu-latest へ戻す" -- runner route down rt1
writes_has "PATCH r-a ubuntu-latest"
writes_has "PATCH r-b ubuntu-latest"
writes_has "PATCH r-c ubuntu-latest"
no_pat_leak
RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route down: ほかの機械（名前の先頭のホスト名が違う）の同じラベルのランナーが online なら戻さない" FAKE_RUNNERS=other-q1:online:rt1+devhost -- runner route down rt1
no_writes
expect_out_line 'ほかの機械のランナーが online（1 台）なので、ubuntu-latest へは戻しません'
RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route down: ほかの機械のランナーが offline なら戻す" FAKE_RUNNERS=other-q1:offline:rt1 -- runner route down rt1
writes_has "PATCH r-a ubuntu-latest"
RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route down: online なのがこの機械のランナーだけなら戻す（止まる側の機械なので）" FAKE_RUNNERS=h-q1:online:rt1 -- runner route down rt1
writes_has "PATCH r-a ubuntu-latest"
RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route down: ホスト名が前方一致するほかの機械（h-x）のランナーは、この機械のものと取り違えず戻さない" FAKE_RUNNERS=h-x-q1:online:rt1 -- runner route down rt1
no_writes
expect_out_line 'ほかの機械のランナーが online（1 台）なので'
RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route down: ほかの機械のランナーでも、ラベルが違えば戻す" FAKE_RUNNERS=other-q1:online:devhost -- runner route down rt1
writes_has "PATCH r-a ubuntu-latest"
RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route down: ランナーの一覧を読めなければ戻す" FAKE_API_FAIL=runners -- runner route down rt1
writes_has "PATCH r-a ubuntu-latest"
RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route down: ランナーの一覧が複数ページでも、2 ページ目のほかの機械のランナーを見つけて戻さない" FAKE_RUNNERS=other-q1:online:rt1 FAKE_RUNNERS_PAGES=2 -- runner route down rt1
no_writes
log_has 'runner-groups/[0-9]+/runners\?per_page=100&page=2\]$'
RT_CACHE="r-a,r-x" RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1 r-x=rt1"
rt 0 "route down: ほかの機械のランナーが online でも、グループから外れたものは戻す" FAKE_RUNNERS=other-q1:online:rt1 -- runner route down rt1
writes_has "PATCH r-x ubuntu-latest"
writes_lack ' r-a '

# ── sync ──
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 0 "route sync: ユニットが active でなければ、API を呼ばずに 0" FAKE_RUNNERS=h-q1:online:rt1 -- runner route sync rt1
log_lacks '^curl '
no_writes
expect_out_line 'dev-route@rt1.service が active ではない'
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 0 "route sync: ユニットが activating のときも書かない（active のときだけ）" FAKE_ACTIVATING_UNITS=dev-route@rt1.service FAKE_RUNNERS=h-q1:online:rt1 -- runner route sync rt1
log_lacks '^curl '
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 0 "route sync: active で、online のランナーが居ればラベルへそろえる" FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS=h-q1:online:rt1+devhost -- runner route sync rt1
writes_has "PATCH r-a rt1"
writes_has "PATCH r-b rt1"
writes_has "PATCH r-c rt1"
log_lacks '^sleep '
RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route sync: active で、ランナーが居なければ（読み直しても居ない）ubuntu-latest へ戻す" FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS=h-q1:offline:rt1 -- runner route sync rt1
writes_has "PATCH r-a ubuntu-latest"
[[ "$(grep -c '/runners?per_page' "$LOG")" == "2" ]] || ng "$CUR: ランナーの一覧を 2 回（1 回目と読み直し）読むはずです"
expect_out_line 'online のランナーが居ません。0 秒後に読み直します'
RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route sync: 読み直すまでの待ちの既定は 60 秒" DEV_ROUTE_RECHECK_WAIT= FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS=h-q1:offline:rt1 -- runner route sync rt1
log_has '^sleep \[60\]$'
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 0 "route sync: ジョブの切れ目（1 回目は 0 台、読み直しで 1 台）なら、戻さずラベルへそろえる" FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS_FIRST=none:offline: FAKE_RUNNERS=h-q1:online:rt1 -- runner route sync rt1
writes_has "PATCH r-a rt1"
writes_lack 'ubuntu-latest'
RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route sync: 1 回目に居れば読み直さない（待たない）" FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS=h-q1:online:rt1 -- runner route sync rt1
log_lacks '^sleep '
no_writes
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 0 "route sync: ほかの機械のランナーだけが online でも、ラベルへそろえる" FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS=other-q1:online:rt1 -- runner route sync rt1
writes_has "PATCH r-a rt1"
RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route sync: online でもラベルが違うランナーは数えない" FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS=h-q9:online:devhost -- runner route sync rt1
writes_has "PATCH r-a ubuntu-latest"
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 1 "route sync: ランナーの一覧を読めなければ、判定できないので何も書かず 1" FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_API_FAIL=runners -- runner route sync rt1
no_writes
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 1 "route sync: 読み直しで一覧を読めなければ、何も書かず 1" FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS_FIRST=none:offline: FAKE_API_FAIL=runners -- runner route sync rt1
no_writes
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 1 "route sync: flock が無ければ書かない" PATH="$ROUTEBIN:$FAKEBIN:$WORK/toolbin-noflock" FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS=h-q1:online:rt1 -- runner route sync rt1
expect_err "flock（util-linux）が無い"
no_writes
log_lacks 'actions/variables'
RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route down: flock が無ければ、警告してロックなしで進める" PATH="$ROUTEBIN:$FAKEBIN:$WORK/toolbin-noflock" -- runner route down rt1
expect_err "flock が無いので、ロックなしで進めます"
writes_has "PATCH r-a ubuntu-latest"

# ── ロック: sync も up / down も、ラベルごとの同じロックを取る ──
RT_VARS="r-a=ubuntu-latest r-b=ubuntu-latest r-c=ubuntu-latest"
rt 0 "route: 準備（ロックのファイルを作る）" FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS=h-q1:online:rt1 -- runner route sync rt1
exec 7>>"$WORK/routestate/route-rt1.lock"
flock -n 7 || ng "試験の前提: ロックを取れません"
RT_KEEP=1 rt 1 "route sync: 停止の処理（ロックの保持者）が動いているあいだは、ロックを取れず書かない" DEV_ROUTE_LOCK_WAIT=0 FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS=h-q1:online:rt1 -- runner route sync rt1
expect_err "ロックを 0 秒待ちましたが取れませんでした"
log_lacks 'actions/variables'
RT_KEEP=1 rt 1 "route down: 同じロックを取る（保持者が居れば取れない）" DEV_ROUTE_LOCK_WAIT=0 -- runner route down rt1
expect_err "ロックを 0 秒待ちましたが取れませんでした"
RT_KEEP=1 rt 1 "route up: 同じロックを取る（保持者が居れば取れない）" DEV_ROUTE_LOCK_WAIT=0 -- runner route up rt1
log_lacks 'actions/variables'
RT_KEEP=1 rt 0 "route: 別のラベルのロックは邪魔しない" DEV_ROUTE_LOCK_WAIT=0 FAKE_GROUPS=Default,grp2 -- runner route up rt2
writes_has "PATCH r-a rt2"
flock -u 7
exec 7>&-
RT_KEEP=1 rt 0 "route sync: ロックが外れれば書ける" DEV_ROUTE_LOCK_WAIT=0 FAKE_ACTIVE_UNITS=dev-route@rt1.service FAKE_RUNNERS=h-q1:online:rt1 -- runner route sync rt1
writes_has "PATCH r-a rt1"

# ── 並列の上限 ──
par_max() { awk 'BEGIN { m = 0 } { if ($1 + 0 > m) m = $1 + 0 } END { print m }' "$STATE/par" 2>/dev/null || echo 0; }
RT_VARS=""
rt 0 "route up: リポジトリごとに並列で書き、同時に走る数は上限（DEV_ROUTE_PARALLEL=3）を超えない" DEV_ROUTE_PARALLEL=3 FAKE_PAR_TRACK=1 FAKE_GROUP_REPOS=p1,p2,p3,p4,p5,p6,p7 -- runner route up rt1
pm="$(par_max)"
if [[ "$pm" -gt 3 || "$pm" -lt 2 ]]; then ng "$CUR: 同時に走った最大が 2 から 3 のはずが $pm です"; fi
[[ "$(grep -c '^POST ' "$STATE/writes")" == "7" ]] || ng "$CUR: 7 件を作るはずです"
RT_VARS=""
rt 0 "route up: DEV_ROUTE_PARALLEL=1 なら 1 つずつ" DEV_ROUTE_PARALLEL=1 FAKE_PAR_TRACK=1 FAKE_GROUP_REPOS=p1,p2,p3 -- runner route up rt1
[[ "$(par_max)" == "1" ]] || ng "$CUR: 同時に走った最大が 1 のはずが $(par_max) です"

# ── show: 書かない ──
RT_VARS="r-a=ubuntu-latest r-c=rt1"
rt 0 "route show: 対象ごとの今の値を出し、何も書かない（未設定も示す）" -- runner route show rt1
no_writes
log_lacks '\[PATCH\]'
log_lacks '\[POST\]'
expect_out_line 'r-a[[:space:]]+ubuntu-latest'
expect_out_line 'r-b[[:space:]]+\(未設定\)'
expect_out_line 'r-c[[:space:]]+rt1'
[[ ! -e "$WORK/routestate/route-my-org.rt1" ]] || ng "$CUR: show がキャッシュを書いています"
no_pat_leak
printf 'x\033[31mred' >"$WORK/fakevars/r-a"
printf 'a b' >"$WORK/fakevars/r-b"
# shellcheck disable=SC2016 # 展開されない文字列を値に書く
printf '$(touch /tmp/x)' >"$WORK/fakevars/r-c"
RT_KEEP=1 rt 0 "route show: 変数の値は制御文字をエスケープして出す（端末へそのまま出さない）" -- runner route show rt1
if grep -q "$(printf '\033')" "$OUT"; then ng "$CUR: ESC がそのまま出ています"; fi
esc_pat='r-a[[:space:]]+\$'"'"'x\\[Ee]\[31mred'"'"
grep -qE -- "$esc_pat" "$OUT" || { ng "$CUR: ESC がエスケープされて出ていません"; sed 's/^/    /' "$OUT" >&2; }
expect_out_line 'r-b[[:space:]]+a\\ b'
expect_out_line 'r-c[[:space:]]+\\\$\\\(touch\\ /tmp/x\\\)'
RT_CACHE="r-a,r-x" RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 0 "route show: グループから外れて、次に戻す対象も示す（書かない）" -- runner route show rt1
expect_out_line 'グループから外れていて、次の up / down / sync で ubuntu-latest へ戻す対象'
expect_out_line '^  r-x$'
no_writes
RT_VARS="r-a=rt1 r-b=rt1 r-c=rt1"
rt 1 "route show: 変数を読めないリポジトリがあれば 1（読めた分は出す）" FAKE_VAR_FAIL=r-b -- runner route show rt1
expect_out_line 'r-a[[:space:]]+rt1'
expect_out_line 'r-b[[:space:]]+\(読めません\)'
rt 2 "route show: selected でなければ 2" FAKE_GROUP_VIS=private -- runner route show rt1
rt 1 "route show: グループを読めなければ 1" FAKE_API_FAIL=groups -- runner route show rt1
no_pat_leak

# ── ユニット・タイマー ──
RUNIT_ROUTE="${DEV_ROUTE_UNIT:-$HERE/dev-route@.service}"
SUNIT_ROUTE="${DEV_ROUTE_SYNC_UNIT:-$HERE/dev-route-sync@.service}"
TIMER_ROUTE="${DEV_ROUTE_TIMER:-$HERE/dev-route-sync@.timer}"
CUR="切り替えのユニット"
runit_has() { grep -qxF -- "$1" "$RUNIT_ROUTE" || ng "切り替えのユニットに「$1」の行がありません（$2）"; }
runit_has 'Type=oneshot' "ExecStart で書いて終わる"
runit_has 'RemainAfterExit=yes' "書いた状態を active で持つ（停止で戻す）"
runit_has 'ExecStart=%h/.local/bin/dev runner route up %i' "起動でラベルへ向ける。%I は - を / へ戻すので使わない"
runit_has 'ExecStopPost=%h/.local/bin/dev runner route down %i --retries 2 --retry-wait 5' "停止で ubuntu-latest へ戻す。起動に失敗したときも動く ExecStopPost にする"
runit_has 'TimeoutStopSec=300' "停止で戻す時間（ロックの待ち・読み取り・やり直し）"
runit_has 'Restart=on-failure' "一時的な失敗（起動直後のネットワーク）はやり直す"
runit_has 'RestartSec=30' "やり直しの間隔"
runit_has 'StartLimitIntervalSec=0' "回線の立ち上がりが遅い日に諦めない"
runit_has 'RestartPreventExitStatus=2' "設定の誤り（2）は起こし直さない"
runit_has 'WantedBy=default.target' "ユーザーのマネージャの起動に付く"
grep -qE '^TimeoutStopSec=[0-9]+' "$RUNIT_ROUTE" || ng "切り替えのユニットに TimeoutStopSec がありません（止めるときに全対象を戻す時間）"
if grep -qE '^[^#]*%I' "$RUNIT_ROUTE"; then ng "切り替えのユニットが %I を使っています（ラベルの - が / に化ける）"; fi
if grep -qE '^ExecStop=' "$RUNIT_ROUTE"; then ng "切り替えのユニットが ExecStop で戻しています（起動に失敗したときは動かない。ExecStopPost にする）"; fi
rpes="$(sed -n 's/^RestartPreventExitStatus=//p' "$RUNIT_ROUTE")"
case " $rpes " in *" 1 "*) ng "切り替えのユニットが 1（一時的な失敗）で起こし直さない設定になっています" ;; esac
CUR="切り替えのそろえ直しのユニット"
sunit_has() { grep -qxF -- "$1" "$SUNIT_ROUTE" || ng "そろえ直しのユニットに「$1」の行がありません（$2）"; }
sunit_has 'Type=oneshot' "タイマーが起こす度に 1 回そろえて終わる"
sunit_has 'ExecStart=%h/.local/bin/dev runner route sync %i' "そろえ直しの口。%I は使わない"
if grep -qE '^\[Install\]' "$SUNIT_ROUTE"; then ng "そろえ直しのユニットが [Install] を持っています（単独で有効にせず、タイマーが起こす）"; fi
if grep -qE '^[^#]*%I' "$SUNIT_ROUTE"; then ng "そろえ直しのユニットが %I を使っています"; fi
CUR="切り替えのそろえ直しのタイマー"
timer_has() { grep -qxF -- "$1" "$TIMER_ROUTE" || ng "タイマーに「$1」の行がありません（$2）"; }
timer_has 'OnBootSec=3min' "起動の 3 分後（ランナーが online になるのを待つ）"
timer_has 'OnUnitActiveSec=10min' "10 分おき"
timer_has 'WantedBy=timers.target' "タイマーとして有効にできる"
if grep -qE '^[^#]*%I' "$TIMER_ROUTE"; then ng "タイマーが %I を使っています"; fi

# ── dev doctor --runner の routes の点検 ──
ALL_UNITS="dev-runner@q1.service dev-route@rt1.service dev-route-sync@rt1.timer"
rt 0 "doctor --runner: routes の行（PAT・グループ・一致・ユニット・タイマー）が全部 OK なら 0" FAKE_ACTIVE_UNITS="$ALL_UNITS" -- doctor --runner q1
expect_out_line '\[OK  \] route rt1: PAT ファイル .*/route-pat（権限 600）'
expect_out_line '\[OK  \] route rt1: グループ my-group を読めて、使えるリポジトリは selected です（対象 3 件）'
expect_out_line '\[OK  \] route rt1: ランナー q1 の組織・group= が routes と一致します'
expect_out_line '\[OK  \] ユニット dev-route@rt1.service: active'
expect_out_line '\[OK  \] タイマー dev-route-sync@rt1.timer: active'
no_pat_leak
rt 3 "doctor --runner: 起動・停止のユニットとタイマーが active でなければ WARN" FAKE_ACTIVE_UNITS="dev-runner@q1.service" -- doctor --runner q1
expect_out_line '\[WARN\] ユニット dev-route@rt1.service: inactive'
expect_out_line '\[WARN\] タイマー dev-route-sync@rt1.timer: inactive'
rt 3 "doctor --runner: タイマーだけ止まっていれば WARN" FAKE_ACTIVE_UNITS="dev-runner@q1.service dev-route@rt1.service" -- doctor --runner q1
expect_out_line '\[WARN\] タイマー dev-route-sync@rt1.timer: inactive'
rt 1 "doctor --runner: route の PAT の権限が緩ければ FAIL" FAKE_ACTIVE_UNITS="dev-runner@q3.service dev-route@rt3.service dev-route-sync@rt3.timer" -- doctor --runner q3
expect_out_line '\[FAIL\] route rt3: PAT ファイルの権限が緩すぎます'
expect_out_line 'route rt3: PAT を使えないため、グループを確かめられません'
no_pat_leak
rt 1 "doctor --runner: route の PAT のファイルが無ければ FAIL" FAKE_ACTIVE_UNITS="dev-runner@q4.service dev-route@rt4.service dev-route-sync@rt4.timer" -- doctor --runner q4
expect_out_line '\[FAIL\] route rt4: PAT ファイルがありません'
rt 1 "doctor --runner: グループの使えるリポジトリが selected でなければ FAIL" FAKE_GROUP_VIS=all FAKE_ACTIVE_UNITS="$ALL_UNITS" -- doctor --runner q1
expect_out_line '\[FAIL\] route rt1: グループ my-group の使えるリポジトリが selected ではありません（all）'
rt 1 "doctor --runner: グループが無ければ FAIL" FAKE_GROUPS=Default FAKE_ACTIVE_UNITS="$ALL_UNITS" -- doctor --runner q1
expect_out_line '\[FAIL\] route rt1: ランナーグループ my-group が組織 my-org にありません'
rt 3 "doctor --runner: グループの一覧を読めなければ WARN" FAKE_API_FAIL=groups FAKE_ACTIVE_UNITS="$ALL_UNITS" -- doctor --runner q1
expect_out_line '\[WARN\] route rt1: グループの一覧を読めませんでした'
rt 1 "doctor --runner: ランナーの group= が routes の行と違えば FAIL" FAKE_GROUPS=Default,other-group,grp2 FAKE_ACTIVE_UNITS="dev-runner@q2.service dev-route@rt2.service dev-route-sync@rt2.timer" -- doctor --runner q2
expect_out_line '\[FAIL\] route rt2: ランナー q2 の組織（my-org）・group=（other-group）が routes の組織（my-org）・group=（grp2）と違います'
rt 1 "doctor --runner: ランナーの組織が routes の行と違えば FAIL" FAKE_ACTIVE_UNITS="dev-runner@q5.service dev-route@rt1.service dev-route-sync@rt1.timer" -- doctor --runner q5
expect_out_line '\[FAIL\] route rt1: ランナー q5 の組織'
printf 'rt1 my-org group=my-group\nrt9 my-org group=my-group\n' >"$WORK/conf/routes-orphan"
rt 3 "doctor --runner: どのランナーも持たないラベルの行は WARN（1 行）" DEV_ROUTES_FILE="$WORK/conf/routes-orphan" FAKE_ACTIVE_UNITS="$ALL_UNITS" -- doctor --runner q1
expect_out_line '\[WARN\] route rt9: runners にこのラベルを持つランナーがありません'
printf 'rt1 my-org group=my-group bogus=1\n' >"$WORK/conf/routes-broken"
rt 1 "doctor --runner: routes を読めなければ FAIL（doctor は止まらず、ほかの点検も出す）" DEV_ROUTES_FILE="$WORK/conf/routes-broken" FAKE_ACTIVE_UNITS="$ALL_UNITS" -- doctor --runner q1
expect_out_line '\[FAIL\] routes を読めません: .*知らないキーです'
expect_out_line '\[OK  \] イメージ dev-runner:local があります'
rt 0 "doctor --runner: routes が無い機械では routes の点検を出さない（従来どおり。0）" DEV_ROUTES_FILE="$WORK/conf/no-such-routes" FAKE_ACTIVE_UNITS="dev-runner@q1.service" -- doctor --runner q1
if grep -q 'route ' "$OUT"; then ng "$CUR: routes が無いのに route の行が出ています"; fi
# route のユニットが有効なのに routes が無い・そのラベルの行が無い
rt 1 "doctor --runner: dev-route@ が enabled で routes が無ければ FAIL（判定は OK にならない）" DEV_ROUTES_FILE="$WORK/conf/no-such-routes" FAKE_ENABLED_UNITS="dev-route@rt1.service" FAKE_ACTIVE_UNITS="dev-runner@q1.service" -- doctor --runner q1
expect_out_line '\[FAIL\] route rt1: ユニット（dev-route@rt1.service）は有効ですが、routes（.*no-such-routes）がありません'
expect_out_line 'systemctl --user disable --now dev-route@rt1.service dev-route-sync@rt1.timer'
if grep -q '判定: OK' "$OUT"; then ng "$CUR: routes が無くユニットが有効なのに判定が OK です"; fi
rt 1 "doctor --runner: dev-route-sync のタイマーだけ active でも routes が無ければ FAIL" DEV_ROUTES_FILE="$WORK/conf/no-such-routes" FAKE_ACTIVE_UNITS="dev-runner@q1.service dev-route-sync@rt1.timer" -- doctor --runner q1
expect_out_line '\[FAIL\] route rt1: ユニット（dev-route-sync@rt1.timer）は有効ですが'
printf 'rt3 my-org group=my-group\n' >"$WORK/conf/routes-other"
rt 1 "doctor --runner: routes にそのラベルの行が無く、ユニットが有効なら FAIL" DEV_ROUTES_FILE="$WORK/conf/routes-other" FAKE_ENABLED_UNITS="dev-route@rt1.service" FAKE_ACTIVE_UNITS="dev-runner@q1.service" -- doctor --runner q1
expect_out_line '\[FAIL\] route rt1: ユニット（dev-route@rt1.service）は有効ですが、routes に rt1 の行がありません'
rt 1 "doctor --runner: enable せず start して failed で止まったユニットも、routes が無ければ FAIL" DEV_ROUTES_FILE="$WORK/conf/no-such-routes" FAKE_FAILED_UNITS="dev-route@rt1.service" FAKE_ACTIVE_UNITS="dev-runner@q1.service" -- doctor --runner q1
expect_out_line '\[FAIL\] route rt1: ユニット（dev-route@rt1.service）は有効ですが'
expect_out_line 'systemctl --user reset-failed dev-route@rt1.service dev-route-sync@rt1.timer'
rt 1 "doctor --runner: activating のユニットも、routes が無ければ FAIL" DEV_ROUTES_FILE="$WORK/conf/no-such-routes" FAKE_ACTIVATING_UNITS="dev-route@rt1.service" FAKE_ACTIVE_UNITS="dev-runner@q1.service" -- doctor --runner q1
expect_out_line '\[FAIL\] route rt1: ユニット（dev-route@rt1.service）は有効ですが'
rt 1 "doctor --runner: enabled-runtime のユニットも、routes が無ければ FAIL" DEV_ROUTES_FILE="$WORK/conf/no-such-routes" FAKE_ENABLED_RUNTIME_UNITS="dev-route@rt1.service" FAKE_ACTIVE_UNITS="dev-runner@q1.service" -- doctor --runner q1
expect_out_line '\[FAIL\] route rt1: ユニット（dev-route@rt1.service）は有効ですが'
expect_out_line '先に routes にその行を戻してから systemctl --user disable --now'
rt 3 "doctor --runner: どのランナーの labels= にも無いラベルの有効なユニットは WARN（1 回）" DEV_ROUTES_FILE="$WORK/conf/no-such-routes" FAKE_ENABLED_UNITS="dev-route-sync@gone.timer" FAKE_ACTIVE_UNITS="dev-runner@q1.service dev-route-sync@gone.timer" -- doctor --runner q1
expect_out_line '\[WARN\] route gone: ユニット dev-route-sync@gone.timer は有効ですが、runners のどのランナーの labels= にもこのラベルがありません'
if [[ "$(grep -c 'route gone' "$OUT")" -ne 1 ]]; then ng "$CUR: どのランナーにも無いラベルの WARN が 1 回ではありません"; fi
expect_out_line 'systemctl --user reset-failed dev-route@gone.service dev-route-sync@gone.timer'
mkdir -p "$WORK/home/.config/systemd/user/default.target.wants"
ln -s ../dev-route@.service "$WORK/home/.config/systemd/user/default.target.wants/dev-route@wantsonly.service"
rt 3 "doctor --runner: wants のリンクだけがあるインスタンス（一覧に出ない）も WARN で拾う" DEV_ROUTES_FILE="$WORK/conf/no-such-routes" FAKE_ACTIVE_UNITS="dev-runner@q1.service" -- doctor --runner q1
expect_out_line '\[WARN\] route wantsonly: ユニット dev-route@wantsonly.service は有効ですが'
rm -rf "$WORK/home/.config/systemd/user/default.target.wants"
rt 0 "doctor --runner: どのランナーの labels= にも無いラベルでも、ユニットが無効なら何も出さない" DEV_ROUTES_FILE="$WORK/conf/no-such-routes" FAKE_ACTIVE_UNITS="dev-runner@q1.service" -- doctor --runner q1
rt 0 "doctor --runner: routes にそのラベルの行が無くても、ユニットが無効なら何も出さない" DEV_ROUTES_FILE="$WORK/conf/routes-other" FAKE_ACTIVE_UNITS="dev-runner@q1.service" -- doctor --runner q1
if grep -q 'route rt1' "$OUT"; then ng "$CUR: ユニットが無効なのに route rt1 の行が出ています"; fi

# ── help ──
run 0 "help runner: route の説明がある" -- -- help runner
expect_out_line '^  dev runner route up[|]down[|]sync[|]show <ラベル>'
expect_out_line 'ACTIONS_RUNS_ON'
expect_out_line 'RestartPreventExitStatus=2'
run 2 "runner: route の引数なしは使い方の誤り" -- -- runner route
expect_err "使い方: dev runner route"
expect_no_calls

# ── self-update: 切り替えのユニットがリリースと違えば、install.sh の再実行を案内する ──
mk_self
printf '[Unit]\nDescription=リリースの切り替えのユニット\n' >"$REL/dev-route@.service"
route_unit_sum="$($sum_cmd "$REL/dev-route@.service" | awk '{ print $1 }')"
printf '{\n  "package": "devcontainer-host",\n  "version": "0.0.0",\n  "checksums": {\n    "dev.sh": "%s",\n    "dev-route@.service": "%s"\n  }\n}\n' "$good_sum" "$route_unit_sum" >"$REL/RELEASE-MANIFEST.json"
mkdir -p "$WORK/home/.config/systemd/user"
printf '[Unit]\nDescription=古い切り替えのユニット\n' >"$WORK/home/.config/systemd/user/dev-route@.service"
run 0 "self-update: 切り替えのユニットがリリースと違えば、install.sh の再実行を案内する（書き換えない）" -- DEV_SELF_PATH="$SELF" FAKE_CURL_DIR="$REL" -- self-update
expect_out_line '置いてある切り替えのユニット（.*dev-route@.service）が、リリース（v0.0.0）の dev-route@.service と違います'
expect_out_line 'install.sh を再実行して切り替えのユニットを更新してください'
[[ "$(cat "$WORK/home/.config/systemd/user/dev-route@.service")" == "$(printf '[Unit]\nDescription=古い切り替えのユニット')" ]] || ng "$CUR: 切り替えのユニットが書き換わっています"
rm -f "$WORK/home/.config/systemd/user/dev-route@.service" "$REL/dev-route@.service"
write_manifest "$good_sum"

if [[ "$fail" -ne 0 ]]; then
  echo "DEVHOST_SELFTEST_FAIL" >&2
  exit 1
fi
echo "[devhost-selftest] $n 件の呼び出しを確かめました"
echo "DEVHOST_SELFTEST_PASS"
