#!/usr/bin/env bash
# install.sh — 外部の機械へ devhost（dev・ユニット・ランナーの Dockerfile・設定の雛形）を入れる。再実行すれば新しい版へ更新する。
#
# dev が無い状態から使うため、dev のサブコマンドではなく独立したスクリプトにしている。
# 取得したものはすべて、同じリリースの RELEASE-MANIFEST.json の checksums と照合する。
# **照合を通らないものは、何も置かない**（置く前にすべて確かめ、外れたら 1 で止まる）。
#
# 使い方:
#   bash install.sh [--version <vX.Y.Z>] [--dry-run]
#
# 入手の手順（このスクリプト自身の照合を含む）は README.md の「install.sh で入れる」。
# curl の出力を bash へ直接渡す形（curl | bash）は勧めない。照合を挟めないため。
set -euo pipefail

PROG="install.sh"
RELEASE_BASE_URL="https://github.com/ojos/devcontainer-host/releases"

# ── ここから ──「dev.sh からの写し」（変えるときは dev.sh と同じ本文に保つ） ───────────
# install.sh は dev.sh が無い状態で動くので、dev.sh から読み込めない。この「ここから」から「写しここまで」の間に
# あるものは、すべて dev.sh の同名のものと同じ本文でなければならない。tests/test-devcontainer-host-install.sh が、
# この間の関数と代入の一覧を取り、その全部を dev.sh と機械で突き合わせる（一覧にないものが混ざっても落ちる）。
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

# ファイルの SHA-256（16 進の小文字 64 桁）を出す。sha256sum が無い環境（macOS）では shasum へ分岐する。
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
# ── 写しここまで ──

# ── 共通 ──────────────────────────────────────────────────────────────────────
die() {
  echo "[$PROG] エラー: $*" >&2
  exit 1
}

usage_error() {
  echo "[$PROG] $*" >&2
  exit 2
}

usage() {
  cat <<'EOF'
install.sh — 外部の機械へ devhost を入れる（再実行すれば新しい版へ更新する）。

使い方:
  bash install.sh [--version <vX.Y.Z>] [--dry-run]

すること:
  1. 公開リリースから RELEASE-MANIFEST.json を取得する（既定は最新。--version でその版に固定する）
  2. 同じリリースの dev.sh・dev-up@.service・dev-runner@.service・dev-route@.service・dev-route-sync@.service・
     dev-route-sync@.timer・runner.Dockerfile・projects.example・runners.example・routes.example を
     取得し、マニフェストの checksums と照合する（dev.sh は devhost の dev.sh の形であることと構文も確かめる）。
     1 つでも外れたら何も置かずに 1 で止まる
  3. dev を ~/.local/bin/dev へ写しで置く（置き換え先がリンク・ディレクトリ・git で追跡されているファイル・devhost の dev.sh でない
     ファイルなら置き換えずに止まる）
  4. dev-up@.service・dev-runner@.service・dev-route@.service・dev-route-sync@.service・dev-route-sync@.timer を
     ~/.config/systemd/user/ へ置き、systemctl --user daemon-reload を呼ぶ
     ランナーのイメージの Dockerfile は ~/.config/dev/runner.Dockerfile へ置く（イメージは dev runner build で作る。自動では作らない）
  5. ~/.config/dev/projects と ~/.config/dev/runners が無ければ、それぞれ projects.example / runners.example から作る
     （あれば決して上書きしない）。routes（ACTIONS_RUNS_ON の切り替えの設定）は、使わない機械もあるので雛形から作らず、
     雛形 routes.example を ~/.config/dev/routes.example へ置く（使うときに routes へ写す）
  6. devcontainer CLI・docker・systemd の有無を確かめ、足りないものと、次にすること（enable-linger・
     プロジェクトごとの enable --now）を案内する。これらは自動では入れない・行わない

オプション:
  --version <vX.Y.Z>   入れる版（既定は最新）
  --dry-run            何も書かず、計画だけを出す（取得と照合は行う）
  -h, --help           この説明

curl と jq と、sha256sum または shasum が要る。
終了コード: 0 = 入れた（または --dry-run の計画を出した） / 1 = 失敗（取得・照合・置き換え先の確認・設置） / 2 = 使い方の誤り
EOF
}

