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
resolve_review_range() {
  command -v git >/dev/null 2>&1 || return 0
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  # ステージ済みがあるなら reviewer の既定に委ねる。
  git diff --cached --quiet || return 0
  # コミットが 1 件も無ければ比較の起点を作れない。
  git rev-parse --verify --quiet HEAD >/dev/null || return 0

  # 上流が設定されていればそこからの差分。未 push のコミットがそのまま対象になる。
  local upstream
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    REVIEW_RANGE="$upstream..HEAD"
    return 0
  fi

  # 上流が無い場合は既定ブランチの追跡枝を起点にする。名前は決め打ちしない。
  local base
  for base in origin/HEAD origin/main origin/master; do
    if git rev-parse --verify --quiet "$base" >/dev/null; then
      REVIEW_RANGE="$base..HEAD"
      return 0
    fi
  done

  # remote が無いプロジェクト。起点が無いので HEAD の全体を対象にする。
  # 「範囲を解決できないので何も見ない」を通過扱いにしないため、素通りはさせない。
  REVIEW_RANGE="HEAD"
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