#!/usr/bin/env bash
# check-git-config.sh — エージェントに任意のコードを実行させうる git の設定を検出して知らせる
#
# 位置づけ:
#   リポジトリ内の git の設定（.git/config と、それが includeIf などで読み込む先、および
#   worktree の設定）は、clone したリポジトリや、エージェントが書き換えうる設定ファイルの
#   一部である。ここへ core.fsmonitor などを仕込まれると、エージェントが git を呼んだ瞬間に
#   任意のコードが実行される（サンドボックスも承認も通らない）。このスクリプトは、そのような
#   キーが設定されていないかを**読み取りだけで**調べ、あれば知らせる。拒否はしない。
#
# 検出するキー（大文字小文字を区別しない）:
#   core.fsmonitor / core.hooksPath / core.sshCommand / core.askPass / core.gitProxy / core.editor
#   sequence.editor / credential.helper / credential.<URL>.helper
#   gpg.program / gpg.<形式>.program
#   diff.external / diff.<名前>.textconv / diff.<名前>.command
#   filter.<名前>.clean / smudge / process
#   merge.<名前>.driver
#   remote.<名前>.uploadpack / remote.<名前>.receivepack
#   （core.fsmonitor の値が真偽値・整数のときは、組み込みのデーモンの指定でコマンドではない
#   ので検出しない）
#
# 範囲: local（--local。--includes で includeIf の先まで）と worktree（--worktree。
#   extensions.worktreeConfig があるときだけ）。global と system は対象にしない。
#
# 安全に調べる: `git config --list`・`git rev-parse`・`git cat-file` だけを使う。fsmonitor を
#   起動しうる git のコマンド（status / diff / ls-files など）は使わない。設定は NUL 区切り（-z）で
#   読む。値には改行を含められるので、行で分けると 1 つの値を別々の設定として読み違える。
#
# 許可の一覧: リポジトリの根の `.git-config-allow` の、**コミット済み（HEAD）の中身**。作業ツリーの
#   ファイルや、追跡していないファイルは読まない（差分にもレビューにも現れないまま、検査を
#   黙らせられるため）。textconv などのフィルターを通らないよう `git cat-file blob` で読む。
#   1 行が `キー=値` の完全一致
#   （キーは大文字小文字を区別しない。値は完全一致）。`#` から始まる行と空行は無視する。
#   husky が立てる core.hooksPath のように、正当に使っているものを黙らせるために使う。
#   値のないキーは `キー=`（右辺が空）と書く。照合はキーと値だけで、どのファイルの設定かは
#   見ない（取り込み先に同じキーと値を置かれても黙る。限界として README に書いている）。
#
# 使い方:
#   bash scripts/check-git-config.sh          検出（キー・値・設定のある場所）を標準出力へ出す
#   bash scripts/check-git-config.sh --hook   SessionStart のフック用。種類と件数だけを出し、何があっても 0 で終わる
#   bash scripts/check-git-config.sh --summary 種類と件数だけを出し、終了コードは通常どおり（doctor.sh が使う）
#
# --hook / --summary の出力は、エージェントの会話の文脈に入りうる（SessionStart、エージェントが
#   doctor.sh を実行したとき）。設定の値・<名前>・取り込み先の
#   パスは、設定を仕込んだ側が自由に書ける文字列なので、**文脈へ出さない**（指示に見える文を
#   値に仕込めば、フックの報告の体裁でエージェントへ届くため）。検出したキーの種類（決まった
#   表記）と件数だけを出し、詳細は手で実行して確かめるよう案内する。判定できなかったことも、
#   決まった文言で文脈へ出す（黙ると、問題が無い状態と区別できない）。
#
# 終了コード: 0 = 該当なし（またはすべて許可済み） / 1 = 検出 / 2 = 判定できない
# bash と git だけで動く（macOS の bash 3.2 でも動く。tr などの外部コマンドも使わない）。
#
# 限界: 引数なしの実行は、値と取り出し元をそのまま出す（人が確かめるため）。エージェントに
#   実行させると、その出力は文脈に入る。

set -uo pipefail

ALLOW_FILE_NAME=".git-config-allow"
SUMMARY=0
HOOK=0
case "${1:-}" in
  --hook) SUMMARY=1; HOOK=1 ;;
  --summary) SUMMARY=1 ;;
  "") ;;
  *)
    echo "usage: bash scripts/check-git-config.sh [--hook|--summary]" >&2
    exit 2
    ;;
