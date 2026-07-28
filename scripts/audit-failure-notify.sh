#!/usr/bin/env bash
# audit-failure-notify.sh — リリース資産監査の失敗を issue へ通知する
#
# 通知方針（#193 の確定事項）:
#   - GitHub の既定通知（Actions の失敗通知）に加え、**2 回連続で失敗したときだけ**
#     issue を起票する。1 回目で起票しないのは、資産取得の一過性失敗
#     （ネットワーク・API のレート制限）で issue が溜まると、追跡すべき本当の
#     不整合がその中に埋もれるため。
#   - 同じ失敗で open issue が既にあるときは、新規起票せずコメント追記に留める。
#
# ## 連続失敗回数の保持方法
#
# **同一 workflow の直前の実行結果（Actions の実行履歴）を参照する。** 専用の
# カウンタは持たない。
#
# 選定理由:
#   - 追加の状態を持たない。実行履歴は成功／失敗の正本そのもので、カウンタを別に
#     置くと同じ事実を二重管理することになる（ずれたときどちらが正かを決められない）。
#   - リポジトリへ状態ファイルをコミットする案は採らない。監査という読み取り専用の
#     処理が定期的に main の履歴を汚し、並列作業ともコンフリクトする。
#   - Actions のキャッシュ／アーティファクトも採らない。キャッシュは 7 日間
#     アクセスが無いと退去し、アーティファクトにも保持期限がある。定期実行の間隔が
#     週次だと、連続失敗のカウントが保持期限のせいで黙って 0 に戻り得る。
#     「2 回連続」の判定が保存期間に依存する形は避ける。
#
# 直前の 1 件だけを見る（それ以前まで遡らない）。「連続」の定義を単純に保つため。
# 実行中の自分自身は conclusion を持たないので、完了済みの実行だけを対象にすれば
# 自然に除外される。
#
# ## テスト可能性
#
# 判定（decide_notification）と実行（GitHub への書き込み）を分けてある。
# --previous / --existing-issue を渡し --dry-run を付ければ、GitHub API を
# 一切叩かずに判定だけを検査できる。テストが叩くのは workflow が実際に使うのと
# 同じ判定関数で、テスト専用の複製ではない。
#
# 終了コード: 0 = 判定・実行が完了 / 1 = 引数不正、または GitHub への書き込みに失敗

set -euo pipefail

usage() {
  cat <<'EOF'
usage:
  bash scripts/audit-failure-notify.sh --repo <owner/repo> --result <failure|success> [options]

options:
  --repo <owner/repo>        起票先リポジトリ（必須）
  --result <failure|success> 今回の監査結果（必須）
  --previous <failure|success|none>
                             直前の実行結果。省略時は gh で実行履歴から解決する
  --existing-issue <number|none>
                             同じ失敗で開いている issue。省略時は gh で検索する
  --workflow <file>          直前実行の解決に使う workflow ファイル名
                             （既定: release-audit.yml）
  --branch <name>            同上のブランチ（既定: main）
  --label <name>             重複抑制に使うラベル（既定: release-audit-failure）
  --title <text>             起票する issue のタイトル
  --run-url <url>            本文に載せる実行 URL
  --log-file <path>          本文へ末尾を抜粋する監査ログ
  --dry-run                  判定だけ行い、GitHub へ書き込まない
  -h, --help                 このヘルプ

output:
  decision=<none|create|comment>
  reason=<判定理由>
EOF
}

REPO=""
RESULT=""
PREVIOUS=""
EXISTING=""
WORKFLOW="release-audit.yml"
BRANCH="main"
LABEL="release-audit-failure"
TITLE="release-audit: リリース資産の整合性検証が 2 回連続で失敗しています"
RUN_URL=""
LOG_FILE=""
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --result) RESULT="$2"; shift 2 ;;
    --previous) PREVIOUS="$2"; shift 2 ;;
    --existing-issue) EXISTING="$2"; shift 2 ;;
    --workflow) WORKFLOW="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --title) TITLE="$2"; shift 2 ;;
    --run-url) RUN_URL="$2"; shift 2 ;;
    --log-file) LOG_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$REPO" ]] || { echo "error: --repo is required" >&2; exit 1; }
case "$RESULT" in
  failure|success) ;;
  *) echo "error: --result must be failure or success, got: '$RESULT'" >&2; exit 1 ;;
esac

