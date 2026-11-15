#!/usr/bin/env bash
# harness-audit-post.sh — ハーネスの棚卸し（scripts/harness-audit.sh）を回し、結果を追跡 issue へ
# コメントする（#724）。GitHub Actions の定期実行（.github/workflows/harness-audit.yml）が呼ぶ。
#
# ## なぜ要るのか
#
# 棚卸しは、当初 claude.ai のルーティンで毎週回す計画だった（#710）。しかし claude.ai の
# アカウントの GitHub 連携がこのリポジトリの組織につながらず、登録できなかった。棚卸しの中心
# （突き合わせとコメント）は curl・jq・gh だけで動き、Claude を要さないので、Actions の定期実行で回す。
# Claude が要る手順（/doctor prompt-audit・候補ごとの判断）は自動化せず、利用者が追跡 issue を
# 読むときにセッションで行う（docs/harness-audit.md）。
#
# ## すること
#
#   1. 追跡 issue のコメントから、前回の印を持つコメントを 1 件だけ選ぶ（select）。
#      拾うのは、このリポジトリの Actions（github-actions[bot]。種別が Bot のもの）が書き、
#      見出し「## ハーネスの棚卸し」と、版の形が正しい印を持つものの最後の 1 件だけ。
#      公開リポジトリで誰でもコメントを付けられるうえ、author_association（OWNER / MEMBER /
#      COLLABORATOR）は書き込み権限を表さない（読み取りだけの組織のメンバーも MEMBER になる）ため、
#      人のコメントの印では起点を動かさない。形の崩れた印を選ぶと、棚卸しが直近の版だけに
#      切り替わって間の版を飛ばすため、形の正しい印だけを見る。
#   2. その本文を scripts/harness-audit.sh --since-from-comment に渡す。
#   3. 結果を 1 件だけコメントする（compose）。冒頭に「自動の報告で、承認の根拠にならない」旨を置く
#      （成功のときは harness-audit.sh の出力がその旨を持つ）。
#      harness-audit.sh が失敗したら（終了コード 2 など）、空の候補として通さず、理由と前回の印を
#      写した失敗のコメントにする。印を写さないと、次の回が直近の版だけを見て間の版を飛ばすため。
#
# 書き込むのは追跡 issue（TRACKING_ISSUE）へのコメント 1 件だけ。issue もファイルも作らない。
#
# 使い方:
#   bash scripts/harness-audit-post.sh run
#       棚卸しを回してコメントする（GH_TOKEN と、Actions では GITHUB_REPOSITORY を使う）
#   bash scripts/harness-audit-post.sh select <コメントの JSON>
#       コメントの一覧（GitHub の issue comments API の配列。ページごとの配列が並んでいてもよい）から、
#       前回の印を持つコメントの本文を出す（無ければ空）
#   bash scripts/harness-audit-post.sh compose <終了コード> <標準出力のファイル> <標準エラーのファイル> <前回の本文のファイル>
#       コメントの本文を出す
#
# 環境変数（テスト用）:
#   HARNESS_AUDIT_CHANGELOG  harness-audit.sh へ --changelog として渡す（取得しない）
#
# 終了コード: 0 = 棚卸しの結果をコメントした
#             1 = 棚卸しが失敗した（失敗のコメントは付けた）、またはコメントを付けられなかった
#             2 = 引数の誤り・道具が無い
#
# bash 3.2 互換を維持する（連想配列・mapfile を使わない）。

set -uo pipefail

TRACKING_ISSUE=711
HEADING="## ハーネスの棚卸し"
# 印の形と、失敗のときの注意書きは scripts/harness-audit.sh と同じものを使う（一致は tests/test-harness-audit-post.sh が照合する）。
MARK_RE='<!-- harness-audit: checked-version=[0-9][0-9A-Za-z.]* -->'
# 選ぶときの印の形（jq の正規表現）。版は harness-audit.sh が読める形（数字と点）だけを認める。
MARK_JQ_RE='<!-- harness-audit: checked-version=[0-9]+(\.[0-9]+)* -->'
NOTICE='> このコメントは棚卸しの自動の報告で、承認の根拠になりません（共通規範 12 章）。候補を削るときは intake を通して issue を立てます。判断の手順は docs/harness-audit.md にあります。'
# 標準エラーの理由は、この長さで切ってコメントへ載せる。
ERR_MAX=2000

die() { echo "harness-audit-post: $*" >&2; exit 2; }

usage() {
  sed -n '/^# 使い方:/,/^# 環境変数/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'
}

