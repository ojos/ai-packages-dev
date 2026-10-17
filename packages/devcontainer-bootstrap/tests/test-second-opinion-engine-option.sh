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

it "記録したエンジンを --without で外す --upgrade は、警告して記録を外し、既定の決め方に戻る"
OUT_W="$(new_workdir)/p"
run_bootstrap "$OUT_W" --with-gemini --with-codex --second-opinion-engine codex >/dev/null 2>&1
w_err="$(bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_W" --without-codex 2>&1 >/dev/null)"; w_rc=$?
if [[ "$w_rc" == 0 && "$w_err" == *warning:*ORIGIN* ]] \
   && [[ "$(engine_of "$OUT_W")" == "" ]] \
   && ! grep -q 'input:second-opinion-engine' "$OUT_W/.devcontainer/ORIGIN"; then pass; else fail "rc=$w_rc 値=$(engine_of "$OUT_W") err=$w_err"; fi

it "gemini + antigravity を残して codex を外すと、既定（gemini）に戻る"
OUT_W2="$(new_workdir)/p"
run_bootstrap "$OUT_W2" --with-gemini --with-antigravity --with-codex --second-opinion-engine codex >/dev/null 2>&1
bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_W2" --without-codex >/dev/null 2>&1
if [[ "$(engine_of "$OUT_W2")" == "SECOND_OPINION_ENGINE=gemini" ]]; then pass; else fail "$(engine_of "$OUT_W2")"; fi

it "明示した値が選んでいないエンジンなら、--upgrade でも止まる"
if ! bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_W2" --second-opinion-engine codex >/dev/null 2>&1; then pass; else fail "止まっていない"; fi

it "ORIGIN の値が未知なら、ORIGIN の破損として止まる"
OUT_B="$(new_workdir)/p"
run_bootstrap "$OUT_B" --with-codex --second-opinion-engine codex >/dev/null 2>&1
sed 's|^input:second-opinion-engine=.*|input:second-opinion-engine=foo|' "$OUT_B/.devcontainer/ORIGIN" > "$OUT_B/o.tmp" && mv "$OUT_B/o.tmp" "$OUT_B/.devcontainer/ORIGIN"
b_err="$(bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_B" 2>&1 >/dev/null)"; b_rc=$?
if [[ "$b_rc" != 0 && "$b_err" == *ORIGIN* ]]; then pass; else fail "rc=$b_rc err=$b_err"; fi

it "doctor は ORIGIN の不正なエンジン値を検出する"
d_out="$(bash "$(dirname "$BOOTSTRAP")/doctor.sh" --target-dir "$OUT_B" 2>&1)"
if [[ "$d_out" == *"input:second-opinion-engine が"* ]]; then pass; else fail "検出していない: $d_out"; fi

it "--second-opinion-engine が最後の引数で値が無いときは、メッセージを出して止まる"
v_err="$(bash "$BOOTSTRAP" --project-name t --languages node --with-codex --second-opinion-engine 2>&1 >/dev/null)"; v_rc=$?
if [[ "$v_rc" != 0 && "$v_err" == *"--second-opinion-engine"* ]]; then pass; else fail "rc=$v_rc err=$v_err"; fi

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

# ── GEMINI_API_KEY の欄はエンジンが codex / antigravity のときだけ出さない（#646） ──
has_key() { [[ -n "$(command grep -n '^GEMINI_API_KEY=' "$1/.env.example")" ]]; }

check_key() { # 説明 期待(present|absent) 引数...
  local desc="$1" want="$2"; shift 2
  local out; out="$(new_workdir)/p"
  it "$desc"
  if ! run_bootstrap "$out" "$@" >/dev/null 2>&1 || [[ ! -f "$out/.env.example" ]]; then fail "生成に失敗した、または .env.example が無い"; return; fi
  if has_key "$out"; then
    [[ "$want" == present ]] && pass || fail "GEMINI_API_KEY が出ている"
  else
    [[ "$want" == absent ]] && pass || fail "GEMINI_API_KEY が無い"
  fi
}

check_key "gemini なしの codex 構成では GEMINI_API_KEY が無い" absent --with-claude --with-codex
check_key "gemini なしの antigravity 構成では GEMINI_API_KEY が無い" absent --with-claude --with-antigravity
check_key "gemini + codex（エンジンは gemini）では GEMINI_API_KEY がある" present --with-gemini --with-codex
check_key "antigravity も codex も選ばない構成では GEMINI_API_KEY がある" present --with-claude
check_key "antigravity と codex の両方で gemini なし（エンジン空）では GEMINI_API_KEY がある" present --with-antigravity --with-codex
check_key "gemini + codex に --second-opinion-engine codex でも GEMINI_API_KEY がある（gemini の CLI が入る）" present --with-gemini --with-codex --second-opinion-engine codex

OUT_K="$(new_workdir)/p"
it "GEMINI_API_KEY の説明行も一緒に消える"
if ! run_bootstrap "$OUT_K" --with-claude --with-codex >/dev/null 2>&1 || [[ ! -f "$OUT_K/.env.example" ]]; then fail "生成に失敗した"
elif [[ -z "$(command grep -n 'Gemini API キー' "$OUT_K/.env.example")" ]]; then pass; else fail "説明行が残っている"; fi

it "キーの欄が無い .env.example に、GEMINI_API_KEY への言及も空行 2 連続も無い"
if [[ -z "$(command grep -n 'GEMINI_API_KEY' "$OUT_K/.env.example")" && -z "$(awk 'prev=="" && $0=="" && NR>1 {print NR} {prev=$0}' "$OUT_K/.env.example")" ]]; then pass; else fail "残っている"; fi

it "キーの欄がある構成（gemini + codex 固定）の .env.example にも空行 2 連続が無い"
OUT_L="$(new_workdir)/p"
if run_bootstrap "$OUT_L" --with-gemini --with-codex --second-opinion-engine codex >/dev/null 2>&1 && [[ -z "$(awk 'prev=="" && $0=="" && NR>1 {print NR} {prev=$0}' "$OUT_L/.env.example")" ]]; then pass; else fail "空行が続く、または生成失敗"; fi

exit_with_result
