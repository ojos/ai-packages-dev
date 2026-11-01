#!/usr/bin/env bash
# test-claude-remote-control.sh — --claude-remote-control（#617）を検証する。
#
# 指定した構成で生成する install-ai-tools.sh が、~/.claude/settings.json に
# remoteControlAtStartup=true をマージすること。利用者の値（false を含む）は覆さず、
# 未指定の構成の出力は変えない。--upgrade が記録を引き継ぎ、doctor が行を不正としない。
#
# 生成した install-ai-tools.sh は全体を一時的な HOME で実行する。claude は PATH 上の
# stub で「導入済み（下限以上）」にするので CLI の導入（npm）は走らない。

set -uo pipefail
if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-crc-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-claude-remote-control"

DOCTOR="$(dirname "$BOOTSTRAP")/doctor.sh"
BASH_BIN="$(command -v bash)"

# claude を導入済みに見せる stub。版の下限の検査で --version だけは答える
# （下限以上の版）。それ以外で呼ばれたら異常。
STUB="$TEST_TMP_ROOT/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nif [[ "${1-}" == "--version" ]]; then echo "2.1.314 (Claude Code)"; exit 0; fi\nexit 97\n' > "$STUB/claude"; chmod +x "$STUB/claude"

# jq を含まない PATH。スクリプトが使うコマンドだけを写す。
NOJQ="$TEST_TMP_ROOT/nojq"; mkdir -p "$NOJQ"
for c in dirname mkdir chmod mktemp mv rm cat env tr grep head awk bash; do
  ln -s "$(command -v "$c")" "$NOJQ/$c" 2>/dev/null
done
cp "$STUB/claude" "$NOJQ/claude"

OUT="$(new_workdir)/p"
run_bootstrap "$OUT" --with-claude --claude-remote-control >/dev/null 2>&1
INSTALL="$OUT/scripts/install-ai-tools.sh"

new_home() { mktemp -d "$TEST_TMP_ROOT/home.XXXXXX"; }
# run_install <script> <home> [PATH]
run_install() { ( HOME="$2" PATH="${3:-$STUB:$PATH}" "$BASH_BIN" "$1" 2>&1 ); }
rc_of() { ( HOME="$2" PATH="${3:-$STUB:$PATH}" "$BASH_BIN" "$1" >/dev/null 2>&1; echo $? ); }

it "ORIGIN に input:claude-remote-control=true が記録される"
if grep -qx 'input:claude-remote-control=true' "$OUT/.devcontainer/ORIGIN" 2>/dev/null; then pass; else fail "記録が無い"; fi

it "settings.json が無ければ {\"remoteControlAtStartup\": true} ができる"
H="$(new_home)"; run_install "$INSTALL" "$H" >/dev/null; S="$H/.claude/settings.json"
if [[ "$(jq -c . "$S" 2>/dev/null)" == '{"remoteControlAtStartup":true}' ]]; then pass; else fail "$(cat "$S" 2>&1)"; fi

it "2 回実行しても結果が同じ"
before="$(cat "$S")"; run_install "$INSTALL" "$H" >/dev/null
if [[ "$(cat "$S")" == "$before" ]]; then pass; else fail "変わった: $(cat "$S")"; fi

it "既存のキーを保ったまま true が足される"
H="$(new_home)"; mkdir -p "$H/.claude"; echo '{"model":"x","permissions":{"allow":["a"]}}' > "$H/.claude/settings.json"
run_install "$INSTALL" "$H" >/dev/null
if [[ "$(jq -c . "$H/.claude/settings.json")" == '{"model":"x","permissions":{"allow":["a"]},"remoteControlAtStartup":true}' ]]; then pass; else fail "$(cat "$H/.claude/settings.json")"; fi

it "false があれば変わらない（バイト単位）"
H="$(new_home)"; mkdir -p "$H/.claude"; printf '{"remoteControlAtStartup": false}\n' > "$H/.claude/settings.json"
run_install "$INSTALL" "$H" >/dev/null
if [[ "$(cat "$H/.claude/settings.json")" == '{"remoteControlAtStartup": false}' ]]; then pass; else fail "$(cat "$H/.claude/settings.json")"; fi

it "JSON が壊れていれば警告して 0 で終わり、ファイルを変えない"
H="$(new_home)"; mkdir -p "$H/.claude"; printf '{broken' > "$H/.claude/settings.json"
o="$(run_install "$INSTALL" "$H")"; rc="$(rc_of "$INSTALL" "$H")"
if [[ "$rc" == 0 && "$o" == *warning:* && "$(cat "$H/.claude/settings.json")" == '{broken' ]]; then pass; else fail "rc=$rc $o"; fi

