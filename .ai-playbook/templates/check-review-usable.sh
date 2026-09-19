#!/usr/bin/env bash
# check-review-usable.sh — review-usable.sh の判定を表で確かめる。
#
# review-gate.yml（確認側ワークフロー）は GitHub 上でしか動かないので、**判定そのもの
# はここで機械的に押さえる。** ワークフローは一覧を集めてこのスクリプトの対象
# （review-usable.sh）へ渡し、結果を commit status へ書くだけにしてある。判定を
# `.yml` へ書き写さないのは、手元と CI で同じコードが判定するようにするため
# （review-usable.sh 冒頭のコメントと同じ考え方）。
#
# 終了コード: 0 = すべて期待どおり / 1 = 1 件でも外れた
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HERE/review-usable.sh"

fail=0
n=0

# case <名前> <期待する終了コード> <期待する出力> <入力>
case_() {
  local name="$1" want_rc="$2" want_out="$3" input="$4" got_out got_rc=0
  n=$((n + 1))
  got_out="$(printf '%b' "$input" | bash "$TARGET" 2>/dev/null)" || got_rc=$?
  if [ "$got_rc" != "$want_rc" ] || [ "$got_out" != "$want_out" ]; then
    echo "[review-usable] FAIL: $name" >&2
    echo "  want rc=$want_rc out=$want_out" >&2
    echo "  got  rc=$got_rc out=$got_out" >&2
    fail=1
  fi
}

# ── 受け入れ条件に対応するもの ────────────────────────────────────────────────

case_ "全ファイルの patch が null なら no-patch で failure" 1 "no-patch" \
  "file 36 nopatch\nfile 93 nopatch\n"

case_ "Copilot の定型文レビューだけが付いていれば empty-review で failure" 3 "empty-review" \
  "file 40 patch\nreview Copilot wasn't able to review any files in this pull request.\n"

case_ "patch のあるファイルを含めば success" 0 "success" \
  "file 40 patch\nfile 93 nopatch\n"

# 対照群: 二値ファイルのみの PR（changes=0 だけ）は success（レビューできる
# ファイルがそもそも無いので、要求そのものが的外れになる）。
case_ "changes が 0 のファイルだけなら success（対照群）" 0 "success" \
  "file 0 nopatch\nfile 0 nopatch\n"

# 対照群: レビューがまだ投稿されていない（review 行が 1 つも無い）なら failure に
# しない。要求から投稿まで数分かかる窓を、空のレビューと混同しない。
case_ "レビュー未投稿なら failure にしない（対照群）" 0 "success" \
  "file 40 patch\n"

# API から読めなかった入力を「読まれた」と判定せず、status を付けない側（unknown）へ
# 倒す。patch 側・review 側のどちらが読めなかったかで別々に確かめる。
case_ "変更ファイル一覧を読めなかった入力は unknown（status を付けない）" 2 "unknown" \
  "patch-unknown\n"

case_ "投稿レビュー一覧を読めなかった入力は unknown（status を付けない）" 2 "unknown" \
  "file 40 patch\nreview-unknown\n"

# ── 追加の分岐 ────────────────────────────────────────────────────────────────

case_ "中身のあるレビューが付いていれば success" 0 "success" \
  "file 40 patch\nreview LGTM, looks good overall.\n"

case_ "定型文のあと中身のあるレビューが付けば最後の 1 件で success" 0 "success" \
  "file 40 patch\nreview Copilot wasn't able to review any files in this pull request.\nreview LGTM now.\n"

case_ "空行は数えない" 0 "success" \
  "\nfile 40 patch\n\n"

case_ "CRLF でも同じ答え" 1 "no-patch" \
  "file 36 nopatch\r\n"

case_ "空の入力は success（該当ファイルが無い）" 0 "success" ""

case_ "形の崩れた file 行は unknown" 2 "unknown" \
  "file not-a-number patch\n"

case_ "flag が既知の値でない file 行は unknown" 2 "unknown" \
  "file 40 maybe\n"

if [ "$fail" -ne 0 ]; then
  echo "[review-usable] 判定が期待と食い違いました（上記）" >&2
  exit 1
fi
echo "[review-usable] $n 件すべて期待どおり"