# 置き先の親ディレクトリに書き込めるか（無ければ、いちばん近い既存の祖先を見る）。
# 問題があれば、その説明を標準出力へ出して 1 を返す。実行では置く前に止め、--dry-run では計画に出す。
# 使い方: parent_problem <置き先>
parent_problem() {
  local dst="$1" d
  d="$(dirname "$dst")"
  while [[ ! -e "$d" && "$d" != "/" && "$d" != "." ]]; do d="$(dirname "$d")"; done
  if [[ ! -d "$d" ]]; then
    echo "$dst の親 $d がディレクトリではありません。"
    return 1
  fi
  if [[ ! -w "$d" || ! -x "$d" ]]; then
    echo "$dst の親 $d に書き込めません。"
    return 1
  fi
  return 0
}

# 置き先に対する計画の語を返す:
#   new（無い）/ same（同じ内容で、権限も同じ）/ mode（同じ内容だが、権限が違う）/ update（違う内容）。
# 使い方: state_of <元> <置き先> <モード>
state_of() {
  local src="$1" dst="$2" mode="$3"
  if [[ ! -e "$dst" ]]; then echo new
  elif ! cmp -s "$src" "$dst"; then echo update
  elif [[ -n "$(find "$dst" -maxdepth 0 -perm "$mode" 2>/dev/null)" ]]; then echo same
  else echo mode
  fi
}

# 置くものを、置き先と同じディレクトリの一時ファイルへ用意する（まだ置き先には触れない）。
# 全部を用意してから、最後にまとめて mv する（途中で失敗して一部だけが更新される窓を小さくする）。
STAGED_TMP=()
STAGED_DST=()
STAGED_NOTE=()
# 使い方: stage_file <元> <置き先> <モード> <置いたあとの表示>
stage_file() {
  local src="$1" dst="$2" mode="$3" note="$4" dir tmp
  dir="$(dirname "$dst")"
  if ! mkdir -p "$dir"; then discard_staged; die "$dir を作れません。何も置いていません。"; fi
  if ! tmp="$(mktemp "$dir/.install.XXXXXX")"; then discard_staged; die "$dir に一時ファイルを作れません。何も置いていません。"; fi
  STAGED_TMP+=("$tmp")
  STAGED_DST+=("$dst")
  STAGED_NOTE+=("$note")
  if ! cp "$src" "$tmp" || ! chmod "$mode" "$tmp"; then
    discard_staged
    die "$dst の一時ファイルを用意できませんでした。何も置いていません。"
  fi
}

discard_staged() {
  local t
  for t in ${STAGED_TMP[@]+"${STAGED_TMP[@]}"}; do rm -f "$t"; done
  STAGED_TMP=()
}