esac

# キー（git config --list の表記。節名と変数名は小文字）から、検出の種類を決まった表記で
# 返す。対象でなければ何も出さない。<名前> の部分は仕込んだ側が書ける文字列なので、
# 種類の表記には含めない。
kind_of() {
  case "${1}" in
    core.fsmonitor | core.hookspath | core.sshcommand | core.askpass | core.gitproxy | core.editor | \
      sequence.editor | credential.helper | gpg.program | diff.external)
      printf '%s' "${1}"
      ;;
    credential.*.helper) printf 'credential.<URL>.helper' ;;
    gpg.*.program) printf 'gpg.<形式>.program' ;;
    diff.*.textconv) printf 'diff.<名前>.textconv' ;;
    diff.*.command) printf 'diff.<名前>.command' ;;
    filter.*.clean) printf 'filter.<名前>.clean' ;;
    filter.*.smudge) printf 'filter.<名前>.smudge' ;;
    filter.*.process) printf 'filter.<名前>.process' ;;
    merge.*.driver) printf 'merge.<名前>.driver' ;;
    remote.*.uploadpack) printf 'remote.<名前>.uploadpack' ;;
    remote.*.receivepack) printf 'remote.<名前>.receivepack' ;;
  esac
}

# core.fsmonitor の値が、組み込みのデーモンの指定（真偽値・整数）か。git は整数も
# 真偽値として読む。
is_builtin_fsmonitor() {
  local v="${1}" r=1
  shopt -s nocasematch
  case "$v" in true | false | yes | no | on | off | "") r=0 ;; esac
  shopt -u nocasematch
  [[ "$v" =~ ^-?[0-9]+$ ]] && r=0
  return "$r"
}

# 許可の一覧（ALLOW_LINES。`キー=値` の改行区切り）に、キー（大文字小文字を区別しない）と
# 値（完全一致）が載っているか。
ALLOW_LINES=""
is_allowed() {
  local key="${1}" val="${2}" line akey aval r=1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    akey="${line%%=*}"
    aval=""
    [[ "$line" == *=* ]] && aval="${line#*=}"
    [[ "$aval" == "$val" ]] || continue
    shopt -s nocasematch
    [[ "$akey" == "$key" ]] && r=0
    shopt -u nocasematch
    [[ "$r" -eq 0 ]] && break
  done <<<"$ALLOW_LINES"
  return "$r"
}

