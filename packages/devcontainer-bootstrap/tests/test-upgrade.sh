#!/usr/bin/env bash
# test-upgrade.sh — bootstrap.sh --upgrade の振り分けを検証する（#396 の 2/3）。
#
# 対象は DCB 自身のテンプレート（write_file の経路）。規範経由のファイル
# （install_playbook_rules の経路）への適用の検証は 3/3 で足す。

set -uo pipefail

# run-tests.sh を介さず直接実行されたときは、自前で一時領域を作って後で消す
# （受け入れ条件は `bash tests/test-upgrade.sh` が 0 で終わること）。
if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-upgrade-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-upgrade"

IMG="mcr.microsoft.com/devcontainers/base:noble"
ORIGIN_REL="/.devcontainer/ORIGIN"

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

# 生成物の全ファイル（相対パス + ハッシュ + モード）の一覧。前後比較用。
tree_state() {
  local f
  (cd "$1" && find . -type f | sort | while IFS= read -r f; do
    printf '%s %s %s\n' "$f" "$(sha_of "$f")" "$(mode_of "$f")"
  done)
}

gen() { # out [args...]
  local out="$1"; shift
  bash "$BOOTSTRAP" --project-name upg --languages node --base-image "$IMG" --output-dir "$out" "$@" >/dev/null 2>&1
}
upgrade() { # out [args...] — 出力は UP_OUT、終了コードは UP_RC
  local out="$1"; shift
  UP_OUT="$(bash "$BOOTSTRAP" --upgrade --output-dir "$out" "$@" 2>&1)"
  UP_RC=$?
}
set_record() { # origin rel hash
  sed "s|^hash:$2=.*|hash:$2=$3|" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
drop_record() { # origin rel
  grep -v "^hash:$2=" "$1" > "$1.tmp"; mv "$1.tmp" "$1"
}

# ── 受け入れ条件の本筋 ────────────────────────────────────────────────────────

out="$(new_workdir)/p"
gen "$out" --with-aws
origin="$out$ORIGIN_REL"

# 手を入れる（実行ビット付きの scripts/verify.sh）
echo "# my edit" >> "$out/scripts/verify.sh"
# 古い版の写し: 中身を変え、記録のハッシュも合わせる
echo "# old version" >> "$out/scripts/on-attach.sh"
set_record "$origin" "scripts/on-attach.sh" "$(sha_of "$out/scripts/on-attach.sh")"
# 記録を 1 件消す（現物も消す）
rm -f "$out/.env.example"
drop_record "$origin" ".env.example"
verify_mode="$(mode_of "$out/scripts/verify.sh")"
edited_sha="$(sha_of "$out/scripts/verify.sh")"

upgrade "$out"

it "--upgrade は *.dcb-new を残したときの専用の終了コード（2）で終わる"
assert_eq "$UP_RC" "2" "exit code"

it "手を入れたファイルは上書きされない"
assert_eq "$(sha_of "$out/scripts/verify.sh")" "$edited_sha" "verify.sh"

it "手を入れたファイルの隣に .dcb-new が置かれ、モードは元のファイルに揃う"
if [[ -f "$out/scripts/verify.sh.dcb-new" ]] \
  && [[ "$(mode_of "$out/scripts/verify.sh.dcb-new")" == "$verify_mode" ]] \
  && ! grep -q '# my edit' "$out/scripts/verify.sh.dcb-new"; then pass; else fail ".dcb-new が無い・モードが違う・内容が新しい版でない"; fi

it "手を入れたファイルの差分の要約が出る"
assert_contains "$UP_OUT" "keep (modified): $out/scripts/verify.sh" "出力"

it "手を入れたファイルのモードは変わらない"
assert_eq "$(mode_of "$out/scripts/verify.sh")" "$verify_mode" "mode"

it "古い版の写しは新しい版で更新される"
if ! grep -q '# old version' "$out/scripts/on-attach.sh" && [[ ! -e "$out/scripts/on-attach.sh.dcb-new" ]]; then pass; else fail "更新されていない、または .dcb-new が残った"; fi

it "記録が消えた（現物も無い）分は生成される"
assert_file_exists "$out/.env.example"

it "ORIGIN は書き直され、温存したファイルにも新しい版のハッシュが記録される"
new_rec="$(sed -n 's|^hash:scripts/verify\.sh=||p' "$origin")"
if [[ "$new_rec" == "$(sha_of "$out/scripts/verify.sh.dcb-new")" && "$new_rec" != "$edited_sha" ]] \
  && grep -q '^hash:\.env.example=' "$origin" && grep -q '^inputs-format=1' "$origin"; then pass; else fail "ORIGIN の記録が期待と違う"; fi

it "もう一度 --upgrade しても、手を入れたファイルは温存され続ける（終了コード 2）"
upgrade "$out"
if [[ "$UP_RC" == "2" && "$(sha_of "$out/scripts/verify.sh")" == "$edited_sha" ]]; then pass; else fail "rc=$UP_RC"; fi

it "手を入れたファイルを新しい版と同じ内容にすると、更新済みとして扱われ .dcb-new は消える"
cp "$out/scripts/verify.sh.dcb-new" "$out/scripts/verify.sh"
upgrade "$out"
if [[ "$UP_RC" == "0" && ! -e "$out/scripts/verify.sh.dcb-new" ]]; then pass; else fail "rc=$UP_RC"; fi

it "全件適用できたときの終了コードは 0（何も変えない再実行）"
upgrade "$out"
assert_eq "$UP_RC" "0" "exit code"

it "記録に無いが現物があり、新しい版と違うファイルは手を入れた扱い（.dcb-new）"
drop_record "$origin" "scripts/verify.sh"
echo "# local" >> "$out/scripts/verify.sh"
upgrade "$out"
if [[ "$UP_RC" == "2" && -f "$out/scripts/verify.sh.dcb-new" ]] && grep -q '# local' "$out/scripts/verify.sh"; then pass; else fail "rc=$UP_RC"; fi

# ── 新しい版で生成されなくなった分 ────────────────────────────────────────────

it "新しい版で生成されなくなった分は報告だけして削除せず、記録からは外す"
echo "hash:legacy/old-file.txt=0000" >> "$origin"
mkdir -p "$out/legacy" && echo x > "$out/legacy/old-file.txt"
upgrade "$out"
if [[ -f "$out/legacy/old-file.txt" ]] && printf '%s' "$UP_OUT" | grep -q 'no longer generated (not deleted): .*legacy/old-file.txt' \
  && ! grep -q 'legacy/old-file.txt' "$origin"; then pass; else fail "報告・温存・記録からの除外のいずれかが違う"; fi

# ── --dry-run ─────────────────────────────────────────────────────────────────

it "--upgrade --dry-run は 1 バイトも書かない（前後でツリーが同じ）"
rm -f "$out/scripts/verify.sh.dcb-new"
echo "# local2" >> "$out/scripts/on-attach.sh"
rm -f "$out/.env.example"
before="$(tree_state "$out")"
upgrade "$out" --dry-run
after="$(tree_state "$out")"
if [[ "$before" == "$after" && "$UP_RC" == "0" ]]; then pass; else fail "ツリーが変わった、または rc=$UP_RC"; fi

it "--dry-run は振り分けの計画を出す"
assert_contains "$UP_OUT" "plan: create $out/.env.example" "出力"

# ── 入力の再現 ────────────────────────────────────────────────────────────────

it "記録した入力（--with-*・言語）で生成し直す（引数なしで同じ構成になる）"
o2="$(new_workdir)/p"
gen "$o2" --with-aws --with-claude --playbook-from "$PLAYBOOK_SRC"
rm -f "$o2/.env.example"
upgrade "$o2" --playbook-from "$PLAYBOOK_SRC"
if [[ "$UP_RC" == "0" && -f "$o2/.env.example" ]] && grep -q '^flags=aws,claude$' "$o2$ORIGIN_REL"; then pass; else fail "rc=$UP_RC"; fi

it "ローカルの規範ソースは記録から再現できず、--playbook-from の明示を求めて止まる"
upgrade "$o2"
if [[ "$UP_RC" == "1" ]] && printf '%s' "$UP_OUT" | grep -q -- '--playbook-from'; then pass; else fail "rc=$UP_RC"; fi

it "引数で渡した --with-* は記録へ足される"
upgrade "$out" --with-gemini
if grep -q '^flags=aws,gemini$' "$origin"; then pass; else fail "flags=$(grep '^flags=' "$origin")"; fi

# ── 古い ORIGIN・ORIGIN なし ──────────────────────────────────────────────────

o3="$(new_workdir)/p"
gen "$o3" --with-aws
grep -v '^inputs-format=\|^input:' "$o3$ORIGIN_REL" > "$o3$ORIGIN_REL.tmp"; mv "$o3$ORIGIN_REL.tmp" "$o3$ORIGIN_REL"

it "条件の記録が無い古い ORIGIN では、引数を明示しないと止まり、案内を出す"
upgrade "$o3"
if [[ "$UP_RC" == "1" ]] && printf '%s' "$UP_OUT" | grep -q -- '--project-name' && printf '%s' "$UP_OUT" | grep -q -- '--languages'; then pass; else fail "rc=$UP_RC"; fi

it "古い ORIGIN でも、引数を明示すれば生成でき、記録し直される"
upgrade "$o3" --project-name upg --languages node --base-image "$IMG" --with-aws
if [[ "$UP_RC" == "0" ]] && grep -q '^inputs-format=1' "$o3$ORIGIN_REL" && grep -q '^flags=aws$' "$o3$ORIGIN_REL"; then pass; else fail "rc=$UP_RC"; fi

it "ORIGIN が無いディレクトリでも、引数を明示しないと止まる"
o4="$(new_workdir)/none"
upgrade "$o4"
if [[ "$UP_RC" == "1" && ! -e "$o4" ]]; then pass; else fail "rc=$UP_RC"; fi

# ── --force との同時指定 ──────────────────────────────────────────────────────

it "--upgrade と --force の同時指定はエラーで、何も書かない"
o5="$(new_workdir)/none"
UP_OUT="$(bash "$BOOTSTRAP" --upgrade --force --output-dir "$o5" 2>&1)"; UP_RC=$?
if [[ "$UP_RC" == "1" && ! -e "$o5" ]] && printf '%s' "$UP_OUT" | grep -q -- '--force'; then pass; else fail "rc=$UP_RC"; fi

# ── 従来の再実行・--force の挙動は変わらない ──────────────────────────────────

it "--upgrade を付けない再実行は、手を入れたファイルを温存し、*.dcb-new を作らない"
o6="$(new_workdir)/p"
gen "$o6"
echo "# mine" >> "$o6/scripts/verify.sh"
bash "$BOOTSTRAP" --project-name upg --languages node --base-image "$IMG" --output-dir "$o6" >/dev/null 2>&1
rc=$?
if [[ "$rc" == "0" ]] && grep -q '# mine' "$o6/scripts/verify.sh" && [[ ! -e "$o6/scripts/verify.sh.dcb-new" ]]; then pass; else fail "rc=$rc"; fi

it "--force は手を入れたファイルも上書きする"
bash "$BOOTSTRAP" --project-name upg --languages node --base-image "$IMG" --output-dir "$o6" --force >/dev/null 2>&1
if ! grep -q '# mine' "$o6/scripts/verify.sh"; then pass; else fail "上書きされていない"; fi

# ── シンボリックリンク・ORIGIN のモード・残った .dcb-new ──────────────────────

o7="$(new_workdir)/p"
gen "$o7"
outside="$(new_workdir)/outside"
mkdir -p "$outside"

it "生成先がシンボリックリンクなら、たどって書かず、手を入れた扱いで .dcb-new を置く"
echo "target" > "$outside/target.txt"
rm -f "$o7/scripts/verify.sh"
ln -s "$outside/target.txt" "$o7/scripts/verify.sh"
upgrade "$o7"
if [[ "$UP_RC" == "2" && "$(cat "$outside/target.txt")" == "target" && -L "$o7/scripts/verify.sh" \
  && -f "$o7/scripts/verify.sh.dcb-new" && ! -L "$o7/scripts/verify.sh.dcb-new" ]] \
  && printf '%s' "$UP_OUT" | grep -q 'keep (symlink'; then pass; else fail "rc=$UP_RC target=$(cat "$outside/target.txt")"; fi

it "切れたシンボリックリンクの生成先でも、リンク先を作らない"
rm -f "$o7/scripts/verify.sh" "$o7/scripts/verify.sh.dcb-new"
ln -s "$outside/missing.txt" "$o7/scripts/verify.sh"
upgrade "$o7"
if [[ ! -e "$outside/missing.txt" && -f "$o7/scripts/verify.sh.dcb-new" ]]; then pass; else fail "リンク先が作られた、または .dcb-new が無い"; fi

it ".dcb-new がシンボリックリンクなら、たどらず消して通常ファイルとして作る"
rm -f "$o7/scripts/verify.sh" "$o7/scripts/verify.sh.dcb-new"
cp "$o7/scripts/check-no-secrets.sh" "$o7/scripts/verify.sh"
echo "keep" > "$outside/dcbnew-target.txt"
ln -s "$outside/dcbnew-target.txt" "$o7/scripts/verify.sh.dcb-new"
upgrade "$o7"
if [[ "$(cat "$outside/dcbnew-target.txt")" == "keep" && -f "$o7/scripts/verify.sh.dcb-new" && ! -L "$o7/scripts/verify.sh.dcb-new" ]]; then pass; else fail "リンク先が書き換わった、または通常ファイルでない"; fi

it "親ディレクトリが出力先の外を指すシンボリックリンクなら、書かずに止まる（exit 1）"
o8="$(new_workdir)/p"
gen "$o8"
mkdir -p "$outside/scripts-copy"
echo "orig" > "$outside/scripts-copy/verify.sh"
rm -rf "$o8/scripts"
ln -s "$outside/scripts-copy" "$o8/scripts"
upgrade "$o8"
if [[ "$UP_RC" == "1" && "$(cat "$outside/scripts-copy/verify.sh")" == "orig" && "$(ls "$outside/scripts-copy")" == "verify.sh" ]]; then pass; else fail "rc=$UP_RC / 出力先の外: $(ls "$outside/scripts-copy")"; fi

it "--upgrade は既存の ORIGIN のモードを保つ（600 のまま）"
o9="$(new_workdir)/p"
gen "$o9"
chmod 600 "$o9$ORIGIN_REL"
upgrade "$o9"
assert_eq "$(mode_of "$o9$ORIGIN_REL")" "600" "ORIGIN のモード"

it "ORIGIN が無いところへ --upgrade で作るときは 644"
rm -f "$o9$ORIGIN_REL"
upgrade "$o9" --project-name upg --languages node --base-image "$IMG"
assert_eq "$(mode_of "$o9$ORIGIN_REL")" "644" "ORIGIN のモード"

it "生成対象から外れたファイルに以前の .dcb-new が残っていると、終了コード 2 で一覧を出す"
o10="$(new_workdir)/p"
gen "$o10"
echo "hash:legacy/old-file.txt=0000" >> "$o10$ORIGIN_REL"
mkdir -p "$o10/legacy"
echo x > "$o10/legacy/old-file.txt"
echo y > "$o10/legacy/old-file.txt.dcb-new"
upgrade "$o10"
if [[ "$UP_RC" == "2" ]] && printf '%s' "$UP_OUT" | grep -q 'legacy/old-file.txt.dcb-new'; then pass; else fail "rc=$UP_RC"; fi

it "従来の経路（--upgrade なし）の --force は ORIGIN を 644 にし、終了コードは 0"
o11="$(new_workdir)/p"
gen "$o11"
chmod 600 "$o11$ORIGIN_REL"
bash "$BOOTSTRAP" --project-name upg --languages node --base-image "$IMG" --output-dir "$o11" --force >/dev/null 2>&1
rc=$?
if [[ "$rc" == "0" && "$(mode_of "$o11$ORIGIN_REL")" == "644" ]]; then pass; else fail "rc=$rc mode=$(mode_of "$o11$ORIGIN_REL")"; fi

exit_with_result
