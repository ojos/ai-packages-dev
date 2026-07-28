#!/usr/bin/env bash
# loop-gate.sh — ローカル事前ゲート（ループコーディングの収束点）
#
# push / PR 作成の前に、機械判定の受け入れ検証（verify.sh）と、任意の第二意見
# レビューを直列で通す単一入口。verify が通り、第二意見があればそれも通ったときだけ
# 通過する。
#
# このスクリプトは単体で動作する。第二意見レビューは存在すれば直列化し、
# 無ければ優雅にスキップする（外部パッケージの導入を前提にしない）。
#
# 第二意見レビュー:
#   既定で scripts/gemini-review.sh があれば実行する。
#   LOOP_GATE_REVIEW_CMD で任意のコマンドへ差し替え可能。空文字でスキップする。
#
#   gemini-review.sh の既定対象はステージ済み差分で、空なら「レビュー対象なし」
#   として 0 を返す。commit 後（ステージが空）にこのゲートを回すと、第二意見が
#   実質スキップされたまま GATE_PASS が出ることになる。push 前ゲートとしては
#   偽の緑なので、ステージが空のときは commit 済み範囲を対象に切り替える。
#
#   切り替えた先が空になる経路も塞ぐ。push 済みのブランチでは上流と HEAD が
#   同じコミットを指すため @{upstream}..HEAD の差分が空になり、同じ偽の緑が
#   復活する。範囲は「解決できたか」ではなく「実際に差分があるか」で選び、
#   無ければ既定ブランチとの分岐点まで戻してブランチ全体を対象にする。
#   それでも差分が無いときは、レビュー対象が無いことを明示したうえで通過する
#   （空を一律 FAIL にすると、差分の無い状態でのゲート実行が落ちるため）。
#
# 終了コード:
#   0 = GATE_PASS（全段通過。push 可）
#   1 = GATE_FAIL（いずれかの段が未通過、または実行不能）
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# verify・第二意見（git diff 等）はプロジェクトルート基準で実行する。
# scripts/ の 1 階層上がルート。任意の作業ディレクトリから起動しても不変にする。
cd "$(dirname "$HERE")"

# 既定の reviewer へ渡す引数を決める。
#
# ステージ済み差分があるときは何も渡さない（reviewer 側の既定に委ねる）。
# 空のときだけ commit 済み範囲へ切り替える。git リポジトリでない場合や範囲を
# 解決できない場合は、従来どおり引数なしで呼ぶ。ここで落とすと、git 管理下に
# ない生成直後のプロジェクトでゲートが使えなくなる。
REVIEW_RANGE=""
# 範囲は解決できたが差分が空だった（= レビューできる対象が無い）状態を表す。
# REVIEW_RANGE="" とは区別する。この状態を reviewer の既定へ流すと、空の
# ステージ済み差分を見せることになり、塞いだはずの素通りへ戻るため。
REVIEW_NO_TARGET=0

# 範囲が実際に差分を持つか。git diff --quiet は差分ありで 1 を返す。
# 128（範囲を解決できない等）を「差分あり」と誤認しないよう、1 だけを真とする。
# 末尾の -- は、範囲と同名のパスが存在するときの曖昧さを排除する。
range_has_diff() {
  local rc=0
  git diff --quiet "$1" -- >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]]
}

