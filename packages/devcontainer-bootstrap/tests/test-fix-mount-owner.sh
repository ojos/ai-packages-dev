#!/usr/bin/env bash
# test-fix-mount-owner.sh — 永続 volume の所有権修復スクリプトを検証する。
#
# 空の named volume を初回マウントすると、マウントポイントは Docker デーモン（root）に
# より root:root 所有で作られる。remoteUser が書き込めず、gh / AI CLI のログインが
# Permission denied で落ちる。修復は CLI 導入より前に、非対話で、失敗しても後続を
# 止めずに走らなければならない。ここではその 3 点を生成物に対して検証する。
#
# 実際の chown は root 権限を要するためテストしない。代わりに「非対話であること」
# 「失敗しても exit 0 であること」「マウントされていないパスを触らないこと」という、
# 壊れると気づきにくい性質を、sudo を差し替えた実行で確かめる。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-fix-mount-owner"

out="$(new_workdir)/p"
run_bootstrap "$out" --with-claude >/dev/null 2>&1
FMO="$out/scripts/fix-mount-owner.sh"
DC="$out/.devcontainer/devcontainer.json"

# ── 生成物として独立していること ──────────────────────────────────────────────

it "fix-mount-owner.sh が生成される"
assert_file_exists "$FMO"

it "実行可能な構文である"
if bash -n "$FMO" 2>/dev/null; then pass; else fail "syntax error"; fi

it "install-ai-tools.sh より前に実行される"
# 文字列の前後ではなく、&& の左辺にあることを見る。右辺に置くと、CLI 導入が
# 失敗した場合に所有権修復まで到達しない。
pcc="$(jq -r '.postCreateCommand' "$DC")"
left="${pcc%%&&*}"
right="${pcc#*&&}"
if printf '%s' "$left" | grep -q 'fix-mount-owner.sh' \
   && printf '%s' "$right" | grep -q 'install-ai-tools.sh'; then
  pass
else
  fail "postCreateCommand の順序が違う: $pcc"
fi

it "doctor が fix-mount-owner.sh の存在を検査する"
output="$(bash "$PKG_DIR/doctor.sh" --target-dir "$out" --strict 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]] && printf '%s' "$output" | grep -q 'scripts/fix-mount-owner.sh'; then
  pass
else
  fail "doctor が検査していない、または --strict が非ゼロ (rc=$rc)"
fi

it "doctor: fix-mount-owner.sh が無いと失敗する"
missing="$(new_workdir)/m"
cp -R "$out" "$missing"
rm "$missing/scripts/fix-mount-owner.sh"
output="$(bash "$PKG_DIR/doctor.sh" --target-dir "$missing" 2>&1)"
if [[ $? -ne 0 ]] && printf '%s' "$output" | grep -q 'fix-mount-owner.sh missing'; then
  pass
else
  fail "欠落を検出できない"
fi

# ── 非対話であること ──────────────────────────────────────────────────────────

it "sudo を -n（非対話）で呼ぶ"
# -n が無いと、パスワードを要求する環境で postCreate が入力待ちのまま固まる。
if grep -qE 'sudo -n chown' "$FMO" && ! grep -qE 'sudo chown' "$FMO"; then
  pass
else
  fail "sudo -n を使っていない: $(grep -n 'sudo' "$FMO" | tr '\n' ' ')"
fi

# 生成物は対象を絶対パス（/home/vscode/...）で持つため、HOME を差し替えても対象は
# 変わらない。関数定義だけを取り出し、テスト用のパスに対して適用する。
# 関数定義は先頭の log() から、最初の呼び出し行（fix_mount "...") の直前まで。
fmo_funcs="$(awk '/^log\(\)/ { inside = 1 } /^fix_mount "/ { inside = 0 } inside' "$FMO")"

it "sudo 不在でも異常終了しない"
probe="$(new_workdir)/nosudo"
mkdir -p "$probe"
target="$probe/target"; mkdir -p "$target"
# sudo を含まない最小 PATH を組み立てる。/usr/bin をそのまま残すと、そこに sudo が
# ある一般的な環境（/usr/bin/sudo）で分岐を通らず、検証にならない。
nosudo_bin="$probe/bin"
mkdir -p "$nosudo_bin"
for c in bash id dirname chown; do
  src="$(command -v "$c" 2>/dev/null || true)"
  [[ -n "$src" ]] && ln -sf "$src" "$nosudo_bin/$c"
