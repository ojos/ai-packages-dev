#!/usr/bin/env bash
# test-copilot-review.sh — リモート最終ゲート（Copilot）雛形の条件配置を検証する。
#
# 規範（review-workflow.md）はベンダー中立で「1 回に限定される機構なら自動要求でよい」
# とだけ述べ、具体機構は --with-copilot を選んだ場合のみ雛形として配置する。ここでは
# その分離（選択時のみ配置・未選択では不在）と、生成される YAML が「1 回だけ」を機構で
# 保証する不変条件（types: [opened] 限定・フォーク PR スキップ）を担保する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-copilot-review"

TPL="$PLAYBOOK_SRC/templates"
WF_REL=".github/workflows/copilot-review.yml"

# ── 規範パッケージ側に雛形が揃っているか ─────────────────────────────────────

it "規範パッケージがリモート最終ゲート（Copilot）の雛形を持つ"
assert_file_exists "$TPL/copilot-review.yml"

# ── 選択時のみ配置する ────────────────────────────────────────────────────────

it "--with-copilot --with-playbook で copilot-review.yml が配置される"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot --with-playbook >/dev/null 2>&1
assert_file_exists "$out/$WF_REL"

it "配置された copilot-review.yml は雛形と完全一致する（コピーであって再生成でない）"
if diff -q "$out/$WF_REL" "$TPL/copilot-review.yml" >/dev/null 2>&1; then pass; else fail "雛形と一致しない"; fi

it "--with-copilot なし（--with-playbook のみ）では配置しない"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-playbook >/dev/null 2>&1
assert_file_absent "$out/$WF_REL"

it "--with-copilot でも規範を配置しない構成（雛形ソース無し）では置かない"
# 雛形は規範パッケージが持つ。playbook を配置しないなら参照元が無く、配置は起きない。
out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot >/dev/null 2>&1
assert_file_absent "$out/$WF_REL"

it "dry-run は copilot 選択時に copilot-review.yml を計画へ含める"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --with-copilot --with-playbook --dry-run 2>&1)"
assert_contains "$output" "$WF_REL" "dry-run 計画"

it "dry-run は copilot 未選択なら copilot-review.yml を計画へ含めない"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --with-playbook --dry-run 2>&1)"
case "$output" in
  *"$WF_REL"*) fail "未選択なのに計画へ現れた" ;;
  *) pass ;;
esac

# ── 「1 回だけ」を機構で保証する不変条件 ──────────────────────────────────────

out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot --with-playbook >/dev/null 2>&1
wf="$out/$WF_REL"

it "生成ワークフローは types: [opened] に限定される（synchronize で再要求しない）"
# opened のみを契機とし、synchronize（PR 更新）を含めないこと。これが「1 回だけ」の実体。
# 判定は設定行（types:）に限定する。コメント文言に synchronize が出ても誤検知しない。
types_line="$(grep -E '^[[:space:]]*types:' "$wf" || true)"
if printf '%s' "$types_line" | grep -Eq '\[[[:space:]]*opened[[:space:]]*\]' \
   && ! printf '%s' "$types_line" | grep -q 'synchronize'; then
  pass
else
  fail "types が opened 限定でない、または synchronize を含む: '$types_line'"
fi

it "生成ワークフローはフォーク PR をスキップする"
if grep -qF 'github.event.pull_request.head.repo.full_name == github.repository' "$wf"; then
  pass
else
  fail "フォーク PR スキップの if 条件が無い"
fi

it "生成ワークフローはトークンをフォールバックさせる（PAT へ切替可）"
if grep -qF 'secrets.COPILOT_REVIEW_TOKEN || secrets.GITHUB_TOKEN' "$wf"; then
  pass
else
  fail "トークンフォールバックが無い"
fi

it "生成ワークフローは前提（422 の条件）をコメントで明記する"
if grep -q '422' "$wf"; then pass; else fail "前提の明記（422）が無い"; fi

# ── YAML として妥当である ─────────────────────────────────────────────────────
# actionlint があれば通す。無ければ PyYAML、それも無ければ最低限の構造検査で代替する
# （沈黙スキップはしない）。

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
