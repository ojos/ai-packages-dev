#!/usr/bin/env bash
# Claude Code 向け intake 起点スキル・land 起点スキルの配置を検証する（issue #111・#311）。
#
# 規範（.ai-playbook/intake/、.ai-playbook/review-workflow.md 等）は「何を判定基準と
# するか」を定めるが、Claude Code がそれをいつ読むかは skill が起点になる。DCB は
# --with-claude のときだけ、規範を参照するだけの薄いスキルを .claude/skills/<name>/SKILL.md
# へ置く。ここでは (1) 条件分岐（--with-claude の有無）、(2) 衝突ポリシー、
# (3) 雛形が規範を複製せず参照だけしていること、(4) 参照先の実在を検証する。
# intake と land の 2 スキルは同じ配布経路（require_playbook_template →
# apply_file_with_policy）に乗るため、intake で確立した検査の型を land にも適用する。
# ネットワークには出ない（隣接チェックアウト／ローカルディレクトリ源のみ）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-claude-skill"

SKILL_REL=".claude/skills/intake/SKILL.md"
LAND_SKILL_REL=".claude/skills/land/SKILL.md"

# ── 条件分岐：生成の有無 ──────────────────────────────────────────────────────

it "--with-claude --with-playbook でスキルが SKILL.md 固定名で配置される"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-claude --with-playbook >/dev/null 2>&1
assert_file_exists "$out/$SKILL_REL"
skill="$out/$SKILL_REL"

it "--with-claude --with-playbook で land スキルも SKILL.md 固定名で配置される"
assert_file_exists "$out/$LAND_SKILL_REL"
land_skill="$out/$LAND_SKILL_REL"

it "--with-claude なし（規範のみ）では .claude/ を生成しない"
outn="$(new_workdir)/p"
run_bootstrap "$outn" --with-playbook >/dev/null 2>&1
assert_file_absent "$outn/.claude"

it "--with-claude なし（規範のみ）では land スキルも配置されない（対照群）"
assert_file_absent "$outn/$LAND_SKILL_REL"

it "--with-claude でも規範を配置しないならスキルを配置しない"
# skill は規範導入経路に相乗りする。playbook を入れないなら skill も置かない。
# .claude/ ディレクトリそのものの不在では判定しない。--with-claude は規範とは独立に
# .claude/settings.json（PreToolUse フックの配線）と .claude/.gitignore を配るため、
# ディレクトリは規範を入れなくても作られる。ここで見たいのは skill の有無だけ。
outc="$(new_workdir)/p"
run_bootstrap "$outc" --with-claude --without-playbook >/dev/null 2>&1
assert_file_absent "$outc/.claude/skills"

it "--with-claude でも規範を配置しないなら land スキルも配置しない"
assert_file_absent "$outc/$LAND_SKILL_REL"

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

# ── land スキル：参照のみ・複製なし（issue #311 の受け入れ条件の中核）──────────

it "land 雛形が .ai-playbook/templates/claude-skill-land.md とバイト一致する"
# 「配置された SKILL.md が雛形とバイト一致する」ことそのものを見る。intake の
# 写しは過去のコミットで字句が独立に編集され既にドリフトしているが（このリポジトリの
# .claude/skills/intake/SKILL.md と .ai-playbook/templates/claude-skill-intake.md を
# 比べると分かる）、land はここで初めて配布するため、最初からバイト一致を固定する。
if cmp -s "$PLAYBOOK_SRC/templates/claude-skill-land.md" "$land_skill"; then
  pass
else
  fail "land 雛形と配置後のファイルが食い違う: $(diff "$PLAYBOOK_SRC/templates/claude-skill-land.md" "$land_skill" | head -n 8 | tr '\n' '/')"
fi