it "複数の JSON 値を連結した settings.json は、警告して 0 で終わり、ファイルを変えない"
H="$(new_home)"; mkdir -p "$H/.claude"; printf '{"remoteControlAtStartup": false}\n{"a": 1}\n' > "$H/.claude/settings.json"
before="$(cat "$H/.claude/settings.json")"
o="$(run_install "$INSTALL" "$H")"; rc="$(rc_of "$INSTALL" "$H")"
if [[ "$rc" == 0 && "$o" == *warning:* && "$(cat "$H/.claude/settings.json")" == "$before" ]]; then pass; else fail "rc=$rc $o"; fi

it "jq が無ければ警告を出して 0 で終わり、ファイルを作らない"
H="$(new_home)"
o="$(run_install "$INSTALL" "$H" "$NOJQ")"; rc="$(rc_of "$INSTALL" "$H" "$NOJQ")"
if [[ "$rc" == 0 && "$o" == *warning:*jq* && ! -e "$H/.claude/settings.json" ]]; then pass; else fail "rc=$rc $o"; fi

it "一時ファイルが settings.json の隣に残らない"
H="$(new_home)"; run_install "$INSTALL" "$H" >/dev/null
if [[ -z "$(ls -A "$H/.claude" | grep -v '^settings.json$')" ]]; then pass; else fail "$(ls -A "$H/.claude")"; fi

# ── 未指定の出力が不変 ───────────────────────────────────────────────────────
it "未指定の install-ai-tools.sh は Remote Control に関する記述を持たず、ORIGIN にも行が無い"
OUT_N="$(new_workdir)/p"
run_bootstrap "$OUT_N" --with-claude >/dev/null 2>&1
if ! grep -qi 'remote\|CLAUDE_USER_SETTINGS' "$OUT_N/scripts/install-ai-tools.sh" \
   && ! grep -q 'claude-remote-control' "$OUT_N/.devcontainer/ORIGIN"; then pass; else fail "混入している"; fi

# ── 検証・併用 ───────────────────────────────────────────────────────────────
it "--with-claude 無しの指定は、何も書かずに非 0 で止まる"
OUT_X="$(new_workdir)/p"
x_err="$(bash "$BOOTSTRAP" --project-name t --languages node --with-gemini --claude-remote-control --output-dir "$OUT_X" 2>&1 >/dev/null)"; x_rc=$?
if [[ "$x_rc" != 0 && "$x_err" == *"--with-claude"* && ! -e "$OUT_X/.devcontainer" ]]; then pass; else fail "rc=$x_rc err=$x_err"; fi

it "--accept と同時に指定すると止まる"
a_err="$(bash "$BOOTSTRAP" --accept scripts/install-ai-tools.sh --claude-remote-control --output-dir "$OUT" 2>&1 >/dev/null)"; a_rc=$?
if [[ "$a_rc" != 0 && "$a_err" == *"--accept"*"--claude-remote-control"* ]]; then pass; else fail "rc=$a_rc err=$a_err"; fi

it "usage に --claude-remote-control が載る"
if bash "$BOOTSTRAP" --help 2>&1 | grep -- '--claude-remote-control' >/dev/null; then pass; else fail "載っていない"; fi

# ── upgrade / doctor ─────────────────────────────────────────────────────────
it "--upgrade（指定なし）でも記録と生成物が残る"
if bash "$BOOTSTRAP" --upgrade --output-dir "$OUT" >/dev/null 2>&1 \
   && grep -qx 'input:claude-remote-control=true' "$OUT/.devcontainer/ORIGIN" \
   && grep -q 'enable_claude_remote_control' "$OUT/scripts/install-ai-tools.sh"; then pass; else fail "残っていない"; fi

it "doctor は ORIGIN の行を不正としない"
d_out="$(bash "$DOCTOR" --target-dir "$OUT" 2>&1)"
if [[ "$d_out" != *"input:claude-remote-control"* && "$d_out" != *"認識できない入力の行"* ]]; then pass; else fail "$d_out"; fi

it "doctor は true 以外の値を検出する"
OUT_B="$(new_workdir)/p"
run_bootstrap "$OUT_B" --with-claude --claude-remote-control >/dev/null 2>&1
python3 - "$OUT_B/.devcontainer/ORIGIN" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("input:claude-remote-control=true", "input:claude-remote-control=yes")
open(p, "w").write(s)
PY
d_out="$(bash "$DOCTOR" --target-dir "$OUT_B" 2>&1)"
if [[ "$d_out" == *"input:claude-remote-control が"* ]]; then pass; else fail "検出していない: $d_out"; fi

