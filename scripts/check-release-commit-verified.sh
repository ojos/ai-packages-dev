#!/usr/bin/env bash
# check-release-commit-verified.sh — 配ろうとしているコミットの CI が緑で完了して
# いるかを、実行の一覧から決定的に判定する
#
# ══════════════════════════════════════════════════════════════════════════════
# なぜ機構で押さえるか
# ══════════════════════════════════════════════════════════════════════════════
#
# `.github/workflows/release.yml` は `actions/checkout` に ref を渡さないため、
# **起動した時点の既定ブランチの head をそのまま配る。** 一方 `ci.yml` は
# `push: branches: [main]` で走るので、**マージで生まれたコミットには新しい実行が
# 作られる**——ruleset の必須チェックは PR の head に対する評価であって、squash で
# 生まれたコミットを見たわけではない。
#
# したがって「マージ直後、その実行が終わる前に起動する」窓が開く。ほかに
# 「その実行が赤だった」「実行がそもそも作られていない」場合も同じ穴になる。
#
# **これまでこの窓を塞いでいたのは、手順書に書かれた人への指示だけだった。**
# 見るのは「気をつけたか」ではなく「緑で完了しているか」なので、
# `.ai-playbook/shared-ai-rules.md` 12 章に照らして機構へ移す。
#
# ══════════════════════════════════════════════════════════════════════════════
# 規則
# ══════════════════════════════════════════════════════════════════════════════
#
# **完了していない実行が 1 件でもあれば止める。** 進行中の再実行は、結論が
# ひっくり返りうる。すべて完了していれば、**最新の実行の結論**だけを見る——再実行で
# 緑にした場合を通し、再実行で赤くなった場合を止めるには、古い結論を混ぜられない。
#
# **入力が空なら止める。** 実行が 1 件も無いことは「緑」ではない。契機のイベントが
# 届かず実行が作られない状態は実在する（2026-09-19、数時間）。判定できないことを
# 合格にしない。
#
# **並び順は入力に依存しない。** 呼び出し側が渡す順ではなく、実行 ID の大きいものを
# 最新とみなす。GitHub の実行 ID は単調増加で、`gh api` の既定の並びは新しい順だが、
# **その既定に判定を預けると、並びが変わった日に黙って古い結論を見る。**
#
# ══════════════════════════════════════════════════════════════════════════════
# 入出力
# ══════════════════════════════════════════════════════════════════════════════
#
# 入力: 標準入力。判定対象の実行を 1 行 1 件、`実行ID 状態 結論`。
#       結論が無いもの（未完了）は `-` を置く。
#
#   printf '101 completed success\n102 completed failure\n' | bash scripts/check-release-commit-verified.sh
#
# 出力: 判定の内訳を人が読める形で出し、**最終行に合図**を置く。
#
#   RELEASE_COMMIT_VERIFIED     最新の実行が success で、未完了が 1 件も無い
#   RELEASE_COMMIT_UNVERIFIED   それ以外（赤・未完了・実行なし）
#
# 終了コード: 0 = 緑、1 = 赤または判定不能、2 = 入力の形が崩れている。
#
# **形の崩れた行があれば、何も判定せず 2 で終わる。** 一部だけ読んで判定すると、
# 止めるべき起動を黙って通しうるので、全部か無しかにする。
set -uo pipefail

# **照合順をバイト順に固定する。** 下の数値比較と行の形を見る正規表現の `[0-9]` は
# ロケールの照合順に従う。桁の揃った十進数ではどのロケールでも同じ結果になるが、
# 「どの環境から呼んでも同じ答え」を偶然に頼らない（check-control-chars.sh と同じ扱い）。
export LC_ALL=C

##
# 実行の一覧から合否を決める。
#
# **本番も負例もこの関数を通す。** 呼び出し側で同じ判断を書き直すと、ここを
# 無効化しても誰も気づけない（ojos/ai-packages-dev#328 で踏んだ形）。
#
# @stdin 1 行 1 件の `実行ID 状態 結論`
# @stdout 判定の内訳と、最終行の合図
# @return 0 = 緑 / 1 = 赤または判定不能 / 2 = 入力の形が崩れている
##
judge_release_commit() {
  local line id status conclusion
  local incomplete=0 total=0
  local latest_id="" latest_conclusion=""

  # **改行で終わらない最終行も読む。** read は区切り無しの EOF で 1 を返すため、
  # 素の while では最後の 1 件を黙って落とす。落ちるのは入力の末尾＝最も新しい
  # 実行になりやすく、**判定が反転する**（このテストの負例で実際に踏んだ）。
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    # **パイプの読み手に grep -q を置かない。** pipefail 下では、grep -q が先に抜けた
    # ときの SIGPIPE で書き手が落ち、パイプライン全体の結果が反転する
    # （check-shell-portability.sh が見ている形）。シェル組み込みだけで済ませる。
    if ! [[ "$line" =~ ^[0-9]+\ [a-z_]+\ (-|[a-z_]+)$ ]]; then
      echo "[release-verified] 形の崩れた行: $line" >&2
      return 2
    fi
    id="${line%% *}"
    status="${line#* }"
    status="${status%% *}"
    conclusion="${line##* }"
    total=$((total + 1))

    if [ "$status" != "completed" ]; then
      echo "[release-verified] 完了していない実行があります: id=${id} status=${status}"
      incomplete=$((incomplete + 1))
      continue
    fi

    # **文字列比較ではなく数値比較で最新を選ぶ。** 実行 ID は桁数が揃わない。
    if [ -z "$latest_id" ] || [ "$id" -gt "$latest_id" ]; then
      latest_id="$id"
      latest_conclusion="$conclusion"
    fi
  done

  if [ "$total" -eq 0 ]; then
    echo "[release-verified] 対象のコミットに CI の実行が 1 件もありません。判定できないので配りません。"
    echo "RELEASE_COMMIT_UNVERIFIED"
    return 1
  fi

  if [ "$incomplete" -gt 0 ]; then
    echo "[release-verified] 完了していない実行が ${incomplete} 件あります。結論が変わりうるので配りません。"
    echo "RELEASE_COMMIT_UNVERIFIED"
    return 1
  fi

  echo "[release-verified] 最新の実行: id=${latest_id} conclusion=${latest_conclusion}"
  if [ "$latest_conclusion" = "success" ]; then
    echo "RELEASE_COMMIT_VERIFIED"
    return 0
  fi

  echo "[release-verified] 最新の実行が success ではありません。配りません。"
  echo "RELEASE_COMMIT_UNVERIFIED"
  return 1
}

# source されたときは関数だけを提供する。テストは本番と同じ関数を呼ぶ。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  judge_release_commit
  exit $?
fi
