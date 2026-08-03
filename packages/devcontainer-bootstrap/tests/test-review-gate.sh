#!/usr/bin/env bash
# test-review-gate.sh — リモート最終ゲート「確認側」雛形の条件配置を検証する。
#
# 要求側（copilot-review.yml）は test-copilot-review.sh が見る。こちらは確認側で、
# 役割が違う 2 本を 1 つのテストへ混ぜると、片方が落ちたときにどちらの機構が壊れた
# のか出力から読めなくなるため、ファイルを分ける。
#
# 確認側が守る不変条件は「要求しないこと」と「別の契機を持つこと」の 2 つ。前者は
# 要求が 2 か所から出ると規範の「1 回だけ」が壊れるため、後者は届かないイベントを
# 同じ契機から見ても起動しないため（規範 review-workflow.md「要求されたことを別の
# 契機で確認する」）。どちらも生成された YAML の内容として検査する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-review-gate"

TPL="$PLAYBOOK_SRC/templates"
WF_REL=".github/workflows/review-gate.yml"

# ── 規範パッケージ側に雛形が揃っているか ─────────────────────────────────────

it "規範パッケージがリモート最終ゲート（確認側）の雛形を持つ"
assert_file_exists "$TPL/review-gate.yml"

# ── 選択時のみ配置する ────────────────────────────────────────────────────────

it "--with-copilot --with-playbook で review-gate.yml が配置される"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot --with-playbook >/dev/null 2>&1
assert_file_exists "$out/$WF_REL"

it "配置された review-gate.yml は雛形と完全一致する（コピーであって再生成でない）"
if diff -q "$out/$WF_REL" "$TPL/review-gate.yml" >/dev/null 2>&1; then pass; else fail "雛形と一致しない"; fi

it "要求側と確認側は 2 本そろって配置される"
# 片方だけの配置は、この機構が塞ごうとしている穴（要求されないまま通る）を残す。
assert_file_exists "$out/.github/workflows/copilot-review.yml"

it "--with-copilot なし（--with-playbook のみ）では配置しない"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-playbook >/dev/null 2>&1
assert_file_absent "$out/$WF_REL"

it "--with-copilot でも規範を配置しない構成（雛形ソース無し）では置かない"
# 雛形は規範パッケージが持つ。playbook を配置しないなら参照元が無く、配置は起きない。
out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot >/dev/null 2>&1
assert_file_absent "$out/$WF_REL"

it "dry-run は copilot 選択時に review-gate.yml を計画へ含める"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --with-copilot --with-playbook --dry-run 2>&1)"
assert_contains "$output" "$WF_REL" "dry-run 計画"

it "dry-run は copilot 未選択なら review-gate.yml を計画へ含めない"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --with-playbook --dry-run 2>&1)"
case "$output" in
  *"$WF_REL"*) fail "未選択なのに計画へ現れた" ;;
  *) pass ;;
esac

# ── 確認側が守る不変条件 ──────────────────────────────────────────────────────

out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot --with-playbook >/dev/null 2>&1
wf="$out/$WF_REL"

it "確認側は要求できる権限を持たない（pull-requests は read）"
# 確認側も要求すると、規範の「1 回だけ要求する」が 2 か所から壊れる。コードを
# 読んで「要求していない」ことを確かめるより、**要求できないこと**を権限で押さえる
# ほうが、後から要求を書き足しても崩れない。
if grep -Eq '^[[:space:]]*pull-requests: read' "$wf" \
   && ! grep -Eq '^[[:space:]]*pull-requests: write' "$wf"; then
  pass
else
  fail "permissions の pull-requests が read でない"
fi

it "確認側は reviewers を POST しない"
# 読み取り（GET）は正当なので、エンドポイント名の出現だけでは落とさない。
# 手で要求する手順を案内する echo 行も除く（あれは実行ではなく文言）。
if grep -- '--method POST' "$wf" | grep -v 'echo' | grep -q 'requested_reviewers'; then
  fail "確認側が requested_reviewers へ POST している（要求してしまっている）"
else
  pass
fi

it "確認側は要求側と別の契機（定期実行）を持つ"
# 同じ契機を見る 2 本目では塞げない。届いていないのはイベントそのものだからである。
if grep -Eq '^[[:space:]]*schedule:' "$wf" && grep -q 'cron:' "$wf"; then
  pass
else
  fail "schedule / cron の契機が無い"
fi

it "確認側は PR 更新の契機も持つ（synchronize / reopened / ready_for_review）"
types_line="$(grep -E '^[[:space:]]*types:' "$wf" || true)"
missing=""
for t in opened synchronize reopened ready_for_review; do
  printf '%s' "$types_line" | grep -q "$t" || missing="$missing $t"
done
if [[ -z "$missing" ]]; then pass; else fail "types に不足:$missing"; fi

it "判定を commit status として書ける権限を持つ"
# ジョブの成否だけでは、定期実行から見た PR に何も現れない。status が出力先である。
if grep -Eq '^[[:space:]]*statuses: write' "$wf"; then
  pass
else
  fail "permissions に statuses: write が無い"
fi

it "判定を head SHA への status として出す"
if grep -qF 'repos/${REPO}/statuses/' "$wf"; then
  pass
else
  fail "statuses エンドポイントへの書き込みが無い"
fi

it "確認側はフォーク PR をスキップする"
# 要求側が対象外にしているものを「要求されていない」と落とすと、恒常的に赤くなる。
if grep -qF 'github.event.pull_request.head.repo.full_name == github.repository' "$wf"; then
  pass
else
  fail "フォーク PR スキップの if 条件が無い"
fi

it "レビュアー名を部分一致で判定しない"
# `*copilot*` で見ると、無関係な利用者がレビュアーに付いただけで緑になる。
if grep -qF 'copilot|"copilot-pull-request-reviewer[bot]") return 0' "$wf"; then
  pass
else
  fail "レビュアー名の完全一致判定が無い"
fi

# ── YAML として妥当である ─────────────────────────────────────────────────────
# actionlint があれば通す。無ければ PyYAML、それも無ければ最低限の構造検査で代替する
# （沈黙スキップはしない）。test-copilot-review.sh と同じ段構え。

it "生成ワークフローが YAML/Actions として妥当である"
if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$wf" >/dev/null 2>&1; then pass; else fail "actionlint 検査に失敗"; fi
elif python3 -c 'import yaml' >/dev/null 2>&1; then
  if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$wf" >/dev/null 2>&1; then
    pass
  else
    fail "PyYAML の safe_load に失敗"
  fi
else
  # 最低限の構造検査: 必須トップキーが存在し、行頭タブインデントが無いこと。
  tab="$(printf '\t')"
  if grep -Eq '^on:' "$wf" \
     && grep -Eq '^jobs:' "$wf" \
     && grep -Eq '^permissions:' "$wf" \
     && ! grep -q "^${tab}" "$wf"; then
    pass
  else
    fail "必須トップキー欠落またはタブインデント混入"
  fi
fi

exit_with_result
