#!/usr/bin/env bash
# ループコーディング支援の実行体（verify / acceptance / loop-gate）を検証する。
#
# 規範（受け入れ検証の機械ゲート化・収束・verify ランナー契約）は ai-playbook の
# loop-workflow.md が正本であり、ここではその「実行側の機構」を検証する。
# 重要な不変条件は次の 2 点:
#   1. DCB 単体で動作する（外部規範パッケージの導入を前提にしない）。
#   2. 純粋な機構であり、規範文言・規範パッケージの内部パスを複製しない。
#
# ネットワークには出ない。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-loop-support"

# ── 生成物の存在（mode 非依存で常に生成） ─────────────────────────────────────

it "verify / acceptance / loop-gate が生成される"
missing=""
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
for s in verify.sh acceptance.sh loop-gate.sh; do
  [[ -f "$out/scripts/$s" ]] || missing="$missing $s"
done
if [[ -z "$missing" ]]; then pass; else fail "生成漏れ:$missing"; fi

it "生成スクリプトは有効な bash 構文"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
bad=""
for s in verify.sh acceptance.sh loop-gate.sh; do
  bash -n "$out/scripts/$s" 2>/dev/null || bad="$bad $s"
done
if [[ -z "$bad" ]]; then pass; else fail "構文エラー:$bad"; fi

it "生成スクリプトは実行可能（755）"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
assert_mode "$out/scripts/verify.sh" "755"

# ── acceptance の言語別既定 ───────────────────────────────────────────────────

it "node 選択時は acceptance に npm test が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
if grep -q 'npm test' "$out/scripts/acceptance.sh"; then pass; else fail "npm test が無い"; fi

it "rust 選択時は acceptance に cargo test が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages rust >/dev/null 2>&1
if grep -q 'cargo test' "$out/scripts/acceptance.sh"; then pass; else fail "cargo test が無い"; fi

it "go 選択時は acceptance に go test ./... が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages go >/dev/null 2>&1
if grep -q 'go test ./\.\.\.' "$out/scripts/acceptance.sh"; then pass; else fail "go test 行が無い"; fi

it "非選択言語の検証行は acceptance に入らない（node のみ選択時）"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
if grep -qE 'cargo test|go test|pytest|composer test' "$out/scripts/acceptance.sh"; then
  fail "非選択言語の検証行が混入"
else
  pass
fi

it "acceptance にプレースホルダが残留しない"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node,rust >/dev/null 2>&1
if grep -q '__ACCEPTANCE_CHECK_LINES__' "$out/scripts/acceptance.sh"; then fail "未置換プレースホルダが残留"; else pass; fi

# ── 単体動作の不変条件（規範パッケージ非依存・機構のみ） ──────────────────────

it "verify / loop-gate / acceptance は規範パッケージの内部パス・文言を複製しない"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
leak=""
for s in verify.sh loop-gate.sh acceptance.sh; do
  if grep -qE '\.ai-playbook|role-contracts|task-playbooks|shared-ai-rules|致命バグ' "$out/scripts/$s"; then
    leak="$leak $s"
  fi
done
if [[ -z "$leak" ]]; then pass; else fail "規範の複製が混入:$leak"; fi

# ── verify の接地信号（機械ゲート） ───────────────────────────────────────────

it "acceptance 合格で verify は VERIFY_PASS / exit 0"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
if out_txt="$(cd "$out" && VERIFY_ACCEPTANCE="$acc" bash scripts/verify.sh 2>&1)"; then
  assert_contains "$out_txt" "VERIFY_PASS" "verify 出力"
else
  fail "合格なのに exit 非 0: $out_txt"
fi

it "acceptance 未定義で verify は VERIFY_FAIL / exit 1"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
if out_txt="$(cd "$out" && VERIFY_ACCEPTANCE="/nonexistent/acc.sh" bash scripts/verify.sh 2>&1)"; then
  fail "未定義なのに通過してしまった: $out_txt"
else
  assert_contains "$out_txt" "VERIFY_FAIL" "verify 出力"
fi

# ── loop-gate の合成（単体 + 第二意見） ───────────────────────────────────────