it "land 雛形の CI スキップ検査は PR 本文とコミットメッセージの両方を見る（squash 本文の設定に依らない）"
# squash マージの本文の組み立て方（PR の説明文だけを使うか、各コミットのメッセージを
# 連ねるか）は squash_merge_commit_message（PR_BODY / COMMIT_MESSAGES）というリポジトリ
# 設定に依る。#311 のレビューで、コミットメッセージだけを見る検査は PR_BODY 設定の
# プロジェクトで [skip ci] を見落とすことが指摘された。設定を読んで検査対象を切り替える
# 案もあるが、判定経路が 2 本になるほど片方だけが古くなる余地が増えるため、
# 設定に依らず両方を常に検査する側（安全側）を選んだ。--json に body を含めているかで
# この選択が保たれているかを見る。
if grep -qE -- '--json[[:space:]]+body,commits' "$land_skill" \
  && grep -qF -- '.body,' "$land_skill"; then
  pass
else
  fail "CI スキップ検査が PR 本文（--json body,commits の body）を対象に含めていない"
fi

it "land 雛形はリモート最終ゲート・打ち切り基準の判定条件を複製していない（参照のみ／言い換えにも頑健）"
# PR #316（Copilot code review）で、逐語一致だけを見る検査は「規範の文面をそのまま
# 貼っていないか」しか見ておらず、「言い換えて条件を変えていないか」を見ていないことが
# 判明した。実際に手順 6 が「CI がすべて通っていれば解決済みとしてマージしてよい」を
# 言い換えたうえで、規範が許す範囲より狭い独自条件（「直さなくてよいと決める規則では
# ない」）へ書き換えていた。これは複製であると同時に、規範と食い違う第二の方針を
# 生む変化でもあった。
#
# そのため、条件文の逐語ではなく、言い換えても脱落しにくい短い特徴的断片で照合する。
# 断片は review-workflow.md「リモート最終ゲート」と closer.md「レビュー往復の打ち切り」
# が定める各条件の中核語から選ぶ。
#
# 検出できるもの: 下記の断片（またはそれを含む言い換え）が雛形にそのまま現れる場合。
# 実際にこの検査は、今回の指摘そのもの（「CI がすべて通っていれば」という言い換え）を
# 検出できる。
#
# 検出できないもの: これらの断片自体を避けた、さらに別の語への言い換え（例:
# 「全チェックが通過していれば」のように核となる語ごと置き換えた場合）は検出できない。
# 逐語一致より頑健だが、あらゆる言い換えを機械的に検出できる保証は無い。断片を
# 際限なく増やしても網羅はできないため、最終的な担保はレビュー（人間・Copilot 等）に
# 依存する。この限界を黙って隠さないために、ここへ明記する。
DUP_FRAGMENTS='CI がすべて通って
差分外の既存コード
命名・可読性・好み
事実誤認であることを実測で示せる
2 巡目以降の軽微な指摘は人間が却下'
dup_found=""
while IFS= read -r frag; do
  [[ -z "$frag" ]] && continue
  if grep -qF -- "$frag" "$land_skill"; then
    dup_found="${dup_found}[${frag}]"
  fi
done <<DUPEOF
$DUP_FRAGMENTS
DUPEOF
if [[ -z "$dup_found" ]]; then
  pass
else
  fail "規範の判定条件・打ち切り基準の言い換えとみられる断片が雛形に残っている: $dup_found"
fi

it "land 雛形は却下の記録要件を複製していない（参照のみ）"
if grep -qF '再現手順と実測結果を残さない却下を認めません' "$land_skill"; then
  fail "却下の記録要件が雛形へ複製されている（review-workflow.md を参照すべき）"
else
  pass
fi

it "land 雛形は規範を参照する形で判定基準を示す"
assert_contains "$(cat "$land_skill")" "判定の基準は規範が正本です" "land 雛形本文"

it "land 雛形は run_in_background で起こした待ちの実在確認を要求する"
# この段は issue #311 で明文化した追加要求（game-forge の原型には無い）。実際に
# 「起動した」という報告だけを信じて待ちが動いていなかった事象が起きたための追加であり、
# その要求が雛形から欠落しないことを固定する。
if grep -qF 'pgrep' "$land_skill" && grep -qF '実在を確かめて' "$land_skill"; then
  pass
