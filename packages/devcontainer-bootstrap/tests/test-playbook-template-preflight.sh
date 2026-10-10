#!/usr/bin/env bash
# 規範パッケージの雛形が欠けているとき、何も書き込まずに止まることを検証する。
#
# require_playbook_template は書き込みの途中で呼ばれるため、それだけに頼ると、雛形の
# 無い古い規範を指定したときに、DCB 自身のテンプレートと規範を書いたあとで停止する。
# 生成物と .devcontainer/ORIGIN が食い違った中途半端な状態が残る（v0.19.0 のリリースの
# 下見で、--upgrade に v0.18.0 当時の規範を渡して実測した）。bootstrap.sh は書き込みの前に
# required_playbook_templates の一覧で一括して確かめる。このファイルはその約束と、一覧が
# require_playbook_template の呼び出しの写しとして欠けていないことを確かめる。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-playbook-template-preflight"

# 生成物のスナップショット（パスと cksum の一覧）。書き込みが起きたかの判定に使う。
snapshot() {
  (cd "$1" && find . -type f -exec cksum {} + | sort)
}

# 規範の写しから、指定した雛形を除いたものを作ってそのパスを返す。
playbook_without() {
  local name="$1" dir
  dir="$(new_workdir)/pb"
  cp -R "$PLAYBOOK_SRC" "$dir"
  rm -f "$dir/templates/$name"
  printf '%s' "$dir"
}

OLD_PB="$(playbook_without claude-skill-peers.md)"

# ── --upgrade ───────────────────────────────────────────────────────────────────

it "前提: 最新の規範で --with-claude の生成が成功し、ORIGIN が記録されている"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-claude --playbook-from "$PLAYBOOK_SRC" >/dev/null 2>&1
gen_rc=$?
if [[ "$gen_rc" == "0" && -f "$out/.devcontainer/ORIGIN" && -f "$out/scripts/session-peers.sh" ]]; then pass; else fail "生成の終了コード=$gen_rc"; fi

it "--upgrade に雛形の欠けた規範を渡すと、終了コード 1 で止まる"
# 同じ版の bootstrap.sh で --upgrade しても、書き込む中身が変わらないので書き込みが
# 起きても見分けられない。管理対象のファイルを 1 つ消し、--upgrade が作り直す状態に
# してから比べる（止まる前に書き込めば、このファイルが現れる）。
rm -f "$out/scripts/session-peers.sh"
before="$(snapshot "$out")"
err="$(bash "$BOOTSTRAP" --upgrade --output-dir "$out" --playbook-from "$OLD_PB" 2>&1 >/dev/null)"
rc=$?
assert_eq "$rc" "1" "終了コード"

it "--upgrade で止まったとき、欠けた雛形の名前を報告する"
assert_contains "$err" "templates/claude-skill-peers.md"

it "--upgrade で止まったとき、生成物を 1 つも書き換えない（消したファイルも作り直さない）"
after="$(snapshot "$out")"
if [[ "$before" == "$after" ]]; then pass; else fail "生成物が変わった: $(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -5)"; fi

# ── 新しく生成する場合 ──────────────────────────────────────────────────────────

it "新しく生成するときも、雛形が欠けていれば何も書かずに止まる"
out2="$(new_workdir)/p"
run_bootstrap "$out2" --with-claude --playbook-from "$OLD_PB" >/dev/null 2>&1
rc2=$?
written="$( [[ -d "$out2" ]] && find "$out2" -type f | wc -l | tr -d ' ' || echo 0)"
if [[ "$rc2" == "1" && "$written" == "0" ]]; then pass; else fail "終了コード=$rc2 書いたファイル数=$written"; fi

it "その構成が使わない雛形が欠けていても、生成できる（--with-claude なし）"
out3="$(new_workdir)/p"
run_bootstrap "$out3" --with-playbook --playbook-from "$OLD_PB" >/dev/null 2>&1
assert_eq "$?" "0" "終了コード"

# ── 一覧の写し漏れ（機械照合）──────────────────────────────────────────────────

it "required_playbook_templates の一覧が、require_playbook_template の呼び出しと一致する"
# 呼び出し側: `require_playbook_template <名前>` の <名前>（関数定義の行は除く）。
called="$(command grep -o -E 'require_playbook_template [A-Za-z0-9._-]+\)' "$BOOTSTRAP" \
  | sed -E 's/^require_playbook_template ([^)]+)\)$/\1/' | sort -u)"
# 一覧側: required_playbook_templates の本体の、引用符で囲んだ名前。
listed="$(sed -n '/^required_playbook_templates() {/,/^}/p' "$BOOTSTRAP" \
  | command grep -o -E "'[A-Za-z0-9._-]+'" | tr -d "'" | sort -u)"
if [[ -n "$called" && "$called" == "$listed" ]]; then
  pass
else
  fail "一致しない: $(diff <(printf '%s\n' "$called") <(printf '%s\n' "$listed") | head -10)"
fi

it "一覧から名前が漏れていると、雛形の有無にかかわらず内部の誤りとして止まる"
# 一覧の写し漏れを黙って通すと、雛形の欠けた古い規範で「書き込んでから止まる」状態に
# 戻る。一覧から claude-skill-peers.md を除いた写しで、--with-claude の生成が内部の誤りと
# して止まることを確かめる（規範は最新で、雛形そのものは揃っている）。
drift="$(new_workdir)/bootstrap-drift.sh"
command grep -v -F "'claude-skill-peers.md'" "$BOOTSTRAP" >"$drift"
out4="$(new_workdir)/p"
err4="$(bash "$drift" --project-name test --languages node --base-image "$TEST_BASE_IMAGE" \
  --output-dir "$out4" --with-claude --playbook-from "$PLAYBOOK_SRC" 2>&1 >/dev/null)"
rc4=$?
if [[ "$rc4" == "1" ]] && printf '%s' "$err4" | command grep -F 'internal: templates/claude-skill-peers.md' >/dev/null; then
  pass
else
  fail "終了コード=$rc4 出力=$(printf '%s' "$err4" | tail -2)"
fi

exit_with_result