it "単体（第二意見なし）: acceptance 合格で GATE_PASS / exit 0、第二意見は SKIP"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
if out_txt="$(cd "$out" && VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  if printf '%s' "$out_txt" | grep -q 'GATE_PASS' && printf '%s' "$out_txt" | grep -qi 'SKIP'; then
    pass
  else
    fail "GATE_PASS/SKIP が揃わない: $out_txt"
  fi
else
  fail "合格なのに exit 非 0: $out_txt"
fi

it "プロジェクトルート以外の作業ディレクトリから起動しても既定 acceptance を解決する"
# 回帰: verify/loop-gate は cwd 相対ではなくスクリプト位置基準でルートへ cd すること。
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
# 既定パス（scripts/acceptance.sh）を通す stub に差し替え、VERIFY_ACCEPTANCE は使わない
printf '#!/usr/bin/env bash\nexit 0\n' > "$out/scripts/acceptance.sh"
foreign="$(new_workdir)/elsewhere"; mkdir -p "$foreign"
if out_txt="$(cd "$foreign" && bash "$out/scripts/loop-gate.sh" 2>&1)"; then
  assert_contains "$out_txt" "GATE_PASS" "loop-gate 出力（異なる cwd から）"
else
  fail "異なる cwd から起動すると既定 acceptance を解決できない: $out_txt"
fi

it "acceptance 不合格で GATE_FAIL / exit 1"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
acc="$(new_workdir)/acc-fail.sh"; printf '#!/usr/bin/env bash\nexit 1\n' > "$acc"
if out_txt="$(cd "$out" && VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  fail "不合格なのに通過してしまった: $out_txt"
else
  assert_contains "$out_txt" "GATE_FAIL" "loop-gate 出力"
fi

it "第二意見（gemini-review.sh）が存在すれば直列化して通過する"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
printf '#!/usr/bin/env bash\necho stub-lgtm\nexit 0\n' > "$out/scripts/gemini-review.sh"
chmod +x "$out/scripts/gemini-review.sh"
if out_txt="$(cd "$out" && VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  if printf '%s' "$out_txt" | grep -q 'stub-lgtm' && printf '%s' "$out_txt" | grep -q 'GATE_PASS'; then
    pass
  else
    fail "第二意見が直列化されていない: $out_txt"
  fi
else
  fail "全段合格なのに exit 非 0: $out_txt"
fi

it "第二意見が指摘を返すと GATE_FAIL"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
printf '#!/usr/bin/env bash\necho stub-findings\nexit 1\n' > "$out/scripts/gemini-review.sh"
chmod +x "$out/scripts/gemini-review.sh"
if out_txt="$(cd "$out" && VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  fail "第二意見が指摘したのに通過: $out_txt"
else
  assert_contains "$out_txt" "GATE_FAIL" "loop-gate 出力"
fi

it "LOOP_GATE_REVIEW_CMD='' で第二意見を明示スキップできる"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
# reviewer が存在しても、空文字指定なら実行しない
printf '#!/usr/bin/env bash\necho SHOULD_NOT_RUN\nexit 1\n' > "$out/scripts/gemini-review.sh"
chmod +x "$out/scripts/gemini-review.sh"
if out_txt="$(cd "$out" && LOOP_GATE_REVIEW_CMD='' VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  if printf '%s' "$out_txt" | grep -q 'GATE_PASS' && ! printf '%s' "$out_txt" | grep -q 'SHOULD_NOT_RUN'; then
    pass
  else
    fail "空文字指定でも reviewer が走った、または通過しない: $out_txt"
  fi
else
  fail "スキップ指定で exit 非 0: $out_txt"
fi

# ── doctor 連携 ───────────────────────────────────────────────────────────────

it "doctor はループスクリプトを含めて FAIL=0 で診断する"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
output="$(bash "$PKG_DIR/doctor.sh" --target-dir "$out" 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]] && printf '%s' "$output" | grep -q 'verify.sh syntax OK' && printf '%s' "$output" | grep -q 'FAIL=0'; then
  pass
else
  fail "doctor が verify を検査していない、または FAIL がある (rc=$rc): $(printf '%s' "$output" | grep -iE 'verify|fail')"
fi

exit_with_result
