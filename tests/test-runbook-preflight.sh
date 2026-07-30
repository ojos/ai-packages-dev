#!/usr/bin/env bash
# RELEASE_EXECUTION_RUNBOOK の preflight 検査表が、release-packages.sh の実際の
# preflight と一致していることを検査する。
#
# この表は「リリースを回す前に何が守られるか」を人が読む唯一の一覧で、実装から
# 書き写している。#161 の並列実装では、この表の必要コマンド一覧と require_cmd の
# 乖離が実際に発生し、統合パス（人の目視）は見逃してリモートのレビューが拾った。
# 目視で照合し続ける限り漏れるため、機械で突き合わせる。
#
# 突き合わせの相手は実装そのもの（preflight ブロックの本文）にする。テスト側へ
# 期待一覧を書き写すと、実装とテストの両方が RUNBOOK から独立して古くなり、
# 「照合しているつもりで何も見ていないテスト」になる。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-runbook-preflight"

RUNBOOK="$REPO_ROOT/docs/release/RELEASE_EXECUTION_RUNBOOK.md"
RELEASE="$REPO_ROOT/scripts/release-packages.sh"

# ── RUNBOOK 側 ────────────────────────────────────────────────────────────────

# 表のヘッダ行から、表が終わる（行頭が | でなくなる）まで。区切り行は落とす。
table_rows() {
  awk '
    /^\| # \| 検査 \| 実行条件 \| 実装 \|/ { inside = 1; next }
    inside && /^\|/ { print }
    inside && !/^\|/ { exit }
  ' "$RUNBOOK" | grep -v '^|---'
}

ROWS="$(table_rows)"

it "RUNBOOK に preflight 検査表がある"
if [[ -n "$ROWS" ]]; then pass; else fail "preflight 検査表を抽出できなかった"; fi

# 実装列（4 列目）のバッククォート付きトークン。1 行に 2 つ書かれる場合がある
# （版の未公開検査は DCB と ai-playbook で関数が分かれる）。
DOC_FUNCS="$(printf '%s\n' "$ROWS" | awk -F'|' '{print $5}' | grep -o '`[^`]*`' | tr -d '`' | sort -u)"

# 必要コマンドの一覧は、実装列が require_cmd である行の検査列に書かれている。
# 行番号で決め打ちすると、表へ行を足したときに黙って別の行を見にいく。
DOC_CMDS="$(printf '%s\n' "$ROWS" | awk -F'|' '$5 ~ /require_cmd/ {print $3}' | grep -o '`[^`]*`' | tr -d '`' | sort -u)"

# ── 実装側 ────────────────────────────────────────────────────────────────────

# preflight の本体は「最初の require_cmd 呼び出し」から「通過ログ」まで。
# 通過ログより後（配布プランの表示や実行本体）は preflight ではないため含めない。
#
# 行頭コメントは落とす。コメントが関数名に言及しているだけの行を「呼び出し」と
# 誤認すると、実際には呼ばれていない検査が表に載っていても通ってしまう。
preflight_block() {
  awk '
    /^require_cmd [a-z]/ { inside = 1 }
    inside { print }
    /^echo "\[ok\] preflight checks passed"/ { if (inside) exit }
  ' "$RELEASE" | grep -v '^[[:space:]]*#'
}

BLOCK="$(preflight_block)"

it "release-packages.sh の preflight ブロックを抽出できる"
if [[ -n "$BLOCK" ]]; then pass; else fail "preflight ブロックを抽出できなかった"; fi

IMPL_CMDS="$(printf '%s\n' "$BLOCK" | grep -E '^require_cmd [a-z0-9]' | awk '{print $2}' | sort -u)"

# このスクリプトが定義する関数のうち、preflight ブロックから呼ばれているもの。
DEFINED_FUNCS="$(grep -oE '^[a-z_]+\(\) \{' "$RELEASE" | sed 's/() {//' | sort -u)"
IMPL_FUNCS=""
for fn in $DEFINED_FUNCS; do
  if printf '%s\n' "$BLOCK" | grep -qE "(^|[^a-z_])$fn([^a-z_]|\$)"; then
    IMPL_FUNCS="$IMPL_FUNCS$fn
"
  fi
done
IMPL_FUNCS="$(printf '%s' "$IMPL_FUNCS" | sort -u)"

# ── 照合 ──────────────────────────────────────────────────────────────────────

it "必要コマンドの一覧が RUNBOOK と require_cmd で一致する"
assert_same_set "$DOC_CMDS" "$IMPL_CMDS" "RUNBOOK" "require_cmd"

it "preflight が実行する検査関数の一覧が RUNBOOK と実装で一致する"
assert_same_set "$DOC_FUNCS" "$IMPL_FUNCS" "RUNBOOK" "preflight"

it "RUNBOOK が挙げる実装関数がすべて release-packages.sh に定義されている"
# 上の照合でも落ちるが、「未定義」と「定義はあるが preflight から呼ばれていない」を
# 区別できるようにする。原因が違えば直し方も違う。
missing=""
for fn in $DOC_FUNCS; do
  case "
$DEFINED_FUNCS
" in
    *"
$fn
"*) ;;
    *) missing="$missing $fn" ;;
  esac
done
if [[ -z "$missing" ]]; then
  pass
else
  fail "release-packages.sh に定義が無い関数:$missing"
fi

exit_with_result
