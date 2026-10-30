#!/usr/bin/env bash
# 生成される scripts/loop-gate.sh が、レビュー範囲の変更のうちエージェントの設定・フックに
# 触れるものを一覧で出力し、第二意見へ環境変数で渡すことを検証する。
#
# 対象: .claude/、.mcp.json、.github/workflows/、.githooks/、.husky/、.git-config-allow。どれも任意のコードの
# 実行や権限に関わる。通過の判定と終了コードは変えない（知らせるだけ）。
#
# 検証の仕方: 第二意見を stub に差し替え、loop-gate.sh が渡す環境変数
# SECOND_OPINION_AGENT_CONFIG_PATHS を観測する。LOOP_GATE_REVIEW_CMD での差し替えにも
# 同じ環境変数が届くことを確かめる。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-loop-gate-agent-config"

GIT_AUTHOR='-c user.name=T -c user.email=t@example.com'
MARK='エージェントの設定・フックに触れる変更'

in_repo() { ( cd "$1" && eval "$2" ) >/dev/null 2>&1; }

acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"

# 既定ブランチ main と、そこから切った feat を持つ生成物のリポジトリを作る。
mk_gate_repo() {
  local repo origin
  repo="$(new_workdir)/p"; origin="$(new_workdir)/origin.git"
  run_bootstrap "$repo" >/dev/null 2>&1
  cat > "$repo/scripts/second-opinion-review.sh" <<'STUB'
#!/usr/bin/env bash
echo "REVIEW_PATHS:$(printf '%s' "${SECOND_OPINION_AGENT_CONFIG_PATHS-}" | tr '\n' ',')"
echo "[second-opinion] LGTM (engine=stub, runs=1)"
exit 0
STUB
  cat > "$repo/scripts/second-opinion-record.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
STUB
  git init -q --bare "$origin" >/dev/null 2>&1
  in_repo "$repo" "git init -q && git symbolic-ref HEAD refs/heads/main && git add -A && git $GIT_AUTHOR commit -q -m c1 && git remote add origin '$origin' && git push -q -u origin main && git remote set-head origin main && git checkout -q -b feat"
  printf '%s' "$repo"
}

run_gate() { # repo [env...]
  local repo="$1"; shift
  GATE_OUT="$(cd "$repo" && env ALLOWED_AUTHOR_EMAILS="t@example.com" VERIFY_ACCEPTANCE="$acc" "$@" bash scripts/loop-gate.sh 2>&1)"
  GATE_RC=$?
}

it "エージェントの設定に触れるコミットでは、パスの一覧を出力し、第二意見へ環境変数で渡す"
repo="$(mk_gate_repo)"
in_repo "$repo" "mkdir -p .claude .github/workflows .husky && printf '{}\n' > .claude/settings.json && printf 'on: push\n' > .github/workflows/x.yml && printf 'x\n' > .husky/pre-commit && printf '{}\n' > .mcp.json && printf 'plain\n' > README.txt && git add -A && git $GIT_AUTHOR commit -q -m c2"
run_gate "$repo"
if [[ "$GATE_RC" -eq 0 && "$GATE_OUT" == *"$MARK"* && "$GATE_OUT" == *".claude/settings.json"* \
   && "$GATE_OUT" == *"REVIEW_PATHS:"*".github/workflows/x.yml"* && "$GATE_OUT" == *".husky/pre-commit"* \
   && "$GATE_OUT" == *".mcp.json"* && "$GATE_OUT" == *"GATE_PASS"* ]]; then
  pass
else
  fail "rc=$GATE_RC $GATE_OUT"
fi

it "対象でないファイル（README.txt）は一覧に入らない"
list="$(printf '%s' "$GATE_OUT" | sed -n 's/^REVIEW_PATHS://p')"
if [[ -n "$list" && "$list" != *README.txt* ]]; then pass; else fail "$list"; fi

it ".githooks/ も対象になる"
repo="$(mk_gate_repo)"
in_repo "$repo" "mkdir -p .githooks && printf 'x\n' > .githooks/pre-push && git add -A && git $GIT_AUTHOR commit -q -m c2"
run_gate "$repo"
if [[ "$GATE_OUT" == *"$MARK"*".githooks/pre-push"* && "$GATE_RC" -eq 0 ]]; then pass; else fail "rc=$GATE_RC $GATE_OUT"; fi

