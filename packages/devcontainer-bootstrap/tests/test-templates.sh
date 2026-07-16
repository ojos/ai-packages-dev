#!/usr/bin/env bash
# 雛形の所有関係を検証する。
#
# 以前は DCB が入口ファイルと gemini-review.sh の内容を埋め込んでいた。その結果、
# 規範（review-workflow.md）と実装（gemini-review.sh のプロンプト）が別パッケージへ
# 複製され、正本が 2 つになっていた。また DCB が規範パッケージの内部構造
# （role-contracts/ 等）をハードコードしていたため、規範側の再編で静かに壊れる
# 状態だった。
#
# ここでは「DCB は雛形を持たず、規範パッケージからコピーするだけ」という不変条件を
# 守る。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-templates"

TPL="$PLAYBOOK_SRC/templates"

# ── 規範パッケージ側に雛形が揃っているか ─────────────────────────────────────

it "規範パッケージが入口ファイルの雛形を持つ"
assert_file_exists "$TPL/entry.md"

it "規範パッケージがプロジェクト共通ルールの雛形を持つ"
assert_file_exists "$TPL/project-ai-rules.md"

it "規範パッケージが第二意見レビューの雛形を持つ"
assert_file_exists "$TPL/gemini-review.sh"

# ── DCB は内容を持たない ──────────────────────────────────────────────────────

it "DCB は入口ファイルの内容を持たない"
if grep -q '実行環境向け入口ファイル' "$BOOTSTRAP"; then
  fail "bootstrap.sh が入口ファイルの本文を埋め込んでいる"
else
  pass
fi

it "DCB はレビュー規範を複製していない"
# review-workflow.md が定めるゲート対象。DCB 側に現れたら複製。
if grep -q '致命バグ' "$BOOTSTRAP"; then
  fail "bootstrap.sh がレビュー規範を複製している"
else
  pass
fi

it "DCB は規範の内部ファイル名をハードコードしない"
# role-contracts/ 等の内部構造を知っていると、規範側の再編で静かに壊れる。
# コメント行を除いて検査する。
hits="$(grep -n 'role-contracts\|task-playbooks\|shared-ai-rules' "$BOOTSTRAP" \
  | grep -v '^\s*[0-9]*:\s*#' | grep -vc '^\s*[0-9]*:#' || true)"
if [[ "${hits:-0}" -eq 0 ]]; then
  pass
else
  fail "内部ファイル名への言及が $hits 件残っている:
$(grep -n 'role-contracts\|task-playbooks\|shared-ai-rules' "$BOOTSTRAP" | grep -v ':#' | head -5)"
fi

# ── 生成物は雛形と完全一致する（コピーであって再生成でない）──────────────────

out="$(new_workdir)/p"
run_bootstrap "$out" --with-playbook >/dev/null 2>&1

it "CLAUDE.md は雛形と完全一致する"
if diff -q "$out/CLAUDE.md" "$TPL/entry.md" >/dev/null 2>&1; then pass; else fail "雛形と一致しない"; fi

it "copilot-instructions.md は雛形と完全一致する"
if diff -q "$out/.github/copilot-instructions.md" "$TPL/entry.md" >/dev/null 2>&1; then pass; else fail "雛形と一致しない"; fi

it "project-ai-rules.md は雛形と完全一致する"
if diff -q "$out/.github/project-ai-rules.md" "$TPL/project-ai-rules.md" >/dev/null 2>&1; then pass; else fail "雛形と一致しない"; fi

it "gemini-review.sh は雛形と完全一致する"
if diff -q "$out/scripts/gemini-review.sh" "$TPL/gemini-review.sh" >/dev/null 2>&1; then pass; else fail "雛形と一致しない"; fi

it "雛形が欠けている規範ソースは失敗する"
broken="$(new_workdir)/broken"
mkdir -p "$broken/.ai-playbook"
cp "$PLAYBOOK_SRC/shared-ai-rules.md" "$broken/.ai-playbook/"
out2="$(new_workdir)/p"
output="$(run_bootstrap "$out2" --with-playbook --playbook-from "$broken" 2>&1)"
if [[ $? -ne 0 ]]; then
  assert_contains "$output" "template not found" "エラー出力"
else
  fail "雛形が無くても成功してしまった"
fi

# ── 規範パッケージ単独で 3 層構造を配線できる ────────────────────────────────
# DCB を介さない利用者（対応言語外、devcontainer 非使用、既存プロジェクト）が
# README の手順だけで完結できることを確認する。

it "DCB を使わずに雛形のコピーだけで 3 層が揃う"
solo="$(new_workdir)/solo"
mkdir -p "$solo/.github"
cp -R "$PLAYBOOK_SRC" "$solo/.ai-playbook"
cp "$solo/.ai-playbook/templates/project-ai-rules.md" "$solo/.github/project-ai-rules.md"
cp "$solo/.ai-playbook/templates/entry.md" "$solo/CLAUDE.md"
missing=""
for f in .ai-playbook/shared-ai-rules.md .github/project-ai-rules.md CLAUDE.md; do
  [[ -f "$solo/$f" ]] || missing="$missing $f"
done
if [[ -z "$missing" ]]; then pass; else fail "3 層が揃わない:$missing"; fi

it "単独導入でも入口ファイルの参照先が実在する"
missing=""
for f in .ai-playbook/shared-ai-rules.md .ai-playbook/role-contracts/planner.md \
         .ai-playbook/task-playbooks/pr-review.md .ai-playbook/review-workflow.md; do
  [[ -f "$solo/$f" ]] || missing="$missing $f"
done
if [[ -z "$missing" ]]; then pass; else fail "参照先が不在:$missing"; fi

exit_with_result