else
  fail "起こした待ちの実在確認（pgrep 等）の記述が雛形から欠落している"
fi

it "land 雛形が参照する .ai-playbook パスがすべて生成物に実在する"
missing=""
for p in $(grep -oE '\.ai-playbook/[A-Za-z0-9_./-]+\.md' "$land_skill" | sort -u); do
  [[ -f "$out/$p" ]] || missing="$missing $p"
done
if [[ -z "$missing" ]]; then
  pass
else
  fail "land 雛形が参照するが実在しないパス:$missing"
fi

# ── 衝突ポリシー ──────────────────────────────────────────────────────────────

it "スキル配置は既定（skip）ポリシーで既存を温存する"
printf 'CUSTOM SKILL BODY' > "$skill"
run_bootstrap "$out" --with-claude --with-playbook >/dev/null 2>&1
assert_eq "$(cat "$skill")" "CUSTOM SKILL BODY" "skip 下で保持された内容"

it "スキル配置は overwrite ポリシーで再配置される"
run_bootstrap "$out" --with-claude --with-playbook --playbook-conflict-policy overwrite >/dev/null 2>&1
assert_contains "$(cat "$skill")" "Intake 判定" "overwrite 後の内容"

it "land スキル配置は既定（skip）ポリシーで既存を温存する"
printf 'CUSTOM LAND SKILL BODY' > "$land_skill"
run_bootstrap "$out" --with-claude --with-playbook >/dev/null 2>&1
assert_eq "$(cat "$land_skill")" "CUSTOM LAND SKILL BODY" "skip 下で保持された内容"

it "land スキル配置は overwrite ポリシーで再配置される"
run_bootstrap "$out" --with-claude --with-playbook --playbook-conflict-policy overwrite >/dev/null 2>&1
assert_contains "$(cat "$land_skill")" "PR の確認とマージ" "overwrite 後の内容"

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

it "land 雛形を持たない古いソースでは --with-claude で失敗する"
# intake の雛形は残し、claude-skill-land.md だけを欠いた版を再現する。land の
# require_playbook_template だけが失敗経路になることを確かめる。
oldsrc2="$(new_workdir)/old2"; mkdir -p "$oldsrc2"; cp -R "$PLAYBOOK_SRC/." "$oldsrc2/"
rm -f "$oldsrc2/templates/claude-skill-land.md"
outo2="$(new_workdir)/p"
output2="$(run_bootstrap "$outo2" --with-claude --playbook-from "$oldsrc2" 2>&1)"
code2=$?
if [[ $code2 -ne 0 ]] && printf '%s' "$output2" | grep -q 'template not found'; then
  pass
else
  fail "land 雛形不在でも失敗しなかった (code=$code2)"
fi

it "land 雛形不在で失敗したとき land スキルは配置されない"
assert_file_absent "$outo2/$LAND_SKILL_REL"

# ── dry-run 計画 ──────────────────────────────────────────────────────────────

it "dry-run は --with-claude 時にスキル生成を計画に含める"
outd="$(new_workdir)/p"
output="$(run_bootstrap "$outd" --with-claude --with-playbook --dry-run 2>&1)"
assert_contains "$output" ".claude/skills/intake/SKILL.md" "dry-run 計画"

it "dry-run は --with-claude 時に land スキル生成も計画に含める"
assert_contains "$output" ".claude/skills/land/SKILL.md" "dry-run 計画"

it "dry-run は --with-claude なしではスキルを計画に含めない"
outd2="$(new_workdir)/p"
output="$(run_bootstrap "$outd2" --with-playbook --dry-run 2>&1)"
case "$output" in
  *".claude/skills/intake/SKILL.md"*) fail "--with-claude なしなのに計画へ出た" ;;
  *) pass ;;
esac

it "dry-run は --with-claude なしでは land スキルも計画に含めない"
case "$output" in
  *".claude/skills/land/SKILL.md"*) fail "--with-claude なしなのに land が計画へ出た" ;;
  *) pass ;;
esac

exit_with_result
