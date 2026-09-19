#!/usr/bin/env bash
# review-usable.sh — Copilot code review が「要求・投稿された」だけでなく
# 「実際に 1 行でも読めたか」を判定する。
#
# 規範: .ai-playbook/review-workflow.md「リモート最終ゲート」。
#
# ══════════════════════════════════════════════════════════════════════════════
# 何のためにあるか
# ══════════════════════════════════════════════════════════════════════════════
#
# **「要求された」と「読まれた」は別である。** GitHub は 1 ファイルの差分が大きすぎると
# `patch` フィールドを落とす（実測: 48,036 B / 50,302 B のファイルは返り、105,251 B
# 相当は落ちた。**行数ではない**——落ちた PR の `changes` は 36 行と 93 行だった。
# 巨大な 1 行を書き換えると、旧＋新でその行だけの差分が 10 万バイトを超える）。
# `patch` の無いファイルしか無い PR に対しても、Copilot は要求どおりレビューを
# 投稿するが、中身は `Copilot wasn't able to review any files in this pull
# request.` の定型文だけになる。要求も投稿も記録は残るため、「要求されたか」しか
# 見ない判定はこの状態でも緑を出し続ける。ある利用プロジェクトの実運用では、この
# 形で 9 本の PR が review-gate 緑のまま通過し、最初の 1 本から気づくまで 3 日、
# 直近は 6 本連続だった。
#
# **原因そのもの（patch の欠落）と、最後の砦（投稿された定型文）の 2 段で見る。**
# 片方だけでは取りこぼす。
#
#   1 段目（patch の欠落）— 原因そのもの。レビューが届く前でも判定が確定する
#                          （返事を待っても変わらない事実である）。ただし
#                          GitHub の挙動が変われば意味を失う。
#   2 段目（定型文の一致）— 最後の砦。1 段目をすり抜けても拾える。ただし
#                          Copilot が文面を変えれば静かに効かなくなる。
#
# ══════════════════════════════════════════════════════════════════════════════
# なぜワークフロー（.yml）へ判定を書かないか
# ══════════════════════════════════════════════════════════════════════════════
#
# GitHub Actions の `run:` ブロックは GitHub 上でしか実行できない。判定をそこへ
# 埋めると、「patch が無い入力で failure になるか」のような受け入れ条件を、PR を
# 実際に立てる以外の方法で確かめられない。判定をここへ切り出すことで、手元と CI の
# 両方から機械的に確かめられる（check-review-usable.sh が表で押さえる）。呼び出し側
# の workflow（review-gate.yml）は、GitHub API から一覧を集めてこのスクリプトへ渡し、
# 結果を commit status へ書くだけになる。
#
# ══════════════════════════════════════════════════════════════════════════════
# 入出力
# ══════════════════════════════════════════════════════════════════════════════
#
# 入力: 標準入力。1 行 1 レコードで、次のいずれかの形を取る。順序は問わない。
#
#   file <changes> <patch|nopatch>
#     変更したファイル 1 件。changes は GitHub が返す追加+削除行数。patch/nopatch
#     は、そのファイルについて API が patch フィールドを返したか。
#     changes が 0 のファイル（二値ファイルの差し替え等）は判定材料に数えない
#     ——数えると、ロゴだけを差し替える PR が「1 つも読めない」で failure になる。
#
#   patch-unknown
#     変更ファイル一覧を API から読めなかった（呼び出し側の都合）。1 度でも
#     出れば、以降の file 行があっても無視する。
#
#   review <body>
#     投稿された Copilot 自身のレビュー本文 1 件。**発言者を Copilot に絞り込むのは
#     呼び出し側の役割である。** このスクリプトは「誰が投稿したか」を知らず、
#     渡された本文をそのまま定型文と比較するだけになっている。複数件あるときは
#     時系列順に渡すこと（最後の 1 件だけを見るため）。本文中の改行はスペースへ
#     畳んでおくこと——このスクリプトの入力は 1 行 1 レコードなので、改行を残すと
#     1 件のレビューが複数レコードに分裂する。定型文の一致は部分一致のままなので
#     判定結果は変わらない。
#
#   review-unknown
#     投稿されたレビュー一覧を API から読めなかった。
#
#   file/review が 1 件も無いことと、対応する *-unknown が無いことは区別する。
#   前者は「該当が無い」という確定した事実（二値ファイルだけの PR、レビュー未投稿）
#   で、後者は「確かめられなかった」という別の状態である。
#
# 出力: 標準出力へ 1 行（合図）と、対応する終了コード。
#
#   success        0   読める（実際に読めた、あるいは読む必要が無い）
#   no-patch       1   変更したどのファイルにも patch が無く、要求する前から読めない
#   unknown        2   確かめられなかった。**呼び出し側は status を書いてはならない**
#   empty-review   3   要求も投稿もされたが、投稿されたのは定型文だけだった
#
# 形の崩れた入力（未知の行、file/review の引数不足）も unknown（2）として扱う。
# 判定できない入力を「読めた」側へ倒すと、確かめていないものを通したことになる。
# 安全側（status を付けない側）へ寄せる。
#
# 使い方の例:
#   printf 'file 40 patch\n' | bash review-usable.sh; echo "$?"   # success / 0
#   printf 'file 40 nopatch\n' | bash review-usable.sh; echo "$?" # no-patch / 1
set -euo pipefail

