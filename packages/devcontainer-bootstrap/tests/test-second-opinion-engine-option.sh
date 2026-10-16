#!/usr/bin/env bash
# test-second-opinion-engine-option.sh — --second-opinion-engine（#610）を検証する。
#
# .env.example の SECOND_OPINION_ENGINE に記入する値を、生成時に明示できること。
# 指定が無いときの出力は変えず、--upgrade が記録を引き継ぎ、不正な値は生成の前に止める。

set -uo pipefail
if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-soe-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-second-opinion-engine-option"

engine_of() { grep -h '^SECOND_OPINION_ENGINE=' "$1/.env.example" 2>/dev/null; }

it "usage に --second-opinion-engine が載る"
if bash "$BOOTSTRAP" --help 2>&1 | grep -- '--second-opinion-engine' >/dev/null; then pass; else fail "--help に載っていない"; fi

# ── 指定で codex が入る ───────────────────────────────────────────────────────
OUT_C="$(new_workdir)/p"
run_bootstrap "$OUT_C" --with-gemini --with-codex --second-opinion-engine codex >/dev/null 2>&1

it "gemini + codex に --second-opinion-engine codex を指定すると SECOND_OPINION_ENGINE=codex"
if [[ "$(engine_of "$OUT_C")" == "SECOND_OPINION_ENGINE=codex" ]]; then pass; else fail "記入値: $(engine_of "$OUT_C")"; fi

it "ORIGIN に input:second-opinion-engine=codex が記録される"
if grep -qx 'input:second-opinion-engine=codex' "$OUT_C/.devcontainer/ORIGIN" 2>/dev/null; then pass; else fail "記録が無い"; fi

# ── upgrade 後も残る / 明示で上書き ──────────────────────────────────────────
it "--upgrade（指定なし）でも codex のまま残る"
if bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_C" >/dev/null 2>&1 \
   && [[ "$(engine_of "$OUT_C")" == "SECOND_OPINION_ENGINE=codex" ]] \
   && grep -qx 'input:second-opinion-engine=codex' "$OUT_C/.devcontainer/ORIGIN"; then pass; else fail "残っていない: $(engine_of "$OUT_C")"; fi

it "--upgrade --second-opinion-engine gemini で上書きできる"
if bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_C" --second-opinion-engine gemini >/dev/null 2>&1 \
   && [[ "$(engine_of "$OUT_C")" == "SECOND_OPINION_ENGINE=gemini" ]]; then pass; else fail "上書きできていない: $(engine_of "$OUT_C")"; fi

it "記録したエンジンを --without で外す --upgrade は、書く前に止まる"
before="$(cat "$OUT_C/.env.example")"
if ! bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_C" --second-opinion-engine codex --without-codex >/dev/null 2>&1 \
   && [[ "$(cat "$OUT_C/.env.example")" == "$before" ]]; then pass; else fail "止まっていない、または書き換わった"; fi

# ── 未指定の出力が不変 ───────────────────────────────────────────────────────
it "未指定の出力は、既定と同じ値を明示した場合と同一（gemini + codex は gemini のまま）"
OUT_D="$(new_workdir)/p"; OUT_E="$(new_workdir)/p"
run_bootstrap "$OUT_D" --with-gemini --with-codex >/dev/null 2>&1
run_bootstrap "$OUT_E" --with-gemini --with-codex --second-opinion-engine gemini >/dev/null 2>&1
if [[ "$(engine_of "$OUT_D")" == "SECOND_OPINION_ENGINE=gemini" ]] \
   && cmp -s "$OUT_D/.env.example" "$OUT_E/.env.example" \
   && ! grep -q 'input:second-opinion-engine' "$OUT_D/.devcontainer/ORIGIN"; then pass; else fail "未指定の出力が変わっている"; fi

it "未指定: antigravity + codex は空のまま、codex 単独は codex（#591 のまま）"
OUT_F="$(new_workdir)/p"; OUT_G="$(new_workdir)/p"
run_bootstrap "$OUT_F" --with-antigravity --with-codex >/dev/null 2>&1
run_bootstrap "$OUT_G" --with-codex >/dev/null 2>&1
if [[ "$(engine_of "$OUT_F")" == "SECOND_OPINION_ENGINE=" && "$(engine_of "$OUT_G")" == "SECOND_OPINION_ENGINE=codex" ]]; then pass; else fail "$(engine_of "$OUT_F") / $(engine_of "$OUT_G")"; fi

it "ORIGIN に行が無い（古い記録・未指定）構成の --upgrade は止まらない"
if bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_D" >/dev/null 2>&1; then pass; else fail "止まった"; fi

# ── 不正な値は生成の前に非 0 で止まる ────────────────────────────────────────
expect_stop() { # 説明 args...
  local desc="$1"; shift
  it "$desc"
  local out; out="$(new_workdir)/p"
  if ! run_bootstrap "$out" "$@" >/dev/null 2>&1 && [[ ! -e "$out" ]]; then pass; else fail "止まらない、または出力が書かれた"; fi
}
expect_stop "未知の値で止まる" --with-codex --second-opinion-engine foo
expect_stop "空の値で止まる" --with-codex --second-opinion-engine ""
expect_stop "選んでいないエンジン（antigravity）で止まる" --with-codex --second-opinion-engine antigravity
expect_stop "gemini を選んでいないのに gemini を指定すると止まる" --with-codex --second-opinion-engine gemini
expect_stop "エンジンの記入欄が出ない構成（gemini のみ）で止まる" --with-gemini --second-opinion-engine gemini
expect_stop "エンジンの記入欄が出ない構成（装備なし）で止まる" --second-opinion-engine gemini

exit_with_result