# 用意した一時ファイルを、順に mv で置く。途中で失敗したら、置いたものと失敗した箇所を示して 1 で止まる。
commit_staged() {
  local i n placed=""
  n=${#STAGED_TMP[@]}
  i=0
  while [[ $i -lt $n ]]; do
    if mv -f "${STAGED_TMP[$i]}" "${STAGED_DST[$i]}"; then
      placed="$placed ${STAGED_DST[$i]}"
      echo "[$PROG]   ${STAGED_NOTE[$i]}: ${STAGED_DST[$i]}"
    else
      local j=$((i + 1))
      while [[ $j -lt $n ]]; do rm -f "${STAGED_TMP[$j]}"; j=$((j + 1)); done
      rm -f "${STAGED_TMP[$i]}"
      echo "[$PROG] エラー: ${STAGED_DST[$i]} を置けませんでした。" >&2
      echo "[$PROG]   ここまでに置いたもの:${placed:- なし}" >&2
      echo "[$PROG]   置けなかったもの: ${STAGED_DST[$i]} 以降。原因を直して、install.sh を再実行してください（冪等です）。" >&2
      exit 1
    fi
    i=$((i + 1))
  done
}

IT_TMP=""
cleanup() { [[ -z "$IT_TMP" ]] || rm -rf "$IT_TMP"; }

main() {
  local version="" dry_run=0 a
  while [[ $# -gt 0 ]]; do
    a="$1"
    case "$a" in
      --version)
        [[ $# -ge 2 && -n "$2" ]] || usage_error "--version には版が要ります（空は不可。使い方: bash install.sh [--version <vX.Y.Z>] [--dry-run]）"
        version="$2"
        shift
        ;;
      --dry-run) dry_run=1 ;;
      -h | --help)
        usage
        return 0
        ;;
      *) usage_error "使い方: bash install.sh [--version <vX.Y.Z>] [--dry-run]" ;;
    esac
    shift
  done
  if [[ -n "$version" && ! "$version" =~ $SEMVER_RE ]]; then
    usage_error "版は vX.Y.Z の形で指定します（URL の一部になるため）: $version"
  fi

  # 取得と照合に要る道具。これが無いと照合できないので、何も始めずに止まる。
  command -v curl >/dev/null 2>&1 || die "curl を入れてください（取得に使います）。何も置いていません。"
  command -v jq >/dev/null 2>&1 || die "jq を入れてください（マニフェストを読みます）。何も置いていません。"
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    die "sha256sum または shasum が要ります（照合に使います）。何も置いていません。"
  fi
  [[ -n "${HOME:-}" ]] || die "HOME が設定されていません。何も置いていません。"

  local conf_home bin_path unit_path projects_path runner_unit_path runner_df_path runners_path
  local route_unit_path route_sync_unit_path route_timer_path routes_example_path
  conf_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  bin_path="$HOME/.local/bin/dev"
  unit_path="$conf_home/systemd/user/dev-up@.service"
  projects_path="$conf_home/dev/projects"
  runner_unit_path="$conf_home/systemd/user/dev-runner@.service"
  runner_df_path="$conf_home/dev/runner.Dockerfile"
  runners_path="$conf_home/dev/runners"
  route_unit_path="$conf_home/systemd/user/dev-route@.service"
  route_sync_unit_path="$conf_home/systemd/user/dev-route-sync@.service"
  route_timer_path="$conf_home/systemd/user/dev-route-sync@.timer"
  routes_example_path="$conf_home/dev/routes.example"

  # 置き換え先の確認。取得より先に行う（置けないと分かっているのに取りにいかない）。
  local why
  if [[ -e "$bin_path" || -L "$bin_path" ]]; then
    why="$(dev_target_refusal "$bin_path")" || die "$why 何も置いていません。"
  fi
  # 既にあるものは、通常のファイルでなければ、比較（cmp）より前に止める（名前付きパイプなどを読むと止まるため）。
  if [[ -L "$unit_path" ]]; then
    die "置き換え先 $unit_path はリンクです。リンクの先は書き換えません。何も置いていません。"
  fi
  if [[ -e "$unit_path" && ! -f "$unit_path" ]]; then
    die "置き換え先 $unit_path は通常のファイルではありません（ディレクトリ、名前付きパイプなど）。何も置いていません。"
  fi
  local rp
  for rp in "$runner_unit_path" "$runner_df_path" "$route_unit_path" "$route_sync_unit_path" "$route_timer_path" "$routes_example_path"; do
    if [[ -L "$rp" ]]; then
      die "置き換え先 $rp はリンクです。リンクの先は書き換えません。何も置いていません。"
    fi
    if [[ -e "$rp" && ! -f "$rp" ]]; then
      die "置き換え先 $rp は通常のファイルではありません（ディレクトリ、名前付きパイプなど）。何も置いていません。"
    fi
  done

  # projects は、通常のファイル（リンクなら実体が通常のファイル）でなければ、「あるので触らない」にせず止める
  # （dev は設定ファイルを -f で読むので、ディレクトリやリンク切れでは「設定ファイルがありません」で止まる）。
  if [[ -e "$projects_path" || -L "$projects_path" ]]; then
    [[ -f "$projects_path" ]] || die "$projects_path が通常のファイルではありません（ディレクトリ、またはリンク切れ）。dev は設定ファイルとして読めません。何も置いていません。"
  fi
  if [[ -e "$runners_path" || -L "$runners_path" ]]; then
    [[ -f "$runners_path" ]] || die "$runners_path が通常のファイルではありません（ディレクトリ、またはリンク切れ）。dev は設定ファイルとして読めません。何も置いていません。"
  fi
  # すべての置き場所の親に書き込めるかを、何かを置く前に検査する。実行では見つかった時点で止まる。
  # --dry-run では止めずに集め、計画に「実行すると書き込めずに止まる」と出す（計画を出せないほうが困るため）。
  local write_problems="" t msg
  for t in "$bin_path" "$unit_path" "$runner_unit_path" "$runner_df_path" "$route_unit_path" "$route_sync_unit_path" "$route_timer_path" "$routes_example_path" "$projects_path" "$runners_path"; do
    [[ ( "$t" != "$projects_path" && "$t" != "$runners_path" ) || ! -e "$t" ]] || continue
    if ! msg="$(parent_problem "$t")"; then write_problems="${write_problems}${msg}"$'\n'; fi
  done
  if [[ -n "$write_problems" && "$dry_run" -eq 0 ]]; then
    die "${write_problems%%$'\n'*} 何も置いていません。"
  fi

  IT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/devhost-install.XXXXXX")" || die "作業ディレクトリを作れません。何も置いていません。"
  trap cleanup EXIT

  # マニフェストだけを最新の取得先から取り、そこに書かれた版で残りを取る
  # （latest を何度も引くと、間にリリースが出たとき、別の版の組み合わせになりうる）。
  local mbase base
  if [[ -n "$version" ]]; then mbase="$RELEASE_BASE_URL/download/$version"; else mbase="$RELEASE_BASE_URL/latest/download"; fi
  base="$mbase"
  echo "[$PROG] 取得先: $mbase"
  curl -fsSL "$mbase/RELEASE-MANIFEST.json" -o "$IT_TMP/RELEASE-MANIFEST.json" || die "RELEASE-MANIFEST.json を取得できません。何も置いていません。"
  jq -e 'type == "object"' "$IT_TMP/RELEASE-MANIFEST.json" >/dev/null 2>&1 || die "RELEASE-MANIFEST.json を読めません。何も置いていません。"
  local mver pkg
  pkg="$(jq -r '.package // empty' "$IT_TMP/RELEASE-MANIFEST.json")" || die "RELEASE-MANIFEST.json を読めません。何も置いていません。"
  if [[ -n "$pkg" && "$pkg" != "devcontainer-host" ]]; then
    die "マニフェストが devcontainer-host のものではありません（package: $pkg）。何も置いていません。"
  fi
  mver="$(jq -r '.version // empty' "$IT_TMP/RELEASE-MANIFEST.json")" || die "RELEASE-MANIFEST.json を読めません。何も置いていません。"
  if [[ -n "$mver" ]]; then
    [[ "$mver" == v* ]] || mver="v$mver"
  fi
  if [[ -z "$version" ]]; then
    [[ "$mver" =~ $SEMVER_RE ]] || die "最新の版をマニフェストから読めません（version: $mver）。--version vX.Y.Z で版を指定してください。何も置いていません。"
    version="$mver"
    base="$RELEASE_BASE_URL/download/$version"
    echo "[$PROG] 最新の版: $version（残りは $base から取る）"
  elif [[ -n "$mver" && "$mver" != "$version" ]]; then
    die "マニフェストの版（$mver）が指定した版（$version）と違います。何も置いていません。"
  fi

  # 資産を取得して照合する。個別の資産として配られているので、アーカイブは取らない。
  local name want got has_route=1 names
  # 変数の切り替え（dev-route）の 4 つは v0.5.0 から配る。それより前の版のマニフェストには無いので、
  # 4 つとも無ければ取らずに進める（古い版へ固定して入れ直す・戻すことができるように）。一部だけ無いのは食い違いとして止める。
  if ! jq -e '.checksums["dev-route@.service"]' "$IT_TMP/RELEASE-MANIFEST.json" >/dev/null 2>&1; then
    if jq -e '.checksums | has("dev-route-sync@.service") or has("dev-route-sync@.timer") or has("routes.example")' "$IT_TMP/RELEASE-MANIFEST.json" >/dev/null 2>&1; then
      die "RELEASE-MANIFEST.json に dev-route@.service のハッシュがありません（ほかの dev-route の資産はあります）。何も置いていません。"
    fi
    has_route=0
  fi
  names="dev.sh dev-up@.service dev-runner@.service runner.Dockerfile projects.example runners.example"
  [[ "$has_route" -eq 0 ]] || names="$names dev-route@.service dev-route-sync@.service dev-route-sync@.timer routes.example"
  for name in $names; do
    want="$(jq -r --arg n "$name" '.checksums[$n] // empty' "$IT_TMP/RELEASE-MANIFEST.json")" || die "RELEASE-MANIFEST.json を読めません。何も置いていません。"
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || die "RELEASE-MANIFEST.json に $name のハッシュ（checksums の $name）がありません。何も置いていません。"
    curl -fsSL "$base/$name" -o "$IT_TMP/$name" || die "$name を取得できません。何も置いていません。"
    got="$(sha256_of "$IT_TMP/$name")" || die "ハッシュを計算できません。何も置いていません。"
    [[ "$got" == "$want" ]] || die "$name のハッシュがマニフェストと合いません（マニフェスト $want / 実際 $got）。何も置いていません。"
    echo "[$PROG] ハッシュが合いました: $name"
  done
  is_devhost_dev_sh "$IT_TMP/dev.sh" || die "取得した dev.sh が devhost の dev.sh だと確かめられません（1 行目が bash の shebang、2 行目が「# dev — 」で始まる形ではない）。何も置いていません。"
  "${BASH:-bash}" -n "$IT_TMP/dev.sh" || die "取得した dev.sh に構文の誤りがあります。何も置いていません。"
  grep -q '^ExecStart=.*dev supervise' "$IT_TMP/dev-up@.service" || die "取得した dev-up@.service が devhost のユニットだと確かめられません（ExecStart に dev supervise がありません）。何も置いていません。"
  grep -q '^ExecStart=.*dev runner run' "$IT_TMP/dev-runner@.service" || die "取得した dev-runner@.service が devhost のユニットだと確かめられません（ExecStart に dev runner run がありません）。何も置いていません。"
  [[ "$has_route" -eq 0 ]] || grep -q '^ExecStart=.*dev runner route up' "$IT_TMP/dev-route@.service" || die "取得した dev-route@.service が devhost のユニットだと確かめられません（ExecStart に dev runner route up がありません）。何も置いていません。"
  [[ "$has_route" -eq 0 ]] || grep -q '^ExecStart=.*dev runner route sync' "$IT_TMP/dev-route-sync@.service" || die "取得した dev-route-sync@.service が devhost のユニットだと確かめられません（ExecStart に dev runner route sync がありません）。何も置いていません。"
  [[ "$has_route" -eq 0 ]] || grep -q '^OnUnitActiveSec=' "$IT_TMP/dev-route-sync@.timer" || die "取得した dev-route-sync@.timer が devhost のタイマーだと確かめられません（OnUnitActiveSec がありません）。何も置いていません。"
  grep -q '^FROM ghcr.io/actions/actions-runner' "$IT_TMP/runner.Dockerfile" || die "取得した runner.Dockerfile が devhost のランナーの Dockerfile だと確かめられません（FROM に公式のランナーのイメージがありません）。何も置いていません。"

  local dev_state unit_state proj_state runner_unit_state runner_df_state runners_state
  local route_unit_state route_sync_unit_state route_timer_state routes_example_state
  dev_state="$(state_of "$IT_TMP/dev.sh" "$bin_path" 0755)"
  unit_state="$(state_of "$IT_TMP/dev-up@.service" "$unit_path" 0644)"
  runner_unit_state="$(state_of "$IT_TMP/dev-runner@.service" "$runner_unit_path" 0644)"
  runner_df_state="$(state_of "$IT_TMP/runner.Dockerfile" "$runner_df_path" 0644)"
  if [[ "$has_route" -eq 1 ]]; then
    route_unit_state="$(state_of "$IT_TMP/dev-route@.service" "$route_unit_path" 0644)"
    route_sync_unit_state="$(state_of "$IT_TMP/dev-route-sync@.service" "$route_sync_unit_path" 0644)"
    route_timer_state="$(state_of "$IT_TMP/dev-route-sync@.timer" "$route_timer_path" 0644)"
    routes_example_state="$(state_of "$IT_TMP/routes.example" "$routes_example_path" 0644)"
  else
    # この版には無いので、置かない（置いてあるものにも触らない）。
    route_unit_state=same route_sync_unit_state=same route_timer_state=same routes_example_state=same
  fi
  if [[ -e "$projects_path" || -L "$projects_path" ]]; then proj_state=keep; else proj_state=new; fi
  if [[ -e "$runners_path" || -L "$runners_path" ]]; then runners_state=keep; else runners_state=new; fi

  describe() { # $1 = 状態の語, $2 = 置き先
    case "$1" in
      new) echo "新規に置く: $2" ;;
      same) echo "すでにこの版（置き換えない）: $2" ;;
      update) echo "新しい版へ置き換える: $2" ;;
      mode) echo "内容は同じだが権限が違うので、権限を直す: $2" ;;
      keep) echo "あるので触らない（上書きしない）: $2" ;;
    esac
  }

  echo "[$PROG] 計画（版 $version）:"
  echo "[$PROG]   dev: $(describe "$dev_state" "$bin_path")"
  echo "[$PROG]   ユニット: $(describe "$unit_state" "$unit_path")"
  echo "[$PROG]   ランナーのユニット: $(describe "$runner_unit_state" "$runner_unit_path")"
  echo "[$PROG]   ランナーの Dockerfile: $(describe "$runner_df_state" "$runner_df_path")"
  if [[ "$has_route" -eq 1 ]]; then
    echo "[$PROG]   変数の切り替えのユニット: $(describe "$route_unit_state" "$route_unit_path")"
    echo "[$PROG]   変数の切り替えのそろえ直しのユニット: $(describe "$route_sync_unit_state" "$route_sync_unit_path")"
    echo "[$PROG]   変数の切り替えのそろえ直しのタイマー: $(describe "$route_timer_state" "$route_timer_path")"
    echo "[$PROG]   routes の雛形: $(describe "$routes_example_state" "$routes_example_path")"
  else
    echo "[$PROG]   変数の切り替え（dev-route）: この版には無いので置かない"
  fi
  if [[ "$proj_state" == "new" ]]; then
    echo "[$PROG]   projects: 雛形から作る: $projects_path"
  else
    echo "[$PROG]   projects: $(describe keep "$projects_path")"
  fi
  if [[ "$runners_state" == "new" ]]; then
    echo "[$PROG]   runners: 雛形から作る: $runners_path"
  else
    echo "[$PROG]   runners: $(describe keep "$runners_path")"
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    while IFS= read -r msg; do
      [[ -z "$msg" ]] || echo "[$PROG] 注意: 実行すると、書き込めずに止まります: $msg"
    done <<EOF_PROBLEMS
