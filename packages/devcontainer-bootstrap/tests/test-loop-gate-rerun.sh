#!/usr/bin/env bash
# 生成される scripts/loop-gate.sh が、第二意見より前に、保存した再現テストの再実行
# （second-opinion-review.sh --rerun-saved）を呼ぶことを検証する。
#
# まだ再現する（再実行の終了コードが 3）なら、第二意見を呼ばずに GATE_FAIL。通れば第二意見へ進む。
# ほかの失敗（再実行できなかった）は警告だけ出して、第二意見へ進む。
# 再実行には第二意見と同じ範囲（--range <起点>..HEAD か --base <起点>）を渡す。
# --rerun-saved を持たない古い版の reviewer では呼ばない（版のずれで止めない）。
# LOOP_GATE_REVIEW_CMD で差し替え・無効化したとき、レビュー対象が無いときも呼ばない。
#
# 検証の仕方: 第二意見を stub に差し替え、呼ばれた引数を順に記録して観測する。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-loop-gate-rerun"

GIT_AUTHOR='-c user.name=T -c user.email=t@example.com'

in_repo() { ( cd "$1" && eval "$2" ) >/dev/null 2>&1; }

acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
STUB_LOG="$(new_workdir)/calls"

# 再実行の口を持つ版の stub。呼ばれた引数を STUB_LOG へ記録し、FAKE_RERUN（pass / still / error）で答える。
write_stub_new() {
  cat > "${1}/scripts/second-opinion-review.sh" <<'STUB'
#!/usr/bin/env bash
echo "CALL:$*" >> "$STUB_LOG"
if [[ "${1-}" == "--rerun-saved" ]]; then
  echo "[second-opinion] rerun: stub"
  case "${FAKE_RERUN:-pass}" in pass) exit 0 ;; still) exit 3 ;; *) exit 1 ;; esac
fi
echo "[second-opinion] LGTM (engine=stub, runs=1)"
exit 0
STUB
}

# 再実行の口を持たない古い版の stub（再実行の旗の綴りを本文に含めない）。
write_stub_old() {
  cat > "${1}/scripts/second-opinion-review.sh" <<'STUB'
#!/usr/bin/env bash
echo "CALL:$*" >> "$STUB_LOG"
echo "[second-opinion] LGTM (engine=stub, runs=1)"
exit 0
STUB
}

# 既定ブランチ main と、そこから切った feat を持つ生成物のリポジトリを作る。
mk_gate_repo() {
  local repo origin
  repo="$(new_workdir)/p"; origin="$(new_workdir)/origin.git"
  run_bootstrap "$repo" >/dev/null 2>&1
  write_stub_new "$repo"
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
  : > "$STUB_LOG"
  GATE_OUT="$(cd "$repo" && env ALLOWED_AUTHOR_EMAILS="t@example.com" VERIFY_ACCEPTANCE="$acc" STUB_LOG="$STUB_LOG" "$@" bash scripts/loop-gate.sh 2>&1)"
  GATE_RC=$?
  CALLS="$(cat "$STUB_LOG")"
}

repo="$(mk_gate_repo)"
in_repo "$repo" "printf 'x\n' > a.txt && git add -A && git $GIT_AUTHOR commit -q -m c2"
base="$(cd "$repo" && git merge-base origin/main HEAD)"

it "保存した再現テストがまだ再現する（終了コード 3）なら、第二意見を呼ばずに GATE_FAIL"
run_gate "$repo" FAKE_RERUN=still
if [[ "$GATE_RC" -eq 1 && "$GATE_OUT" == *"GATE_FAIL"* && "$GATE_OUT" == *"saved reproduction tests still reproduce"* \
   && "$CALLS" == "CALL:--rerun-saved --range $base..HEAD" ]]; then
  pass
else
  fail "rc=$GATE_RC calls=[$CALLS] $GATE_OUT"
fi

it "再実行がほかの理由で失敗したら（終了コード 1）、警告だけ出して第二意見へ進む"
run_gate "$repo" FAKE_RERUN=error
expected="CALL:--rerun-saved --range $base..HEAD
CALL:--range $base..HEAD"
if [[ "$GATE_RC" -eq 0 && "$GATE_OUT" == *"保存した再現テストを再実行できませんでした（終了コード 1"* && "$CALLS" == "$expected" ]]; then
  pass
else
  fail "rc=$GATE_RC calls=[$CALLS] $GATE_OUT"
fi

it "再実行が通れば、同じ範囲で第二意見へ進む（再実行が先）"
run_gate "$repo" FAKE_RERUN=pass
expected="CALL:--rerun-saved --range $base..HEAD
CALL:--range $base..HEAD"
if [[ "$GATE_RC" -eq 0 && "$GATE_OUT" == *"GATE_PASS"* && "$CALLS" == "$expected" ]]; then pass; else fail "rc=$GATE_RC calls=[$CALLS] $GATE_OUT"; fi

it "ステージ済みの差分があるときは、再実行にも --base <起点> を渡す"
in_repo "$repo" "printf 'y\n' > b.txt && git add b.txt"
run_gate "$repo" FAKE_RERUN=pass
expected="CALL:--rerun-saved --base $base
CALL:--base $base"
if [[ "$GATE_RC" -eq 0 && "$CALLS" == "$expected" ]]; then pass; else fail "rc=$GATE_RC calls=[$CALLS] $GATE_OUT"; fi
in_repo "$repo" "git reset -q && rm -f b.txt"

it "再実行の口を持たない古い版の reviewer では、再実行を呼ばずに第二意見だけを回す"
write_stub_old "$repo"
in_repo "$repo" "git add -A && git $GIT_AUTHOR commit -q -m stub-old"
run_gate "$repo" FAKE_RERUN=still
if [[ "$GATE_RC" -eq 0 && "$CALLS" == "CALL:--range $base..HEAD" ]]; then pass; else fail "rc=$GATE_RC calls=[$CALLS] $GATE_OUT"; fi
write_stub_new "$repo"
in_repo "$repo" "git add -A && git $GIT_AUTHOR commit -q -m stub-new"

it "LOOP_GATE_REVIEW_CMD で差し替え・無効化したときは、再実行を呼ばない"
run_gate "$repo" FAKE_RERUN=still LOOP_GATE_REVIEW_CMD='echo "[second-opinion] LGTM (engine=stub, runs=1)"'
rc1="$GATE_RC"; calls1="$CALLS"
run_gate "$repo" FAKE_RERUN=still LOOP_GATE_REVIEW_CMD=
if [[ "$rc1" -eq 0 && -z "$calls1" && "$GATE_RC" -eq 0 && -z "$CALLS" ]]; then pass; else fail "rc1=$rc1 calls1=[$calls1] rc=$GATE_RC calls=[$CALLS] $GATE_OUT"; fi

it "レビュー対象が無い（起点との差が空）ときは、再実行を呼ばない"
repo="$(mk_gate_repo)"
run_gate "$repo" FAKE_RERUN=still
if [[ "$GATE_RC" -eq 0 && -z "$CALLS" && "$GATE_OUT" == *"no reviewable diff"* ]]; then pass; else fail "rc=$GATE_RC calls=[$CALLS] $GATE_OUT"; fi

exit_with_result