it "doctor は flags= に claude が無いのに行がある ORIGIN を検出する"
OUT_F="$(new_workdir)/p"
run_bootstrap "$OUT_F" --with-claude --claude-remote-control >/dev/null 2>&1
python3 - "$OUT_F/.devcontainer/ORIGIN" <<'PY'
import sys
p = sys.argv[1]
lines = ["flags=" if l.startswith("flags=") else l for l in open(p).read().split("\n")]
open(p, "w").write("\n".join(lines))
PY
d_out="$(bash "$DOCTOR" --target-dir "$OUT_F" 2>&1)"
if [[ "$d_out" == *"flags= に claude が無い"* ]]; then pass; else fail "検出していない: $d_out"; fi

it "ORIGIN の値が true 以外（True）なら、--upgrade は ORIGIN の破損として止まる"
OUT_T="$(new_workdir)/p"
run_bootstrap "$OUT_T" --with-claude --claude-remote-control >/dev/null 2>&1
python3 - "$OUT_T/.devcontainer/ORIGIN" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("input:claude-remote-control=true", "input:claude-remote-control=True")
open(p, "w").write(s)
PY
t_err="$(bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_T" 2>&1 >/dev/null)"; t_rc=$?
if [[ "$t_rc" != 0 && "$t_err" == *ORIGIN*input:claude-remote-control* ]]; then pass; else fail "rc=$t_rc err=$t_err"; fi

it "ORIGIN の値が空（input:claude-remote-control=）でも、--upgrade は ORIGIN の破損として止まる"
OUT_E="$(new_workdir)/p"
run_bootstrap "$OUT_E" --with-claude --claude-remote-control >/dev/null 2>&1
python3 - "$OUT_E/.devcontainer/ORIGIN" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read().replace("input:claude-remote-control=true", "input:claude-remote-control=")
open(p, "w").write(s)
PY
e_err="$(bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_E" 2>&1 >/dev/null)"; e_rc=$?
if [[ "$e_rc" != 0 && "$e_err" == *ORIGIN*input:claude-remote-control* ]]; then pass; else fail "rc=$e_rc err=$e_err"; fi

it "--upgrade --no-claude-remote-control は、破損した値があっても記録を外して生成できる"
if bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_T" --no-claude-remote-control >/dev/null 2>&1 \
   && ! grep -q 'claude-remote-control' "$OUT_T/.devcontainer/ORIGIN"; then pass; else fail "外せない"; fi

it "行が無い古い ORIGIN でも --upgrade は止まらない"
OUT_O="$(new_workdir)/p"
run_bootstrap "$OUT_O" --with-claude >/dev/null 2>&1
if bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_O" >/dev/null 2>&1 && ! grep -q 'claude-remote-control' "$OUT_O/.devcontainer/ORIGIN"; then pass; else fail "止まった/行が増えた"; fi

it "--upgrade --claude-remote-control で後から有効にできる"
if bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_O" --claude-remote-control >/dev/null 2>&1 \
   && grep -qx 'input:claude-remote-control=true' "$OUT_O/.devcontainer/ORIGIN"; then pass; else fail "有効にできない"; fi

it "記録があるのに --without-claude で --upgrade すると、警告して記録を外す"
w_err="$(bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_O" --without-claude 2>&1 >/dev/null)"; w_rc=$?
if [[ "$w_rc" == 0 && "$w_err" == *warning:*ORIGIN* ]] && ! grep -q 'claude-remote-control' "$OUT_O/.devcontainer/ORIGIN"; then pass; else fail "rc=$w_rc err=$w_err"; fi

it "--upgrade --no-claude-remote-control で記録と生成物の処理が外れる"
OUT_R="$(new_workdir)/p"
run_bootstrap "$OUT_R" --with-claude --claude-remote-control >/dev/null 2>&1
if bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_R" --no-claude-remote-control >/dev/null 2>&1 \
   && ! grep -q 'claude-remote-control' "$OUT_R/.devcontainer/ORIGIN" \
   && ! grep -q 'enable_claude_remote_control' "$OUT_R/scripts/install-ai-tools.sh"; then pass; else fail "外れていない"; fi

it "--no-claude-remote-control を生成時に単独で使っても、未指定と同じ"
OUT_S="$(new_workdir)/p"; OUT_U="$(new_workdir)/p"
run_bootstrap "$OUT_S" --with-claude --no-claude-remote-control >/dev/null 2>&1
run_bootstrap "$OUT_U" --with-claude >/dev/null 2>&1
if cmp -s "$OUT_S/scripts/install-ai-tools.sh" "$OUT_U/scripts/install-ai-tools.sh" \
   && ! grep -q 'claude-remote-control' "$OUT_S/.devcontainer/ORIGIN"; then pass; else fail "未指定と違う"; fi

it "--claude-remote-control と --no-claude-remote-control の同時指定は止まる"
c_err="$(bash "$BOOTSTRAP" --project-name t --languages node --with-claude --claude-remote-control --no-claude-remote-control --output-dir "$(new_workdir)/p" 2>&1 >/dev/null)"; c_rc=$?
if [[ "$c_rc" != 0 && "$c_err" == *"同時に指定できません"* ]]; then pass; else fail "rc=$c_rc err=$c_err"; fi