patch_unknown=0
review_unknown=0
malformed=0
file_total=0
file_with_patch=0
# 直近に見た Copilot レビューの分類。""（未投稿）/ "yes"（定型文）/ "no"（中身あり）。
# 複数件を渡された場合は最後の 1 件で上書きする——投稿されると要求は消える性質上、
# 「最後に何が起きたか」だけが生きた状態を表す（timeline を見る他の判定と同じ考え方）。
last_review_empty=""

while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  [ -n "$line" ] || continue

  case "$line" in
    "patch-unknown")
      patch_unknown=1
      ;;
    "review-unknown")
      review_unknown=1
      ;;
    "file "*)
      rest="${line#file }"
      changes="${rest%% *}"
      flag="${rest#* }"
      # changes が数字でない、または flag が既知の値でない行は形が崩れている。
      # 一部だけ判定に混ぜると、無かったはずの「patch あり」を作ってしまいうる。
      case "$changes" in
        ''|*[!0-9]*) malformed=1; continue ;;
      esac
      case "$flag" in
        patch|nopatch) ;;
        *) malformed=1; continue ;;
      esac
      [ "$changes" -gt 0 ] || continue
      file_total=$((file_total + 1))
      [ "$flag" = "patch" ] && file_with_patch=$((file_with_patch + 1))
      ;;
    "review "*)
      body="${line#review }"
      case "$body" in
        # アポストロフィは引用の扱いが 1 つ増えるだけなので綴りに含めない
        # （"wasn't" と "was not" のどちらでも一致する）。
        *"t able to review any files"*) last_review_empty="yes" ;;
        *) last_review_empty="no" ;;
      esac
      ;;
    *)
      malformed=1
      ;;
  esac
done

if [ "$malformed" -eq 1 ]; then
  echo "unknown"
  exit 2
fi

if [ "$patch_unknown" -eq 1 ]; then
  echo "unknown"
  exit 2
fi

# 対照群: レビューできるファイルがそもそも無い（二値ファイルだけの PR）。
# レビュー本文の中身を見るまでもなく、要求そのものが的外れなので success とする。
if [ "$file_total" -eq 0 ]; then
  echo "success"
  exit 0
fi

# 1 段目: 原因そのもの。変更したどのファイルにも patch が無ければ、レビューが
# 届いていようといまいと、Copilot は要求される前から読めない。
if [ "$file_with_patch" -eq 0 ]; then
  echo "no-patch"
  exit 1
fi

if [ "$review_unknown" -eq 1 ]; then
  echo "unknown"
  exit 2
fi

# 2 段目: 最後の砦。1 段目を通っても、投稿された中身が定型文だけなら読まれていない。
# レビューがまだ投稿されていない（last_review_empty が空のまま）場合は、届いていない
# ことを「空」とは見なさない——要求から投稿まで数分かかる窓を failure にしない。
if [ "$last_review_empty" = "yes" ]; then
  echo "empty-review"
  exit 3
fi

echo "success"
exit 0
