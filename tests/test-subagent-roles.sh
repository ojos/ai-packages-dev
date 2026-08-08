#!/usr/bin/env bash
# .github/project-ai-rules.md の委譲可能な役割の表が、.claude/agents/ のエージェント
# 定義と一致していることを検査する。
#
# この表は規範側に置かれた定義の写しで、「どの役割をどのモデルへ委譲するか」を人が
# 知る唯一の一覧になっている。定義を足したときに表を更新し忘れると、使える委譲先が
# 規範から見えないまま残る。逆に表から消し忘れると、存在しない役割が規範として案内
# され続ける。どちらも目視では気づけないため機械で突き合わせる。
#
# モデル指定そのものも検査する。この仕組みの目的は、委譲先のモデルを運用ルールの
# 文言ではなく frontmatter で固定することにある（.ai-playbook/shared-ai-rules.md の
# 「機構で保証する」）。model の記述が落ちた定義は親のモデルを継承し、機構としての
# 意味を失う。落ちたことは実行するまで分からないため、ここで止める。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-subagent-roles"

RULES="$REPO_ROOT/.github/project-ai-rules.md"
AGENTS_DIR="$REPO_ROOT/.claude/agents"

# ── 規範側 ────────────────────────────────────────────────────────────────────

table_rows() {
  awk '
    /^\| 役割 \| model \| tools \| 契約の正本 \|/ { inside = 1; next }
    inside && /^\|/ { print }
    inside && !/^\|/ { exit }
  ' "$RULES" | grep -v '^|---'
}

ROWS="$(table_rows)"

it "project-ai-rules に委譲可能な役割の表がある"
if [[ -n "$ROWS" ]]; then pass; else fail "委譲可能な役割の表を抽出できなかった"; fi

DOC_ROLES="$(printf '%s\n' "$ROWS" | awk -F'|' '{print $2}' | grep -o '`[a-z][a-z-]*`' | tr -d '`' | sort -u)"

# 役割とモデルの対応。集合の照合だけでは「表と定義に同じ役割があるが model が違う」
# を捕まえられないため、対にして突き合わせる。
DOC_PAIRS="$(printf '%s\n' "$ROWS" \
  | awk -F'|' '{
      role = $2; model = $3
      gsub(/[` \t]/, "", role); gsub(/[` \t]/, "", model)
      if (role != "" && model != "") print role "=" model
    }' | sort -u)"

# ── 定義側 ────────────────────────────────────────────────────────────────────

# frontmatter から 1 キーの値を取る。定義は先頭行が --- で始まり、次の --- で閉じる。
# 本文中に同名の記述があっても拾わないよう、閉じで打ち切る。
agent_field() {
  awk -v key="$2" '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { exit }
    inside {
      idx = index($0, ":")
      if (idx == 0) next
      k = substr($0, 1, idx - 1)
      v = substr($0, idx + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", k)
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (k == key) { print v; exit }
    }
  ' "$1"
}

agent_files() {
  find "$AGENTS_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort
}

FILES="$(agent_files)"

it "エージェント定義が 1 つ以上ある"
if [[ -n "$FILES" ]]; then pass; else fail "$AGENTS_DIR に定義が無い"; fi

IMPL_ROLES=""
IMPL_PAIRS=""
missing_model=""
missing_tools=""
inherit_model=""
name_mismatch=""

for f in $FILES; do
  base="$(basename "$f" .md)"
  name="$(agent_field "$f" name)"
  model="$(agent_field "$f" model)"
  tools="$(agent_field "$f" tools)"

  [[ -z "$model" ]] && missing_model="$missing_model $base"
  [[ -z "$tools" ]] && missing_tools="$missing_tools $base"
  [[ "$model" == "inherit" ]] && inherit_model="$inherit_model $base"
  [[ "$name" != "$base" ]] && name_mismatch="$name_mismatch $base(name=$name)"

  IMPL_ROLES="$IMPL_ROLES$base
"
  IMPL_PAIRS="$IMPL_PAIRS$base=$model
"
done

IMPL_ROLES="$(printf '%s' "$IMPL_ROLES" | grep -v '^$' | sort -u)"
IMPL_PAIRS="$(printf '%s' "$IMPL_PAIRS" | grep -v '^$' | sort -u)"

# ── 定義そのものの検査 ────────────────────────────────────────────────────────

it "すべての定義が model を指定する"
if [[ -z "$missing_model" ]]; then pass; else fail "model が無い:$missing_model"; fi

it "すべての定義が tools を指定する"
if [[ -z "$missing_tools" ]]; then pass; else fail "tools が無い:$missing_tools"; fi

it "model が inherit でない（親モデルを継承しない）"
if [[ -z "$inherit_model" ]]; then pass; else fail "model が inherit:$inherit_model"; fi

it "frontmatter の name がファイル名と一致する"
if [[ -z "$name_mismatch" ]]; then pass; else fail "不一致:$name_mismatch"; fi

it ".claude/agents/ が追跡対象である"
tracked="$(cd "$REPO_ROOT" && git ls-files .claude/agents | wc -l | tr -d ' ')"
if [[ "$tracked" -gt 0 ]]; then pass; else fail ".gitignore で除外されている（!.claude/agents/ の再包含が必要）"; fi

# ── 照合 ──────────────────────────────────────────────────────────────────────

it "役割の一覧が規範と定義で一致する"
assert_same_set "$DOC_ROLES" "$IMPL_ROLES" "project-ai-rules" ".claude/agents"

it "役割ごとの model が規範と定義で一致する"
assert_same_set "$DOC_PAIRS" "$IMPL_PAIRS" "project-ai-rules" ".claude/agents"

exit_with_result