$write_problems
EOF_PROBLEMS
    echo "[$PROG] --dry-run のため、何も置いていません。"
  else
    # 全部の一時ファイルを用意してから、まとめて置く。
    local note
    if [[ "$dev_state" != "same" ]]; then
      if [[ "$dev_state" == "mode" ]]; then note="権限を直しました"; else note="置きました"; fi
      stage_file "$IT_TMP/dev.sh" "$bin_path" 0755 "$note"
    fi
    if [[ "$unit_state" != "same" ]]; then
      if [[ "$unit_state" == "mode" ]]; then note="権限を直しました"; else note="置きました"; fi
      stage_file "$IT_TMP/dev-up@.service" "$unit_path" 0644 "$note"
    fi
    if [[ "$runner_unit_state" != "same" ]]; then
      if [[ "$runner_unit_state" == "mode" ]]; then note="権限を直しました"; else note="置きました"; fi
      stage_file "$IT_TMP/dev-runner@.service" "$runner_unit_path" 0644 "$note"
    fi
    if [[ "$runner_df_state" != "same" ]]; then
      if [[ "$runner_df_state" == "mode" ]]; then note="権限を直しました"; else note="置きました"; fi
      stage_file "$IT_TMP/runner.Dockerfile" "$runner_df_path" 0644 "$note"
    fi
    if [[ "$route_unit_state" != "same" ]]; then
      if [[ "$route_unit_state" == "mode" ]]; then note="権限を直しました"; else note="置きました"; fi
      stage_file "$IT_TMP/dev-route@.service" "$route_unit_path" 0644 "$note"
    fi
    if [[ "$route_sync_unit_state" != "same" ]]; then
      if [[ "$route_sync_unit_state" == "mode" ]]; then note="権限を直しました"; else note="置きました"; fi
      stage_file "$IT_TMP/dev-route-sync@.service" "$route_sync_unit_path" 0644 "$note"
    fi
    if [[ "$route_timer_state" != "same" ]]; then
      if [[ "$route_timer_state" == "mode" ]]; then note="権限を直しました"; else note="置きました"; fi
      stage_file "$IT_TMP/dev-route-sync@.timer" "$route_timer_path" 0644 "$note"
    fi
    if [[ "$routes_example_state" != "same" ]]; then
      if [[ "$routes_example_state" == "mode" ]]; then note="権限を直しました"; else note="置きました"; fi
      stage_file "$IT_TMP/routes.example" "$routes_example_path" 0644 "$note"
    fi
    if [[ "$proj_state" == "new" ]]; then stage_file "$IT_TMP/projects.example" "$projects_path" 0644 "置きました"; fi
    if [[ "$runners_state" == "new" ]]; then stage_file "$IT_TMP/runners.example" "$runners_path" 0644 "置きました"; fi
    commit_staged
    echo "[$PROG] 置き終えました。"
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl --user daemon-reload; then
        echo "[$PROG] systemctl --user daemon-reload を呼びました。"
      else
        echo "[$PROG] 警告: systemctl --user daemon-reload に失敗しました（ユーザーのマネージャに届かない端末かもしれません）。ログインし直すか、あとで手で実行してください。" >&2
      fi
    fi
  fi

  report_next_steps "$dry_run" "$dev_state" "$unit_state" "$proj_state" "$bin_path" "$projects_path" "$runner_df_state"
}