# 判定の本体。検出を標準出力へ出し（--hook / --summary では出さない）、終了コードを返す。
# 検出した種類を KINDS（重複なし、「, 」区切り）に、件数を FOUND に残す。
KINDS=""
FOUND=0
run_check() {
  if ! command -v git >/dev/null 2>&1; then
    echo "[check-git-config] git が見つかりません。判定できません。" >&2
    return 2
  fi
  local root
  if ! root="$(git rev-parse --show-toplevel 2>/dev/null)" || [[ -z "$root" ]]; then
    echo "[check-git-config] git のリポジトリではありません。判定できません。" >&2
    return 2
  fi
  # 読めるかを先に確かめる（下の -z の読み取りはプロセス置換なので、失敗を拾えない）。
  # 引数は下の読み取りとそろえる（--includes が無いと、取り込み先だけが壊れているときに
  # 確認だけが通り、読み取りの失敗が黙って「該当なし」になる）。
  if ! git config --local --list --includes >/dev/null 2>&1; then
    echo "[check-git-config] git の設定を読めませんでした。判定できません。" >&2
    return 2
  fi

  # 許可の一覧は、コミット済み（HEAD）の中身だけを読む。
  ALLOW_LINES=""
  if git cat-file -e "HEAD:${ALLOW_FILE_NAME}" 2>/dev/null; then
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      case "$line" in "" | "#"*) continue ;; esac
      ALLOW_LINES="${ALLOW_LINES}${line}"$'\n'
    done < <(git cat-file blob "HEAD:${ALLOW_FILE_NAME}" 2>/dev/null)
  fi

  local origin kv key val kind worktree=0 pass
  for pass in local worktree; do
    if [[ "$pass" == worktree ]]; then
      # extensions.worktreeConfig があるときだけ、local と別のファイル（config.worktree）を
      # 読む（値の真偽は git の読み方が広いので見ない）。無ければ --worktree は local と同じ
      # ものを読み直すだけなので、起動の経路で git を余計に起こさない。
      [[ "$worktree" -eq 1 ]] || break
      if ! git config --worktree --list --includes >/dev/null 2>&1; then
        echo "[check-git-config] worktree の git の設定を読めませんでした。判定できません。" >&2
        return 2
      fi
    fi
    # -z の形: <origin>NUL<key>LF<value>NUL（値の無いキーは <key>NUL）
    while IFS= read -r -d '' origin && IFS= read -r -d '' kv; do
      key="${kv%%$'\n'*}"
      val=""
      [[ "$kv" == *$'\n'* ]] && val="${kv#*$'\n'}"
      [[ "$key" == extensions.worktreeconfig ]] && worktree=1
      # git config --list は節名と変数名を小文字で出す（大文字小文字が残るのは
      # diff.<名前> などの <名前> だけ）。そのため照合は $key のままで足りる。
      kind="$(kind_of "$key")"
      [[ -n "$kind" ]] || continue
      if [[ "$kind" == core.fsmonitor ]] && is_builtin_fsmonitor "$val"; then
        continue
      fi
      is_allowed "$key" "$val" && continue
      # 重複は取り除かない。worktree の設定は local と別のファイルだけを読むので重ならず、
      # 改行を含められる値で重複を判定すると、値に別の設定の記録を埋め込んで、その設定を
      # 要約から消せてしまう。
      if [[ "$FOUND" -eq 0 && "$SUMMARY" -eq 0 ]]; then
        echo "[check-git-config] 任意のコードを実行させうる git の設定があります（エージェントが git を呼ぶと実行されうる）:"
      fi
      FOUND=$((FOUND + 1))
      case ", ${KINDS}, " in *", ${kind}, "*) ;; *) KINDS="${KINDS:+$KINDS, }$kind" ;; esac
      [[ "$SUMMARY" -eq 1 ]] || echo "  ${key}=${val}   (${origin})"
    done < <(git config "--${pass}" --list --show-origin --includes -z 2>/dev/null)
  done

  if [[ "$FOUND" -gt 0 ]]; then
    [[ "$SUMMARY" -eq 1 ]] || echo "[check-git-config] 心当たりが無ければ設定を確認してください。正当な設定は、リポジトリの根の ${ALLOW_FILE_NAME} へ『キー=値』の行で書いてコミットすると知らせなくなります。"
    return 1
  fi
  return 0
}

if [[ "$SUMMARY" -eq 1 ]]; then
  # 文脈へ出しうるのは、決まった文言と、検出した種類（決まった表記）と件数だけ。
  # まだ git のリポジトリでない場所（生成直後など）は、検査する設定が無いので黙って 0 で通す。
  # rev-parse は設定ファイルが壊れていても失敗するので、失敗だけで「リポジトリでない」と
  # 決めない（壊れた設定を黙って通すことになる）。git の文言を英語に固定し、出力の 1 行目が
  # `fatal: not a git repository` で始まるときだけを見分ける。含むかで見ると、エラー文に入る
  # 取り込み先のファイル名へこの語句を仕込まれ、壊れた設定を「リポジトリでない」と取り違える。
  if command -v git >/dev/null 2>&1; then
    if ! probe="$(LC_ALL=C git rev-parse --git-dir 2>&1)" \
      && [[ "${probe%%$'\n'*}" == "fatal: not a git repository"* ]]; then
      exit 0
    fi
  fi
  rc=0
  run_check 2>/dev/null || rc=$?
  case "$rc" in
    0) ;;
    1)
      echo "[check-git-config] 任意のコードを実行させうる git の設定が ${FOUND} 件あります（種類: ${KINDS}）。"
      echo "[check-git-config] 値はここに出しません。利用者に bash scripts/check-git-config.sh で確かめてもらうまで、このリポジトリで git を呼ぶ操作は慎重に扱ってください。"
      ;;
    *)
      echo "[check-git-config] git の設定を検査できませんでした。bash scripts/check-git-config.sh で確かめてください（危険な設定が無いとは言えません）。"
      ;;
  esac
  [[ "$HOOK" -eq 1 ]] && exit 0
  exit "$rc"
fi
run_check