it "--accept と --no-claude-remote-control の同時指定は止まる"
n_err="$(bash "$BOOTSTRAP" --accept scripts/install-ai-tools.sh --no-claude-remote-control --output-dir "$OUT" 2>&1 >/dev/null)"; n_rc=$?
if [[ "$n_rc" != 0 && "$n_err" == *"--accept"*"--no-claude-remote-control"* ]]; then pass; else fail "rc=$n_rc err=$n_err"; fi

it "--upgrade --dry-run の警告は「外すことになります」と読め、ORIGIN を変えない"
OUT_D="$(new_workdir)/p"
run_bootstrap "$OUT_D" --with-claude --claude-remote-control >/dev/null 2>&1
before_o="$(cat "$OUT_D/.devcontainer/ORIGIN")"
dr_err="$(bash "$BOOTSTRAP" --upgrade --dry-run --output-dir "$OUT_D" --without-claude 2>&1 >/dev/null)"
if [[ "$dr_err" == *"外すことになります"* && "$(cat "$OUT_D/.devcontainer/ORIGIN")" == "$before_o" ]]; then pass; else fail "err=$dr_err"; fi

# ── 書き込めない・シンボリックリンク・権限 ───────────────────────────────────
it "書けない ~/.claude でも 0 で終わり、警告が出て、一時ファイルが残らない"
if [[ "$(id -u)" == 0 ]]; then
  pass  # root は権限で拒否されないので検査できない
else
  H="$(new_home)"; mkdir -p "$H/.claude"; chmod 500 "$H/.claude"
  o="$(run_install "$INSTALL" "$H")"; rc="$(rc_of "$INSTALL" "$H")"
  chmod 700 "$H/.claude"
  if [[ "$rc" == 0 && "$o" == *warning:* && -z "$(ls -A "$H/.claude")" ]]; then pass; else fail "rc=$rc $o"; fi
fi

it "~/.claude を作れない（HOME が書けない）ときも 0 で終わり、警告が出る"
if [[ "$(id -u)" == 0 ]]; then
  pass
else
  H="$(new_home)"; chmod 500 "$H"
  o="$(run_install "$INSTALL" "$H")"; rc="$(rc_of "$INSTALL" "$H")"
  chmod 700 "$H"
  if [[ "$rc" == 0 && "$o" == *warning:* ]]; then pass; else fail "rc=$rc $o"; fi
fi

it "読み取り専用の settings.json は、親ディレクトリに書けても置き換えず、警告して 0 で終わる"
if [[ "$(id -u)" == 0 ]]; then
  pass  # root は権限で拒否されないので検査できない
else
  H="$(new_home)"; mkdir -p "$H/.claude"; printf '{"a": 1}\n' > "$H/.claude/settings.json"; chmod 400 "$H/.claude/settings.json"
  o="$(run_install "$INSTALL" "$H")"; rc="$(rc_of "$INSTALL" "$H")"
  if [[ "$rc" == 0 && "$o" == *warning:* && "$(cat "$H/.claude/settings.json")" == '{"a": 1}' ]]; then pass; else fail "rc=$rc $o"; fi
  chmod 600 "$H/.claude/settings.json"
fi

it "settings.json がシンボリックリンクなら書き換えず、警告して 0 で終わる"
H="$(new_home)"; mkdir -p "$H/.claude" "$H/dot"; echo '{"a":1}' > "$H/dot/s.json"; ln -s "$H/dot/s.json" "$H/.claude/settings.json"
o="$(run_install "$INSTALL" "$H")"; rc="$(rc_of "$INSTALL" "$H")"
if [[ "$rc" == 0 && "$o" == *warning:* && -L "$H/.claude/settings.json" && "$(cat "$H/dot/s.json")" == '{"a":1}' ]]; then pass; else fail "rc=$rc $o"; fi

it "既存のファイルを書き換えても元の権限を保つ"
H="$(new_home)"; mkdir -p "$H/.claude"; echo '{"a":1}' > "$H/.claude/settings.json"; chmod 644 "$H/.claude/settings.json"
run_install "$INSTALL" "$H" >/dev/null
m="$(stat -c %a "$H/.claude/settings.json" 2>/dev/null || stat -f %Lp "$H/.claude/settings.json")"
if [[ "$m" == 644 ]]; then pass; else fail "権限 $m"; fi

it "新規に作るファイルは 600"
H="$(new_home)"; run_install "$INSTALL" "$H" >/dev/null
m="$(stat -c %a "$H/.claude/settings.json" 2>/dev/null || stat -f %Lp "$H/.claude/settings.json")"
if [[ "$m" == 600 ]]; then pass; else fail "権限 $m"; fi

exit_with_result
