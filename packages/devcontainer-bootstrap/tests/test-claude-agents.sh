#!/usr/bin/env bash
# Claude Code 向け委譲先エージェント定義の配置を検証する（issue #259）。
#
# 委譲先の model / tools を運用ルールの文言ではなく frontmatter で固定するのが目的。
# 指示文による呼びかけは迂回できるが、実行環境が読む機構は迂回できない
# （規範 shared-ai-rules.md 12 章「機構化の判断基準」）。
#
# ここでは (1) 条件分岐（--with-claude の有無・規範の有無）、(2) frontmatter が
# model / tools を持ち inherit でないこと、(3) 読み取り専用ロールから編集系ツールが
# 外れていること、(4) 規範を複製せず参照していること、(5) 判定の導線が規範側に
# あること（定義だけを配ると到達できない役割が残るため）を検証する。
# ネットワークには出ない（隣接チェックアウト／ローカルディレクトリ源のみ）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-claude-agents"

EXPLORER_REL=".claude/agents/explorer.md"
IMPLEMENTER_REL=".claude/agents/implementer.md"

# frontmatter から 1 キーの値を取る。先頭行が --- で始まり、次の --- で閉じる。
# 本文中に同名の記述があっても拾わないよう、閉じで打ち切る。
frontmatter_value() {
  awk -v key="$2" '
    NR == 1 && $0 ~ /^---[[:space:]]*\r?$/ { inside = 1; next }
    inside && $0 ~ /^---[[:space:]]*\r?$/ { exit }
    inside {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ "^" key "[[:space:]]*:") {
        sub("^" key "[[:space:]]*:[[:space:]]*", "", line)
        print line
        exit
      }
    }
  ' "$1"
}

# ── 条件分岐：生成の有無 ──────────────────────────────────────────────────────

it "--with-claude --with-playbook でエージェント定義が配置される"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-claude --with-playbook >/dev/null 2>&1
assert_file_exists "$out/$EXPLORER_REL"
explorer="$out/$EXPLORER_REL"

it "implementer の定義も配置される"
assert_file_exists "$out/$IMPLEMENTER_REL"
implementer="$out/$IMPLEMENTER_REL"

it "--with-claude なし（規範のみ）では .claude/ を生成しない"
outn="$(new_workdir)/p"
run_bootstrap "$outn" --with-playbook >/dev/null 2>&1
assert_file_absent "$outn/.claude"

it "--with-claude でも規範を配置しないならエージェント定義を配置しない"
# エージェント定義は規範導入経路に相乗りする。雛形の正本が規範パッケージ側にあり、
# playbook を入れなければ雛形そのものが無い。--with-claude は規範とは独立に
# .claude/settings.json と .claude/.gitignore を配るため、ディレクトリの不在では
# 判定しない。見たいのは agents/ の有無だけ。
outc="$(new_workdir)/p"
run_bootstrap "$outc" --with-claude --without-playbook >/dev/null 2>&1
assert_file_absent "$outc/.claude/agents"

# ── 機構としての固定（この配布の目的そのもの）────────────────────────────────

it "explorer の model が haiku に固定されている"
assert_eq "$(frontmatter_value "$explorer" model)" "haiku" "explorer の model"

it "implementer の model が sonnet に固定されている"
assert_eq "$(frontmatter_value "$implementer" model)" "sonnet" "implementer の model"

# model の記述が落ちた定義は親のモデルを継承し、機構としての意味を失う。落ちたことは
# 実行するまで分からないため、ここで止める。
it "どちらの定義も model に inherit を指定しない"
bad=""
for f in "$explorer" "$implementer"; do
  v="$(frontmatter_value "$f" model)"
  [[ -z "$v" || "$v" == "inherit" ]] && bad="$bad $(basename "$f")=[$v]"
done
if [[ -z "$bad" ]]; then pass; else fail "model が未指定または inherit:$bad"; fi

it "explorer の tools から編集系が外れている"
tools="$(frontmatter_value "$explorer" tools)"
if printf '%s' "$tools" | grep -qE '\b(Edit|Write|NotebookEdit)\b'; then
  fail "読み取り専用ロールに編集系ツールが含まれる: $tools"
else
  pass
fi

it "explorer の tools に調査へ必要な読み取り系が残っている"
# 編集系を外しすぎて調査が成立しない形にしない（Bash は所在の特定に要る）。
missing=""
for t in Read Grep Glob Bash; do
  printf '%s' "$tools" | grep -qE "\\b$t\\b" || missing="$missing $t"
done
if [[ -z "$missing" ]]; then pass; else fail "不足:$missing（tools=$tools）"; fi

it "implementer の tools には編集系が含まれる"
itools="$(frontmatter_value "$implementer" tools)"
if printf '%s' "$itools" | grep -qE '\bEdit\b' && printf '%s' "$itools" | grep -qE '\bWrite\b'; then
  pass
else
  fail "実装ロールに編集系が無い: $itools"
fi

it "frontmatter の name がファイル名と一致する"
en="$(frontmatter_value "$explorer" name)"
in_="$(frontmatter_value "$implementer" name)"
if [[ "$en" == "explorer" && "$in_" == "implementer" ]]; then
  pass
else
  fail "name の不一致: explorer=[$en] implementer=[$in_]"
fi

# ── 規範を複製せず参照する ──────────────────────────────────────────────────

it "定義が委譲判定の本文を複製していない（参照のみ）"
# 判定の条件そのものを定義側へ書き写すと、規範を直したときに片方だけが古くなる。
if grep -qE '委譲対象.*:|自分で実装してよい対象' "$explorer" "$implementer"; then
  fail "委譲判定の一覧が定義へ複製されている（規範を参照すべき）"
else
  pass
fi

it "定義が規範の所在を指している"
if grep -q 'shared-ai-rules.md' "$explorer" && grep -q 'role-contracts' "$explorer"; then
  pass
else
  fail "explorer が規範の所在を指していない"
fi

# ── 判定の導線が規範側にある（定義だけ配ると到達できない）────────────────────

it "規範に委譲判定の導線があり、生成物から辿れる"
# 定義を配っても、判定から到達する導線が無ければ役割は選ばれない。配布先で
# 「使われないまま残る役割」を作らないため、導線の実在をここで固定する。
rules="$out/.ai-playbook/shared-ai-rules.md"
assert_file_exists "$rules"

it "規範の委譲判定に調査の導線が含まれる"
if grep -q '調査を委譲する条件' "$rules"; then pass; else fail "「調査を委譲する条件」が規範に無い"; fi

it "規範に委譲の閾値が含まれる"
if grep -q '委譲の閾値' "$rules"; then pass; else fail "「委譲の閾値」が規範に無い"; fi

it "規範がサブエージェントの戻り値を定めている"
if grep -q 'サブエージェントの戻り値' "$rules"; then pass; else fail "戻り値の契約が規範に無い"; fi

it "explorer のロール契約が配布されている"
assert_file_exists "$out/.ai-playbook/role-contracts/explorer.md"

# ── 衝突ポリシー ────────────────────────────────────────────────────────────

it "既存のエージェント定義は既定で上書きしない"
printf 'KEEP\n' > "$out/$EXPLORER_REL"
run_bootstrap "$out" --with-claude --with-playbook >/dev/null 2>&1
if [[ "$(cat "$out/$EXPLORER_REL")" == "KEEP" ]]; then
  pass
else
  fail "既定で既存ファイルを上書きした"
fi

exit_with_result