it ".git-config-allow（git の設定の許可の一覧）も対象になる"
# 許可の一覧への書き足しは、危険な git の設定を検査から黙らせる。設定そのものと同じ重さで見る。
repo="$(mk_gate_repo)"
in_repo "$repo" "printf 'core.hooksPath=.evil\\n' > .git-config-allow && git add -A && git $GIT_AUTHOR commit -q -m c2"
run_gate "$repo"
if [[ "$GATE_OUT" == *"$MARK"*".git-config-allow"* && "$GATE_RC" -eq 0 ]]; then pass; else fail "rc=$GATE_RC $GATE_OUT"; fi

it "対象の場所から外へ移した（改名した）ファイルも、移動元が一覧に出る"
# 改名の検出に任せると移動先しか出ず、ワークフローを外へ移して無効にしたことが埋もれる。
repo="$(mk_gate_repo)"
in_repo "$repo" "mkdir -p .github/workflows && printf 'on: push\\njobs: {}\\n' > .github/workflows/guard.yml && git add -A && git $GIT_AUTHOR commit -q -m c2 && git push -q origin HEAD:main 2>/dev/null; git update-ref refs/remotes/origin/main HEAD && mkdir -p docs && git mv .github/workflows/guard.yml docs/old.yml && git $GIT_AUTHOR commit -q -m c3"
run_gate "$repo"
if [[ "$GATE_OUT" == *"$MARK"*".github/workflows/guard.yml"* && "$GATE_RC" -eq 0 ]]; then pass; else fail "rc=$GATE_RC $GATE_OUT"; fi

it ".devcontainer/ と、settings.json が呼ぶフックの本体も対象になる"
repo="$(mk_gate_repo)"
in_repo "$repo" "mkdir -p .devcontainer scripts && printf '{}\\n' > .devcontainer/devcontainer.json && printf 'x\\n' > scripts/session-coord-hook.sh && git add -A && git $GIT_AUTHOR commit -q -m c2"
run_gate "$repo"
if [[ "$GATE_OUT" == *"$MARK"*".devcontainer/devcontainer.json"*"scripts/session-coord-hook.sh"* && "$GATE_RC" -eq 0 ]]; then pass; else fail "rc=$GATE_RC $GATE_OUT"; fi

it "サブディレクトリの .gitattributes も対象になる"
repo="$(mk_gate_repo)"
in_repo "$repo" "mkdir -p src && printf '*.x filter=evil\\n' > src/.gitattributes && git add -A && git $GIT_AUTHOR commit -q -m c2"
run_gate "$repo"
if [[ "$GATE_OUT" == *"$MARK"*"src/.gitattributes"* && "$GATE_RC" -eq 0 ]]; then pass; else fail "rc=$GATE_RC $GATE_OUT"; fi

it "改行を含むファイル名も、対象の場所にあれば一覧に出る（改行は ? に置き換える）"
repo="$(mk_gate_repo)"
in_repo "$repo" "mkdir -p .github/workflows && printf 'x\\n' > \"\$(printf '.github/workflows/a\\nb.yml')\" && git add -A && git $GIT_AUTHOR commit -q -m c2"
run_gate "$repo"
if [[ "$GATE_OUT" == *"$MARK"*".github/workflows/a?b.yml"* && "$GATE_RC" -eq 0 ]]; then pass; else fail "rc=$GATE_RC $GATE_OUT"; fi

it "一覧の表示から制御文字を落とす（ESC などで警告の行を消させない）"
repo="$(mk_gate_repo)"
in_repo "$repo" "mkdir -p .claude && printf 'x\\n' > \"\$(printf '.claude/a\\033[2Kb')\" && git add -A && git $GIT_AUTHOR commit -q -m c2"
run_gate "$repo"
line="$(printf '%s\n' "$GATE_OUT" | command grep -F "$MARK" || true)"
if [[ -n "$line" && "$line" == *".claude/a[2Kb"* && "$line" != *$'\033'* ]]; then pass; else fail "line=$(printf '%q' "$line")"; fi

