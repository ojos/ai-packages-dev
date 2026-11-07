#!/usr/bin/env bash
# 検疫（dev quarantine）が開いた直後に一覧にする「エージェントの設定・フックの在りか」が、
# scripts/loop-gate.sh の 1-1 ②（レビューする範囲の変更ファイルのうち、エージェントの設定・
# フックに当たるもの）の対象を、すべて含むことの検査（#715）。
#
# 対象の一覧が 2 箇所（packages/devcontainer-host/dev.sh と scripts/loop-gate.sh）になるため、
# 共通規範 12 章「一覧の複製は機械照合で担保する」に従い、一致を照合する。
# dev.sh の側は、目印の行（# >>> quarantine-surfaces 〜 # <<< quarantine-surfaces）で囲んだ中の、
# シングルクォートで囲んだ行が一覧。loop-gate.sh の側は、resolve_agent_config_paths の case のパターン。
# dev.sh の一覧は、loop-gate.sh の一覧をすべて含み、さらに、検疫で注入の運び手になるもの（エージェントが読む
# 指示のファイル: CLAUDE.md・AGENTS.md・GEMINI.md・各種ツールの規則・コピロットの指示・ローカルのアクション・
# サブディレクトリの .claude/ と .mcp.json）を足したもの。.devcontainer/ は loop-gate.sh が既に持つので、
# 「含む」の中で照合される。足したものは、下の EXTRAS のいくつかが欠けていないことを確かめる。
#
# 抜き出しが空になったら落とす（書式が変わって、何も照合しないまま緑になることを避ける）。
# 検査は「ファイルを受け取る関数」にしてあり、末尾で壊したフィクスチャへも同じ関数を当てる。
#
# bash 3.2 互換を維持する（連想配列・mapfile を使わない）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-quarantine-surfaces"

DEV_SH="$REPO_ROOT/packages/devcontainer-host/dev.sh"
LOOP_GATE="$REPO_ROOT/scripts/loop-gate.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/test-quarantine-surfaces.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

# loop-gate.sh の case のパターンを 1 行 1 件で出す。パターンの行は `.claude/* | ...` で始まり、
# 行末の `\` で続き、`)` で終わる。
loop_gate_surfaces() {
  awk '
    !on && $0 ~ /^[[:space:]]*\.claude\/\* \|/ { on = 1 }
    on { print }
    on && $0 ~ /\)[[:space:]]*$/ { exit }
  ' "$1" | tr '|' '\n' | sed -e 's/\\$//' -e 's/)[[:space:]]*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | awk 'NF'
}

# dev.sh の一覧（目印の内側の、シングルクォートで囲んだ行）を 1 行 1 件で出す。
dev_surfaces() {
  sed -n '/^# >>> quarantine-surfaces$/,/^# <<< quarantine-surfaces$/p' "$1" | sed -n "s/^[[:space:]]*'\(.*\)'[[:space:]]*\$/\1/p"
}

# 検疫が足す項目のうち、欠けてはいけないもの（照合の対象はこの一部。全件の複製を持たない）。
EXTRAS=".devcontainer/*
CLAUDE.md
*/CLAUDE.md
AGENTS.md
*/AGENTS.md
GEMINI.md
.cursor/*
.github/copilot-instructions.md
*/.claude/*
*/.mcp.json"

# 検査: <dev.sh> <loop-gate.sh>。問題があれば原因を出して 1。
check_surfaces() {
  local dev="$1" lg="$2" want have missing item
  want="$(loop_gate_surfaces "$lg")"
  have="$(dev_surfaces "$dev")"
  if [[ -z "$want" ]]; then echo "loop-gate.sh の 1-1 ② の一覧を抜き出せない"; return 1; fi
  if [[ -z "$have" ]]; then echo "dev.sh の一覧（quarantine-surfaces の目印の内側）を抜き出せない"; return 1; fi
  missing=""
  while IFS= read -r item; do
    printf '%s\n' "$have" | grep -xF -- "$item" >/dev/null || missing="$missing $item"
  done <<<"$want"
  if [[ -n "$missing" ]]; then echo "dev.sh の一覧に無い（loop-gate.sh にある）:$missing"; return 1; fi
  missing=""
  while IFS= read -r item; do
    printf '%s\n' "$have" | grep -xF -- "$item" >/dev/null || missing="$missing $item"
  done <<<"$EXTRAS"
  if [[ -n "$missing" ]]; then echo "dev.sh の一覧に、検疫が足す項目が無い:$missing"; return 1; fi
  return 0
}

it "dev.sh の検疫の一覧が、loop-gate.sh の 1-1 ② の一覧をすべて含み、検疫が足す項目（指示のファイルなど）も含む"
if msg="$(check_surfaces "$DEV_SH" "$LOOP_GATE")"; then pass; else fail "$msg"; fi

it "loop-gate.sh の一覧を抜き出せている（14 件前後。空や極端に少ないときは書式が変わっている）"
n="$(loop_gate_surfaces "$LOOP_GATE" | awk 'END { print NR }')"
if [[ "$n" -ge 10 ]]; then pass; else fail "抜き出せたのは ${n} 件"; fi

it "dev.sh の一覧から 1 件でも欠けた複製は落ちる（検査が死んでいない）"
sed "/^  '\.husky\/\*'\$/d" "$DEV_SH" >"$FIX/dev-missing.sh"
if check_surfaces "$FIX/dev-missing.sh" "$LOOP_GATE" >/dev/null; then fail ".husky/* を消しても通った"; else pass; fi

it "検疫が足した項目（AGENTS.md）を欠いた複製は落ちる"
sed "/^  'AGENTS\.md'\$/d" "$DEV_SH" >"$FIX/dev-noagents.sh"
if check_surfaces "$FIX/dev-noagents.sh" "$LOOP_GATE" >/dev/null; then fail "AGENTS.md を消しても通った"; else pass; fi

it ".devcontainer/* を欠いた複製は落ちる"
sed "/^  '\.devcontainer\/\*'\$/d" "$DEV_SH" >"$FIX/dev-nodc.sh"
if check_surfaces "$FIX/dev-nodc.sh" "$LOOP_GATE" >/dev/null; then fail ".devcontainer/* を消しても通った"; else pass; fi

it "loop-gate.sh に対象が増えたのに dev.sh が追随していないと落ちる"
sed 's|^\( *\)\.claude/\* \| \.mcp\.json|\1.claude/* \| .newagent/* \| .mcp.json|' "$LOOP_GATE" >"$FIX/lg-more.sh"
if grep -qF '.newagent/*' "$FIX/lg-more.sh" && ! check_surfaces "$DEV_SH" "$FIX/lg-more.sh" >/dev/null; then pass; else fail "対象を足した loop-gate.sh で通った（または足せていない）"; fi

it "目印が無い・一覧が空の dev.sh は落ちる（空の抜き出しで緑にならない）"
sed -e 's/^# >>> quarantine-surfaces$/# >>> renamed/' "$DEV_SH" >"$FIX/dev-nomark.sh"
if check_surfaces "$FIX/dev-nomark.sh" "$LOOP_GATE" >/dev/null; then fail "目印を消しても通った"; else pass; fi

it "loop-gate.sh の一覧を抜き出せない（空の）ときも落ちる"
: >"$FIX/lg-empty.sh"
if check_surfaces "$DEV_SH" "$FIX/lg-empty.sh" >/dev/null; then fail "空の loop-gate.sh で通った"; else pass; fi

exit_with_result
