#!/usr/bin/env bash
# 生成物のシェルスクリプトが、素の状態で静的解析（shellcheck）を通ることを検査する。
#
# 新設の理由: このリポジトリの受け入れ検証（scripts/acceptance.sh）は bootstrap.sh と
# doctor.sh を shellcheck するが、**bootstrap.sh が生成したスクリプトは検査していない。**
# 生成物の本体はヒアドキュメントの中にあり、生成元を解析しても中身は文字列としてしか
# 見えない。その結果 scripts/load-project-env.sh の zsh 固有展開 `${(%):-%x}` が
# SC2296（severity error）を出す状態で配布され、`scripts/` を静的解析する受け入れ条件を
# 持つ利用プロジェクトが、配布物のせいで赤になっていた（注記を手で足して回避していた）。
#
# 検査の深さ: -S warning。info / style まで拾うと配布物の書きぶりに関する好みが検査へ
# 混ざり、赤の意味が薄れる。SC2296 は severity error なのでこの範囲に入る。
#
# 出力書式に gcc を選ぶ理由: 既定の tty 書式は指摘箇所のソース行をそのまま出力する。
# 生成物のコメントは日本語で、ロケールが POSIX の環境では shellcheck がその行を
# エンコードできず commitBuffer エラー（終了コード 2）で落ちる。「日本語コメントの
# 近くで指摘が出たかどうか」で結果が変わる検査は信用できないため、ソース行を出さない
# 書式に固定する。指摘の所在は file:line:col で足りる。
#
# 対象の組み合わせ: 言語の選択（--languages）は生成されるスクリプトの集合を変えない
# ため代表 1 件で足りるが、装備フラグは変える（--with-gemini + 規範配置で
# scripts/second-opinion-review.sh が増える）。素の構成と全部入りの構成の 2 件を見る。
#
# 全部入りには --with-antigravity も含める。このフラグは install-ai-tools.sh へ
# 関数 2 つ分（agy の導入とテレメトリ無効化）を丸ごと足す唯一のフラグで、外すと
# その本体が静的解析を一度も通らないまま配布される。
#
# 空振りさせない: 生成に失敗した、あるいは対象が 0 件だった場合を合格にしない。
# 検証していないことを合格として報告するのが最悪であり、この不変条件は
# scripts/acceptance.sh が ran_any で採っている考え方と同じ。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-generated-shellcheck"

SEVERITY=warning

# 全構成を通じて実際に shellcheck へ掛けた本数。0 のまま終わったら落とす。
CHECKED_TOTAL=0

# 生成物の scripts/*.sh を 1 件ずつ shellcheck へ掛ける。
#   $1 = 生成先ディレクトリ / $2 = 構成の呼び名（失敗メッセージ用）
check_generated_scripts() {
  local out="$1" label="$2"
  local list f checked=0 failed=0 detail="" report=""

  it "$label: 生成物に scripts/*.sh がある"
  # ls の失敗（1 件も無い）と、生成そのものの失敗を同じ扱いにする。どちらも
  # 「検査対象 0 件で緑」を作るため、次の shellcheck 判定まで進ませない。
  list="$(ls "$out"/scripts/*.sh 2>/dev/null || true)"
  if [[ -z "$list" ]]; then
    fail "$label: scripts/*.sh が 1 件も無い（bootstrap.sh の生成に失敗した可能性）"
    return
  fi
  pass

  it "$label: zsh 固有展開を持つ scripts/load-project-env.sh が対象に含まれる"
  # この検査が生まれた原因のファイル。生成対象から外れても他のファイルが緑なら
  # 全体が緑になってしまうため、対象に含まれることを名指しで確かめる。
  if printf '%s\n' "$list" | grep -q '/scripts/load-project-env\.sh$'; then
    pass
  else
    fail "$label: scripts/load-project-env.sh が生成されていない"
  fi

  it "$label: 生成物が素で shellcheck -S $SEVERITY を通る"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    checked=$((checked + 1))
    if report="$(shellcheck -S "$SEVERITY" -f gcc "$f" 2>&1)"; then
      continue
    fi
    failed=$((failed + 1))
    # 生成先の一時パスは実行ごとに変わる。読む側に意味があるのは生成物内の
    # 相対パスなので、そこまでを削って出す。
    detail="$detail
$(printf '%s' "$report" | sed "s|^$out/||" | head -n 5)"
  done <<<"$list"

  CHECKED_TOTAL=$((CHECKED_TOTAL + checked))

  if [[ "$failed" -eq 0 ]]; then
    pass
  else
    fail "$label: $checked 件中 $failed 件で指摘（注記を足すか実装を直す）:$detail"
  fi
}

# ── 素の構成（装備フラグ・規範配置なし）──────────────────────────────────────

out="$(new_workdir)/plain"
run_bootstrap "$out" --without-playbook >/dev/null 2>&1
check_generated_scripts "$out" "素の構成"

# ── 全部入りの構成（装備フラグと規範配置で増えるスクリプトまで見る）──────────

outf="$(new_workdir)/full"
bash "$BOOTSTRAP" \
  --project-name test --languages node,go,python,php,rust,ruby \
  --with-aws --with-gcp --with-claude --with-gemini --with-antigravity --with-copilot --with-copilot-review \
  --playbook-from "$PLAYBOOK_SRC" \
  --output-dir "$outf" >/dev/null 2>&1
check_generated_scripts "$outf" "全部入りの構成"

it "全部入りの構成で第二意見スクリプトまで生成されている"
# 規範パッケージ由来の scripts/second-opinion-review.sh は、装備フラグを付けたときだけ
# 現れる。素の構成しか見ていないと、この 1 本が検査から抜けたまま緑になる。
assert_file_exists "$outf/scripts/second-opinion-review.sh"

it "全部入りの構成でリモート最終ゲートの判定スクリプトまで生成されている"
# 規範パッケージ由来の scripts/review-usable.sh / scripts/check-review-usable.sh は
# --with-copilot-review を付けたときだけ現れる。上と同じ理由で、名指しで確かめる
# （素の構成しか見ていないと、この 2 本が検査から抜けたまま緑になる）。
assert_file_exists "$outf/scripts/review-usable.sh"
assert_file_exists "$outf/scripts/check-review-usable.sh"

# ── 空振り防止 ────────────────────────────────────────────────────────────────

it "shellcheck を実際に 1 件以上へ掛けた"
if [[ "$CHECKED_TOTAL" -gt 0 ]]; then
  pass
else
  fail "検査対象が 0 件だった（生成に失敗しても緑になる状態）"
fi

exit_with_result