done
# 所有者判定を「自分ではない」に倒す。テスト実行ユーザー所有のままだと冪等の
# 早期 return に入り、sudo 不在の分岐へ到達しない。
cat > "$nosudo_bin/stat" <<'STUB'
#!/usr/bin/env bash
echo "someone-else"
STUB
chmod +x "$nosudo_bin/stat"
it_sudo_visible="$(env PATH="$nosudo_bin" bash -c 'command -v sudo || true')"
if [[ -n "$it_sudo_visible" ]]; then
  fail "テストの前提が崩れている（PATH に sudo が残る: $it_sudo_visible）"
else
  output="$(env PATH="$nosudo_bin" HOME="$probe" bash -c "
set -uo pipefail
$fmo_funcs
fix_mount '$target'
exit 0
" 2>&1)"
  rc=$?
  if [[ "$rc" -eq 0 ]] && printf '%s' "$output" | grep -q 'sudo not available'; then
    pass
  else
    fail "sudo 不在の分岐を通っていない (rc=$rc): $output"
  fi
fi

# ── 失敗しても後続へ進めること ────────────────────────────────────────────────

# sudo をスタブに差し替えて必ず失敗させ、stat も「別ユーザー所有」に倒す。
stub="$(new_workdir)/stub"
mkdir -p "$stub/bin"
cat > "$stub/bin/sudo" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
cat > "$stub/bin/stat" <<'STUB'
#!/usr/bin/env bash
echo "someone-else"
STUB
chmod +x "$stub/bin/sudo" "$stub/bin/stat"

it "chown が失敗しても exit 0 で終わる"
# ここで非ゼロを返すと postCreate の && が切れ、CLI 導入まで到達しなくなる。
work="$(new_workdir)/w"; mkdir -p "$work/.config/gh"
output="$(env PATH="$stub/bin:$PATH" HOME="$work" bash -c "
set -uo pipefail
$fmo_funcs
fix_mount '$work/.config/gh'
exit 0
" 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]]; then pass; else fail "chown 失敗で非ゼロ終了 (rc=$rc): $output"; fi

it "chown 失敗を WARN として可視化する"
assert_contains "$output" "WARN" "失敗時の出力"

it "生成物全体としても chown 失敗で exit 0 になる"
# 実行時の対象は絶対パスであり、この環境に存在しないものは skip される。
# ここで見たいのは「スクリプト全体が非ゼロを返さないこと」。
output="$(env PATH="$stub/bin:$PATH" bash "$FMO" 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]]; then pass; else fail "非ゼロ終了 (rc=$rc): $output"; fi

it "マウントされていないディレクトリは触らない"
# 存在しないパスへ chown をかけると、毎回 WARN が出て本当の失敗が埋もれる。
output="$(env PATH="$stub/bin:$PATH" HOME="$work" bash -c "
set -uo pipefail
$fmo_funcs
fix_mount '$work/never/created'
exit 0
" 2>&1)"
if printf '%s' "$output" | grep -q 'does not exist, skipping' \
   && ! printf '%s' "$output" | grep -q 'WARN'; then
  pass
else
  fail "不在パスの扱いが違う: $output"
fi

it "既に自分の所有なら chown を試みない"
# 冪等性。毎回 chown -R すると、大きな設定ディレクトリで無駄な再帰 I/O が走る。
# ここでは stat を差し替えない（実際の所有者はテスト実行ユーザー自身）。
output="$(env HOME="$work" bash -c "
set -uo pipefail
$fmo_funcs
fix_mount '$work/.config/gh'
exit 0
" 2>&1)"
if printf '%s' "$output" | grep -q 'already owned by'; then
  pass
else
  fail "所有者一致時に skip していない: $output"
fi

it "親ディレクトリも修復対象になる（ネストしたマウント先）"
output="$(env PATH="$stub/bin:$PATH" HOME="$work" bash -c "
set -uo pipefail
$fmo_funcs
fix_mount '$work/.config/gh'
exit 0
" 2>&1)"
assert_contains "$output" "$work/.config" "親ディレクトリへの言及"

# ── 親ディレクトリの扱い ──────────────────────────────────────────────────────

it "ネストしたマウント先では親も対象にする"
# ~/.config/gh の親 ~/.config が root:root で作られる経路があるため、親も直す。
if grep -q 'fix_parent "$(dirname "$dir")"' "$FMO"; then pass; else fail "親の修復が無い"; fi

it "親は非再帰で直す（無関係な設定を巻き込まない）"
# ~/.config 配下には他ツールの設定も入る。再帰 chown は影響範囲が読めない。
if grep -q 'sudo_chown shallow "$parent"' "$FMO"; then pass; else fail "親を再帰 chown している"; fi

it "HOME 自身は親として直さない"
if grep -q '\[\[ "$parent" != "$HOME" && "$parent" != "/" \]\]' "$FMO"; then
  pass
else
  fail "HOME / ルートの除外が無い"
fi

exit_with_result