# 直前の実行結果を Actions の実行履歴から解決する。
# 完了済み（--status completed）に絞るため、実行中の自分自身は対象に入らない。
# failure 以外の結論（cancelled / skipped 等）は「連続失敗」とみなさない。異常では
# ない中断まで数えると、2 回連続の意味が薄れるため。
resolve_previous_result() {
  local conclusion=""
  conclusion="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch "$BRANCH" \
    --status completed --limit 1 --json conclusion --jq '.[0].conclusion // ""' 2>/dev/null || true)"
  case "$conclusion" in
    failure|timed_out) printf 'failure' ;;
    success) printf 'success' ;;
    *) printf 'none' ;;
  esac
}

# 同じ失敗で開いている issue を探す。同一性はラベルで判定する。監査の失敗理由は
# 実行ごとに文面が変わり得るため、本文の一致で重複を判定すると同じ障害で複数の
# issue が立つ。
resolve_existing_issue() {
  local number=""
  number="$(gh issue list --repo "$REPO" --label "$LABEL" --state open \
    --limit 1 --json number --jq '.[0].number // ""' 2>/dev/null || true)"
  if [[ -n "$number" ]]; then
    printf '%s' "$number"
  else
    printf 'none'
  fi
}

# 通知の判定。GitHub へ問い合わせず、渡された事実だけで決める。
DECISION=""
REASON=""
decide_notification() {
  local result="$1" previous="$2" existing="$3"

  if [[ "$result" != "failure" ]]; then
    DECISION="none"
    REASON="監査は失敗していない"
    return 0
  fi
  if [[ "$previous" != "failure" ]]; then
    DECISION="none"
    REASON="今回が 1 回目の失敗（直前の実行: ${previous:-none}）。一過性の失敗で issue を溜めないため起票しない"
    return 0
  fi
  if [[ -n "$existing" && "$existing" != "none" ]]; then
    DECISION="comment"
    REASON="2 回連続で失敗。同じ失敗の open issue #$existing があるためコメント追記に留める"
    return 0
  fi
  DECISION="create"
  REASON="2 回連続で失敗し、同じ失敗の open issue が無い"
}

# 起票・追記の本文。実行 URL と監査ログの末尾を載せる。どのリリースのどのファイルで
# 値が食い違ったかはログにしか出ないため、issue だけを見て判断できるようにする。
build_body() {
  printf '%s\n\n' "リリース資産の整合性検証（\`scripts/release-packages.sh --audit\`）が 2 回連続で失敗しました。"
  printf '%s\n' "- 判定: $REASON"
  if [[ -n "$RUN_URL" ]]; then
    printf '%s\n' "- 実行: $RUN_URL"
  fi
  printf '\n'
  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    printf '%s\n\n' "### 監査ログ（末尾 50 行）"
    printf '```\n'
    tail -n 50 "$LOG_FILE"
    printf '```\n'
  fi
}

if [[ -z "$PREVIOUS" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    # dry-run は「GitHub を叩かない」ことが前提。解決できない値を勝手に補うと、
    # 判定の入力が見えないまま結果だけが出る。
    echo "error: --dry-run では --previous を明示してください（GitHub へ問い合わせないため）" >&2
    exit 1
  fi
  PREVIOUS="$(resolve_previous_result)"
fi

if [[ -z "$EXISTING" ]]; then
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "error: --dry-run では --existing-issue を明示してください（GitHub へ問い合わせないため）" >&2
    exit 1
  fi
  EXISTING="$(resolve_existing_issue)"
fi

decide_notification "$RESULT" "$PREVIOUS" "$EXISTING"

echo "decision=$DECISION"
echo "reason=$REASON"

if [[ "$DRY_RUN" == "true" || "$DECISION" == "none" ]]; then
  exit 0
fi

body_file="$(mktemp)"
build_body > "$body_file"

case "$DECISION" in
  create)
    # ラベルが未作成のリポジトリでは gh issue create --label が失敗する。
    # 通知が「ラベルが無い」だけの理由で落ちないよう、先に作成を試みる。
    gh label create "$LABEL" --repo "$REPO" \
      --description "リリース資産の整合性検証が連続失敗したことを示す" \
      --color B60205 >/dev/null 2>&1 || true
    gh issue create --repo "$REPO" --title "$TITLE" --label "$LABEL" --body-file "$body_file"
    ;;
  comment)
    gh issue comment "$EXISTING" --repo "$REPO" --body-file "$body_file"
    ;;
esac

rm -f "$body_file"