it "ステージ済みの変更だけがエージェントの設定に触れるときも一覧に出る"
repo="$(mk_gate_repo)"
in_repo "$repo" "printf 'a\n' > a.txt && git add -A && git $GIT_AUTHOR commit -q -m c2 && mkdir -p .claude && printf '{}\n' > .claude/settings.json && git add .claude/settings.json"
run_gate "$repo"
if [[ "$GATE_OUT" == *"$MARK"*".claude/settings.json"* && "$GATE_RC" -eq 0 ]]; then pass; else fail "rc=$GATE_RC $GATE_OUT"; fi

it "触れない差分では一覧を出さず、第二意見へ渡す環境変数も空で、終了コードは同じ（0）"
repo="$(mk_gate_repo)"
in_repo "$repo" "printf 'a\n' > a.txt && git add -A && git $GIT_AUTHOR commit -q -m c2"
run_gate "$repo"
if [[ "$GATE_RC" -eq 0 && "$GATE_OUT" != *"$MARK"* && "$GATE_OUT" == *"REVIEW_PATHS:"$'\n'* && "$GATE_OUT" == *"GATE_PASS"* ]]; then
  pass
else
  fail "rc=$GATE_RC $GATE_OUT"
fi

it "外から入っていた SECOND_OPINION_AGENT_CONFIG_PATHS は、触れない差分では空に上書きされる"
run_gate "$repo" SECOND_OPINION_AGENT_CONFIG_PATHS=".claude/forged"
if [[ "$GATE_OUT" == *"REVIEW_PATHS:"$'\n'* && "$GATE_OUT" != *"forged"* ]]; then pass; else fail "$GATE_OUT"; fi

it "第二意見を止めても（LOOP_GATE_REVIEW_CMD=''）、一覧は出る"
# 一覧は利用者に見せるためのもので、第二意見へ渡すのは用途の 1 つにすぎない。
repo="$(mk_gate_repo)"
in_repo "$repo" "mkdir -p .claude && printf '{}\\n' > .claude/settings.json && git add -A && git $GIT_AUTHOR commit -q -m c2"
run_gate "$repo" LOOP_GATE_REVIEW_CMD=
if [[ "$GATE_OUT" == *"$MARK"*".claude/settings.json"* && "$GATE_OUT" == *"SKIP (disabled"* && "$GATE_RC" -eq 0 ]]; then pass; else fail "rc=$GATE_RC $GATE_OUT"; fi

it "第二意見のスクリプトが無い構成でも、一覧は出る"
rm -f "$repo/scripts/second-opinion-review.sh"
run_gate "$repo"
if [[ "$GATE_OUT" == *"$MARK"*".claude/settings.json"* && "$GATE_OUT" == *"SKIP (no reviewer present)"* && "$GATE_RC" -eq 0 ]]; then pass; else fail "rc=$GATE_RC $GATE_OUT"; fi

it "LOOP_GATE_REVIEW_CMD で差し替えたコマンドにも、同じ環境変数が届く"
repo="$(mk_gate_repo)"
in_repo "$repo" "mkdir -p .claude && printf '{}\n' > .claude/settings.json && git add -A && git $GIT_AUTHOR commit -q -m c2"
run_gate "$repo" LOOP_GATE_REVIEW_CMD='echo "CMD_PATHS:$SECOND_OPINION_AGENT_CONFIG_PATHS"; echo "[second-opinion] LGTM (engine=stub, runs=1)"'
if [[ "$GATE_RC" -eq 0 && "$GATE_OUT" == *"CMD_PATHS:.claude/settings.json"* && "$GATE_OUT" == *"$MARK"* ]]; then pass; else fail "rc=$GATE_RC $GATE_OUT"; fi

it "一覧が出ても、第二意見が失敗なら GATE_FAIL のまま（判定は変えない）"
run_gate "$repo" LOOP_GATE_REVIEW_CMD='echo "[second-opinion] findings"; exit 1'
if [[ "$GATE_RC" -eq 1 && "$GATE_OUT" == *"$MARK"* && "$GATE_OUT" == *"GATE_FAIL"* ]]; then pass; else fail "rc=$GATE_RC $GATE_OUT"; fi

it "レビュー対象が無い（起点との差が空）ときは一覧を出さない"
repo="$(mk_gate_repo)"
run_gate "$repo"
if [[ "$GATE_RC" -eq 0 && "$GATE_OUT" != *"$MARK"* && "$GATE_OUT" == *"no reviewable diff"* ]]; then pass; else fail "rc=$GATE_RC $GATE_OUT"; fi

exit_with_result