resolve_review_range() {
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  # ステージ済みがあるなら reviewer の既定に委ねる。
  git diff --cached --quiet || return 0
  # コミットが 1 件も無ければ比較の起点を作れない。
  git rev-parse --verify --quiet HEAD >/dev/null || return 0

  # 上流が設定されていればそこからの差分。未 push のコミットがそのまま対象になる。
  # push 済みだと上流 == HEAD で差分が空になるため、範囲を解決できたことではなく
  # 差分があることを採用条件にする。
  local upstream
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]] && range_has_diff "$upstream..HEAD"; then
    REVIEW_RANGE="$upstream..HEAD"
    return 0
  fi

  # 上流が無い、または上流との差分が空（= push 済み）の場合は、既定ブランチの
  # 追跡枝との分岐点を起点にし、ブランチ全体をレビュー対象にする。
  # 既定ブランチ名は決め打ちしない。
  #
  # 分岐点（merge-base）を使うのは、base..HEAD が 2 点間の比較であり、base 側に
  # 進んだコミットを「打ち消し」として差分へ混ぜるため。ブランチが加えた変更
  # だけを対象にする。
  local base mb
  for base in origin/HEAD origin/main origin/master; do
    git rev-parse --verify --quiet "$base" >/dev/null || continue
    mb="$(git merge-base "$base" HEAD 2>/dev/null || true)"
    # 履歴が繋がっていない（分岐点が無い）場合の受け皿。
    [[ -n "$mb" ]] || mb="$base"
    if range_has_diff "$mb..HEAD"; then
      REVIEW_RANGE="$mb..HEAD"
      return 0
    fi
    # 既定ブランチの追跡枝が見つかった時点で起点は確定する。そこと差分が無いのは
    # 「レビュー対象が無い」であって、空ツリーまで戻してリポジトリ全体を対象に
    # すべき状況ではない。
    REVIEW_NO_TARGET=1
    return 0
  done

  # 上流はあるが既定ブランチの追跡枝が無い場合。remote は存在するので、下の
  # 空ツリー（= リポジトリ全体）へは広げずレビュー対象なしとして扱う。
  if [[ -n "$upstream" ]]; then
    REVIEW_NO_TARGET=1
    return 0
  fi

  # remote が無いプロジェクト。起点が無いので空ツリーからの全体を対象にする。
  #
  # ここを "HEAD" にしてはならない。reviewer は範囲を git diff に渡すため、
  # git diff HEAD は「作業ツリー vs HEAD」になる。commit 直後は作業ツリーが
  # クリーンで差分が空になり、塞いだはずの素通りがそのまま復活する。
  # （git log HEAD が全履歴を指すのとは意味が違う。verify-commit-identity.sh の
  #   resolve_range が HEAD へ落とすのは git log に渡すためで、こことは別。）
  #
  # 空ツリーのハッシュはオブジェクト形式（sha1 / sha256）で異なるため、
  # 定数を焼き込まず git に計算させる。
  local empty_tree
  empty_tree="$(git hash-object -t tree /dev/null 2>/dev/null || true)"
  if [[ -n "$empty_tree" ]] && range_has_diff "$empty_tree..HEAD"; then
    REVIEW_RANGE="$empty_tree..HEAD"
    return 0
  fi

  # 空ツリーとの差分すら無い（実質空のリポジトリ）。
  REVIEW_NO_TARGET=1
}

echo "[loop-gate] step 1: verify (acceptance)"
if ! bash "$HERE/verify.sh"; then
  echo "[loop-gate] verify not passed" >&2
  echo "GATE_FAIL"
  exit 1
fi

echo "[loop-gate] step 2: second opinion"
if [[ "${LOOP_GATE_REVIEW_CMD-__UNSET__}" == "__UNSET__" ]]; then
  if [[ -f "$HERE/gemini-review.sh" ]]; then
    resolve_review_range
    review_ok=0
    if [[ -n "$REVIEW_RANGE" ]]; then
      echo "[loop-gate] staged diff is empty; reviewing $REVIEW_RANGE"
      bash "$HERE/gemini-review.sh" --range "$REVIEW_RANGE" || review_ok=1
    elif [[ "$REVIEW_NO_TARGET" -eq 1 ]]; then
      # レビューできる差分が 1 行も無い。第二意見を呼んでも対象が無いため、
      # その事実を明示したうえで通過させる（空を FAIL にすると、差分の無い
      # 状態でのゲート実行が落ちる）。黙って通すと偽の緑と区別が付かない。
      echo "[loop-gate] no reviewable diff; second opinion has nothing to review"
    else
      bash "$HERE/gemini-review.sh" || review_ok=1
    fi
    if [[ "$review_ok" -ne 0 ]]; then
      echo "[loop-gate] second opinion reported findings" >&2
      echo "GATE_FAIL"
      exit 1
    fi
  else
    echo "[loop-gate] SKIP (no reviewer present)"
  fi
elif [[ -n "$LOOP_GATE_REVIEW_CMD" ]]; then
  if ! bash -c "$LOOP_GATE_REVIEW_CMD"; then
    echo "[loop-gate] second opinion reported findings" >&2
    echo "GATE_FAIL"
    exit 1
  fi
else
  echo "[loop-gate] SKIP (disabled by LOOP_GATE_REVIEW_CMD='')"
fi

echo "GATE_PASS"
exit 0
