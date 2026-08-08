#!/usr/bin/env bash
# Claude Code 向け intake 起点スキルの配置を検証する（issue #111）。
#
# 規範（.ai-playbook/intake/）は「intake の要否をどう判定するか」を定めるが、
# Claude Code がそれをいつ読むかは skill が起点になる。DCB は --with-claude の
# ときだけ、規範を参照するだけの薄いスキルを .claude/skills/intake/SKILL.md へ
# 置く。ここでは (1) 条件分岐（--with-claude の有無）、(2) 衝突ポリシー、
# (3) 雛形が規範を複製せず参照だけしていること、(4) 参照先の実在を検証する。
# ネットワークには出ない（隣接チェックアウト／ローカルディレクトリ源のみ）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-claude-skill"

SKILL_REL=".claude/skills/intake/SKILL.md"

# ── 条件分岐：生成の有無 ──────────────────────────────────────────────────────

it "--with-claude --with-playbook でスキルが SKILL.md 固定名で配置される"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-claude --with-playbook >/dev/null 2>&1
assert_file_exists "$out/$SKILL_REL"
skill="$out/$SKILL_REL"

it "--with-claude なし（規範のみ）では .claude/ を生成しない"
outn="$(new_workdir)/p"
run_bootstrap "$outn" --with-playbook >/dev/null 2>&1
assert_file_absent "$outn/.claude"

it "--with-claude でも規範を配置しないならスキルを配置しない"
# skill は規範導入経路に相乗りする。playbook を入れないなら skill も置かない。
# .claude/ ディレクトリそのものの不在では判定しない。--with-claude は規範とは独立に
# .claude/settings.json（PreToolUse フックの配線）と .claude/.gitignore を配るため、
# ディレクトリは規範を入れなくても作られる。ここで見たいのは skill の有無だけ。
outc="$(new_workdir)/p"
run_bootstrap "$outc" --with-claude --without-playbook >/dev/null 2>&1
assert_file_absent "$outc/.claude/skills"

# ── 参照のみ・複製なし（issue の受け入れ条件の中核）──────────────────────────

it "雛形に reason_code の一覧を複製していない（参照のみ）"
if grep -qE 'IMPLEMENTATION_MISSING|SMALL_FIX_EXEMPT|SMALL_FIX_REQUIRES|QUESTION_EXEMPT|INVESTIGATE_EXEMPT|BYPASS_APPROVED|EXEMPTION_UNCLEAR' "$skill"; then
  fail "具体的な reason_code が雛形へ複製されている（REASON_CODES.md を参照すべき）"
else
  pass
fi

it "雛形に軽微修正の免除条件（判定基準）を複製していない"
if grep -qE '単一のリバートコミット|6 条件|公開契約を変更しない|外部状態を変更しない' "$skill"; then
  fail "判定基準が雛形へ複製されている（REASON_CODES.md を参照すべき）"
else
  pass
fi

it "雛形に intake 票の項目定義を複製していない（参照のみ）"
if grep -qE 'scope\.in|scope\.out' "$skill"; then
  fail "intake 票の項目定義が雛形へ複製されている（intake-template.md を参照すべき）"
else
  pass
fi

it "雛形は規範の正本が .ai-playbook 側にあることを冒頭で宣言する"
assert_contains "$(cat "$skill")" "規範の正本は" "雛形本文"

it "雛形は判定に迷えば intake 必須側へ倒す方針を示す"
assert_contains "$(cat "$skill")" "intake 必須側へ倒します" "雛形本文"

# ── 参照先パスの実在（integration）────────────────────────────────────────────

it "雛形が参照する .ai-playbook パスがすべて生成物に実在する"
missing=""
for p in $(grep -oE '\.ai-playbook/[A-Za-z0-9_./-]+\.md' "$skill" | sort -u); do
  [[ -f "$out/$p" ]] || missing="$missing $p"
done
if [[ -z "$missing" ]]; then
  pass
else
  fail "雛形が参照するが実在しないパス:$missing"
fi

# ── 衝突ポリシー ──────────────────────────────────────────────────────────────

it "スキル配置は既定（skip）ポリシーで既存を温存する"
printf 'CUSTOM SKILL BODY' > "$skill"
run_bootstrap "$out" --with-claude --with-playbook >/dev/null 2>&1
assert_eq "$(cat "$skill")" "CUSTOM SKILL BODY" "skip 下で保持された内容"

it "スキル配置は overwrite ポリシーで再配置される"
run_bootstrap "$out" --with-claude --with-playbook --playbook-conflict-policy overwrite >/dev/null 2>&1
assert_contains "$(cat "$skill")" "Intake 判定" "overwrite 後の内容"

# ── require_playbook_template：古いソースでは失敗する ────────────────────────

it "雛形を持たない古いソースでは --with-claude で失敗する"
# 規範側に claude-skill-intake.md が無い版を再現する。他の雛形は残すため、
# skill 配置の require_playbook_template だけが失敗経路になる。
oldsrc="$(new_workdir)/old"; mkdir -p "$oldsrc"; cp -R "$PLAYBOOK_SRC/." "$oldsrc/"
rm -f "$oldsrc/templates/claude-skill-intake.md"
outo="$(new_workdir)/p"
output="$(run_bootstrap "$outo" --with-claude --playbook-from "$oldsrc" 2>&1)"
code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep -q 'template not found'; then
  pass
else
  fail "雛形不在でも失敗しなかった (code=$code)"
fi

it "雛形不在で失敗したときスキルは配置されない"
assert_file_absent "$outo/$SKILL_REL"

# ── dry-run 計画 ──────────────────────────────────────────────────────────────

it "dry-run は --with-claude 時にスキル生成を計画に含める"
outd="$(new_workdir)/p"
output="$(run_bootstrap "$outd" --with-claude --with-playbook --dry-run 2>&1)"
assert_contains "$output" ".claude/skills/intake/SKILL.md" "dry-run 計画"

it "dry-run は --with-claude なしではスキルを計画に含めない"
outd2="$(new_workdir)/p"
output="$(run_bootstrap "$outd2" --with-playbook --dry-run 2>&1)"
case "$output" in
  *".claude/skills/intake/SKILL.md"*) fail "--with-claude なしなのに計画へ出た" ;;
  *) pass ;;
esac

exit_with_result