# コメントの一覧（$1）から、前回の印を持つコメントの本文を出す。
select_previous() {
  local f="$1"
  [[ -f "$f" ]] || { echo "harness-audit-post: コメントの一覧のファイルがありません: $f" >&2; return 1; }
  jq -rs --arg h "$HEADING" --arg m "$MARK_JQ_RE" '
    [ .[] | if type == "array" then .[] else . end ]
    | [ .[] | select(
          (.user.login // "") == "github-actions[bot]" and (.user.type // "") == "Bot"
          and ((.body // "") | contains($h))
          and ((.body // "") | test($m)) ) ]
    | last | .body // ""' "$f" || { echo "harness-audit-post: コメントの一覧を読めません: $f" >&2; return 1; }
}

# 標準入力から不正な UTF-8 のバイト列（バイト数で切った末尾の欠けた文字など）を落とす。iconv が無ければそのまま通す。
utf8_clean() {
  if command -v iconv >/dev/null 2>&1; then iconv -c -f UTF-8 -t UTF-8 2>/dev/null; else cat; fi
}

# コメントの本文を出す。$1 = harness-audit.sh の終了コード、$2 = 標準出力、$3 = 標準エラー、$4 = 前回の本文。
compose() {
  local rc="$1" out="$2" err="$3" prev="$4" mark
  # 成功のときは、harness-audit.sh の出力が冒頭に承認の根拠にならない旨を持つので、そのまま載せる。
  if [[ "$rc" == 0 ]]; then
    cat "$out"
    return 0
  fi
  echo "$NOTICE"
  echo ""
  echo "$HEADING"
  echo ""
  if [[ "$rc" == 3 ]]; then
    echo "棚卸しに失敗しました（追跡 issue の前回のコメントを読めず、起点を決められません）。空の候補として扱いません。"
  else
    echo "棚卸しに失敗しました（\`scripts/harness-audit.sh\` の終了コード ${rc}）。空の候補として扱いません。"
  fi
  echo ""
  echo "理由:"
  echo ""
  echo '```'
  # コードブロックを途中で閉じないよう、バッククォート 3 つを置き換える。
  head -c "$ERR_MAX" "$err" | utf8_clean | sed 's/```/'"'''"'/g'
  echo ""
  echo '```'
  # 前回の印をそのまま写す（無ければ何も写さない）。
  mark="$(grep -o "$MARK_RE" "$prev" 2>/dev/null | tail -1)"
  if [[ -n "$mark" ]]; then
    echo ""
    echo "$mark"
  fi
}

# 棚卸しを回してコメントする。
run() {
  local here root repo work rc args
  command -v gh >/dev/null 2>&1 || die "gh が見つかりません"
  command -v jq >/dev/null 2>&1 || die "jq が見つかりません"
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)" || die "git リポジトリの中で実行してください"
  repo="${GITHUB_REPOSITORY:-}"
  if [[ -z "$repo" ]]; then
    repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || die "リポジトリを決められません"
  fi
  work="$(mktemp -d "${TMPDIR:-/tmp}/harness-audit-post.XXXXXX")" || die "一時ディレクトリを作れません"
  # shellcheck disable=SC2064 # 関数を抜けたあと（EXIT）にも消せるよう、今の値で埋め込む
  trap "rm -rf '$work'" EXIT

  : > "$work/out.md"
  : > "$work/previous.md"
  # 前回のコメントを読めなければ、棚卸しは回さず、失敗のコメントにする（読めないまま起点を決めない）。
  if ! gh api --paginate "repos/$repo/issues/$TRACKING_ISSUE/comments?per_page=100" > "$work/comments.json" 2> "$work/err.txt"; then
    echo "追跡 issue #$TRACKING_ISSUE のコメントを読めません" >> "$work/err.txt"
    rc=3
  elif ! select_previous "$work/comments.json" > "$work/previous.md" 2> "$work/err.txt"; then
    : > "$work/previous.md"
    rc=3
  else
    args=(--since-from-comment "$work/previous.md")
    if [[ -n "${HARNESS_AUDIT_CHANGELOG:-}" ]]; then args+=(--changelog "$HARNESS_AUDIT_CHANGELOG"); fi
    bash "$root/scripts/harness-audit.sh" "${args[@]}" > "$work/out.md" 2> "$work/err.txt"
    rc=$?
  fi
  # 失敗の理由は、投稿に失敗しても残るよう、投稿の前にログへ出す。
  if [[ "$rc" != 0 ]]; then cat "$work/err.txt" >&2; fi
  compose "$rc" "$work/out.md" "$work/err.txt" "$work/previous.md" > "$work/body.md"

  if ! gh issue comment "$TRACKING_ISSUE" --repo "$repo" --body-file "$work/body.md" >/dev/null; then
    echo "harness-audit-post: 追跡 issue #$TRACKING_ISSUE へコメントできません" >&2
    return 1
  fi
  echo "harness-audit-post: 追跡 issue #$TRACKING_ISSUE へコメントしました（終了コード ${rc}）"
  [[ "$rc" == 0 ]]
}

case "${1:-}" in
  run) [[ $# -eq 1 ]] || { usage >&2; die "run は引数を取りません"; }; run ;;
  select) [[ $# -eq 2 ]] || { usage >&2; die "select にはコメントの一覧のファイルを 1 つ渡します"; }; select_previous "$2" ;;
  compose) [[ $# -eq 5 ]] || { usage >&2; die "compose には 4 つの引数を渡します"; }; compose "$2" "$3" "$4" "$5" ;;
  -h|--help) usage ;;
  *) usage >&2; die "未知のサブコマンド: ${1:-（なし）}" ;;
esac