# 足りないものと、次にすること（自動では行わない）を案内する。
report_next_steps() {
  local dry_run="$1" dev_state="$2" unit_state="$3" proj_state="$4" bin_path="$5" projects_path="$6" runner_df_state="${7:-same}"
  echo "[$PROG] 次にすること（自動では行いません）:"
  if ! command -v devcontainer >/dev/null 2>&1 && [[ ! -x "$HOME/.devcontainers/bin/devcontainer" && ! -x "$HOME/.local/bin/devcontainer" ]]; then
    echo "[$PROG]   - devcontainer CLI がありません。README.md の「devcontainer CLI を入れる」の手順で入れてください。"
  fi
  command -v docker >/dev/null 2>&1 || echo "[$PROG]   - docker がありません。入れて、利用者を docker グループへ足してください。"
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "[$PROG]   - systemd（systemctl）がありません。ユニットで常駐させる使い方はできません（dev の手動の操作は使えます）。"
  fi
  case ":${PATH:-}:" in
    *":$(dirname "$bin_path"):"*) ;;
    *) echo "[$PROG]   - $(dirname "$bin_path") が PATH にありません。PATH へ足してください。" ;;
  esac
  if [[ "$proj_state" == "new" && "$dry_run" -eq 0 ]]; then
    echo "[$PROG]   - $projects_path に、名前と絶対パスを書いてください（雛形を置きました）。"
  elif [[ "$proj_state" == "new" ]]; then
    echo "[$PROG]   - 入れたあと、$projects_path に名前と絶対パスを書いてください。"
  fi
  echo "[$PROG]   - ログインしていない間も動かすなら: sudo loginctl enable-linger \"\$USER\""
  echo "[$PROG]   - 常駐させるプロジェクトごとに: systemctl --user enable --now dev-up@<名前>.service"
  echo "[$PROG]   - 自前のランナーを使うなら（README.md の「自前のランナー」）: runners と PAT のファイル（権限 600）を書き、dev runner build でイメージを作り、systemctl --user enable --now dev-runner@<名前>.service"
  echo "[$PROG]   - 自前のランナーの出口の規則は root で入れます（入れないと dev runner run は起動しません。LAN に届いてよいランナーは runners で lan=allow）: dev runner net script | sudo install -m 755 /dev/stdin /usr/local/sbin/dev-runner-net、dev runner net unit | sudo install -m 644 /dev/stdin /etc/systemd/system/dev-runner-net.service、sudo systemctl daemon-reload && sudo systemctl enable --now dev-runner-net.service"
  echo "[$PROG]   - ランナーが動けるあいだだけ ACTIONS_RUNS_ON をランナーのラベルへ向けるなら（README.md の「自前のランナー」の「変数の切り替え」。導入の順序があります。変数を先に ubuntu-latest へ逃がし、ランナーを起こして確かめてから）: routes.example を routes へ写して書き、PAT のファイル（権限 600。ランナーの登録用とは別）を置き、dev runner route show <ラベル> で読めるか確かめ、systemctl --user enable --now dev-route@<ラベル>.service dev-route-sync@<ラベル>.timer"
  if [[ "$runner_df_state" == "update" ]]; then
    if [[ "$dry_run" -eq 1 ]]; then
      echo "[$PROG]   - 実行すると、ランナーの Dockerfile を更新します。実行したあとに、dev runner build でイメージを作り直し、動いているランナーのユニットを起こし直してください。"
    else
      echo "[$PROG]   - ランナーの Dockerfile を更新しました。dev runner build でイメージを作り直し、動いているランナーのユニットを起こし直してください。"
    fi
  fi
  if [[ "$dev_state" == "update" || "$unit_state" == "update" ]]; then
    if [[ "$dry_run" -eq 1 ]]; then
      echo "[$PROG]   - 実行すると dev かユニットのファイルを更新します。動いているユニットは起こし直すまで古いままなので、実行したあとに起こし直しを案内します。"
    else
      echo "[$PROG]   - すでに動いているユニットは、起こし直すまで古い版（dev またはユニットの定義）のまま動きます。dev restart <名前>（コンテナも再起動します）か systemctl --user restart dev-up@<名前>.service で起こし直してください。"
    fi
  fi
}

main "$@"
