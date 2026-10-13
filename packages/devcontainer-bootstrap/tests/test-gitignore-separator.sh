#!/usr/bin/env bash
# test-gitignore-separator.sh — .gitignore の管理区画の手前の空行が累積しないことを検証する（#460）。
#
# 区画の外にある区切りの空行は awk の除去対象にならないため、以前は
# --upgrade のたびに 1 行ずつ増えていた。区切りは常に 1 行であること、
# 累積済みのファイルも 1 回の実行で 1 行に戻ることを確かめる。

set -uo pipefail

if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-gitignore-separator-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-gitignore-separator"

IMG="mcr.microsoft.com/devcontainers/base:noble"
BEGIN_MARK="# >>> devcontainer-bootstrap managed section >>>"

# 管理区画には github/gitignore のテンプレートを curl で取得して入れる。取得の成否や
# 公開内容が実行ごとに変わると「同じ入力」にならないため、curl を固定の出力へ差し替える。
STUB_BIN="$(new_workdir)/bin"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\nprintf "%%s\\n" "stub-template-entry"\n' > "$STUB_BIN/curl"
chmod +x "$STUB_BIN/curl"
export PATH="$STUB_BIN:$PATH"

gen() { # out [args...]
  local out="$1"; shift
  bash "$BOOTSTRAP" --project-name sep --languages node --base-image "$IMG" --output-dir "$out" "$@" >/dev/null 2>&1
}
upgrade() { # out — 終了コードは UP_RC
  bash "$BOOTSTRAP" --upgrade --output-dir "$1" >/dev/null 2>&1
  UP_RC=$?
}
# 管理区画の開始行の直前に並ぶ空行の数
blank_lines_before_section() {
  awk -v start="$BEGIN_MARK" '
    $0 == start {print n; exit}
    /^[[:space:]]*$/ {n++; next}
    {n=0}
  ' "$1"
}

# ── --upgrade を繰り返しても変わらない ───────────────────────────────────────

out="$(new_workdir)/p"
mkdir -p "$out"
printf 'node_modules\nmy-local-file\n' > "$out/.gitignore"
gen "$out"

it "管理区画のテンプレートは差し替えた curl から入る（入力が固定されている）"
if grep -qx 'stub-template-entry' "$out/.gitignore"; then pass; else fail "差し替えが効いていない"; fi

it "生成直後、プロジェクトの記述と管理区画の間の空行は 1 行"
assert_eq "$(blank_lines_before_section "$out/.gitignore")" "1"

upgrade "$out"; rc1=$UP_RC
first="$(cksum < "$out/.gitignore")"
upgrade "$out"; rc2=$UP_RC
second="$(cksum < "$out/.gitignore")"

it "--upgrade は 2 回とも成功する"
assert_eq "$rc1,$rc2" "0,0"

it "--upgrade を 2 回続けても、2 回目で .gitignore が変わらない"
assert_eq "$second" "$first"

it "--upgrade を重ねても、区切りの空行は 1 行のまま"
assert_eq "$(blank_lines_before_section "$out/.gitignore")" "1"

it "プロジェクトの記述は残る"
if grep -qx 'my-local-file' "$out/.gitignore"; then pass; else fail "my-local-file が消えた"; fi

# ── 累積済みの空行は 1 回で 1 行に戻る ──────────────────────────────────────

tmp="$(new_workdir)/g"
{ printf 'my-local-file\n\n\n\n'; sed -n "/^${BEGIN_MARK}\$/,\$p" "$out/.gitignore"; } > "$tmp"
cp "$tmp" "$out/.gitignore"
upgrade "$out"
it "空行が累積した .gitignore への --upgrade も成功する"
assert_eq "$UP_RC" "0"
it "区画がある .gitignore では、区画の外の空行を変えない（3 行のまま。#538）"
assert_eq "$(blank_lines_before_section "$out/.gitignore")" "3"

# ── プロジェクトの記述が無ければ、先頭に空行を作らない ─────────────────────

it "既存の .gitignore が空行だけなら、区画の手前に空行を残さない"
out2="$(new_workdir)/q"
mkdir -p "$out2"
printf '\n\n' > "$out2/.gitignore"
gen "$out2"
assert_eq "$(head -n1 "$out2/.gitignore")" "$BEGIN_MARK"

# ── 区画の外の行は位置と順序を保つ（#538） ──────────────────────────────────

END_MARK="# <<< devcontainer-bootstrap managed section <<<"
# 区画の前後に外の行がある .gitignore を作る（区画の中身は古い版を模した 1 行）
make_around() { # out
  mkdir -p "$1"
  printf 'before-1\n!keep.txt\n\n%s\nold-entry\n%s\nafter-1\n*.log\n!after-neg\n' "$BEGIN_MARK" "$END_MARK" > "$1/.gitignore"
}
# 区画を <SEC> 1 行に置き換えた、外の行の並び
outside_lines() {
  awk -v s="$BEGIN_MARK" -v e="$END_MARK" '$0==s{k=1;print "<SEC>";next} $0==e{k=0;next} !k{print}' "$1"
}
EXPECT_OUTSIDE="$(printf 'before-1\n!keep.txt\n\n<SEC>\nafter-1\n*.log\n!after-neg')"

run_mode() { # mode out
  case "$1" in
    upgrade) bash "$BOOTSTRAP" --upgrade --output-dir "$2" >/dev/null 2>&1 ;;
    rerun) bash "$BOOTSTRAP" --project-name sep --languages node --base-image "$IMG" --output-dir "$2" >/dev/null 2>&1 ;;
    force) bash "$BOOTSTRAP" --project-name sep --languages node --base-image "$IMG" --output-dir "$2" --force >/dev/null 2>&1 ;;
  esac
}

for mode in upgrade rerun force; do
  o="$(new_workdir)/pos-$mode"
  if [[ "$mode" == "upgrade" ]]; then
    mkdir -p "$o"; gen "$o"
    # 生成済みの区画の前後へ外の行を足した状態にする
    { printf 'before-1\n!keep.txt\n\n'; sed -n "/^${BEGIN_MARK}\$/,/^${END_MARK}\$/p" "$o/.gitignore"; printf 'after-1\n*.log\n!after-neg\n'; } > "$o/.gitignore.new"
    mv "$o/.gitignore.new" "$o/.gitignore"
  else
    make_around "$o"
  fi
  run_mode "$mode" "$o"; rc=$?
  it "$mode: 区画の前後に外の行があっても成功する"
  assert_eq "$rc" "0"
  it "$mode: 前の行は前に、後ろの行は後ろに、同じ順序で残る"
  assert_eq "$(outside_lines "$o/.gitignore")" "$EXPECT_OUTSIDE"
  it "$mode: 区画の中身が差し替わっている（古い行が消え、新しい行が入る）"
  if ! grep -qx 'old-entry' "$o/.gitignore" && grep -qx 'stub-template-entry' "$o/.gitignore"; then pass; else fail "差し替わっていない"; fi
  h1="$(cksum < "$o/.gitignore")"
  run_mode "$mode" "$o"
  it "$mode: 2 回続けても内容が変わらない（空行が累積しない）"
  assert_eq "$(cksum < "$o/.gitignore")" "$h1"
done

# 空行 2 行・空白だけの行が区画の直前にあっても、そのまま残る。対が 2 つあれば 2 つ目は消える
for mode in upgrade rerun force; do
  o="$(new_workdir)/blank-$mode"
  mkdir -p "$o"
  printf 'before-1\n\n  \n\n%s\nold-1\n%s\nmid\n\n%s\nold-2\n%s\nafter-1\n' "$BEGIN_MARK" "$END_MARK" "$BEGIN_MARK" "$END_MARK" > "$o/.gitignore"
  if [[ "$mode" == "upgrade" ]]; then
    # --upgrade は由来の記録を要るので、先に別の出力先で作った記録を使わず、区画なしで生成してから戻す
    o2="$(new_workdir)/blank-gen"
    mkdir -p "$o2"; gen "$o2"
    cp "$o/.gitignore" "$o2/.gitignore"
    o="$o2"
  fi
  run_mode "$mode" "$o"; rc=$?
  it "$mode: 対が 2 つ・直前に空行 2 行と空白だけの行があっても成功する"
  assert_eq "$rc" "0"
  it "$mode: 2 つ目の対が消え、外の行は空行・空白だけの行も含めて残る"
  assert_eq "$(outside_lines "$o/.gitignore")" "$(printf 'before-1\n\n  \n\n<SEC>\nmid\n\nafter-1')"
  it "$mode: 区画は 1 つだけで、1 つ目が新しい中身になる"
  if [[ "$(grep -cxF "$BEGIN_MARK" "$o/.gitignore")" == "1" ]] && ! grep -qx 'old-1' "$o/.gitignore" && ! grep -qx 'old-2' "$o/.gitignore" && grep -qx 'stub-template-entry' "$o/.gitignore"; then pass; else fail "区画の数か中身が違う"; fi
  h1="$(cksum < "$o/.gitignore")"
  run_mode "$mode" "$o"
  it "$mode: 2 回続けても内容が変わらない"
  assert_eq "$(cksum < "$o/.gitignore")" "$h1"
done

it "区画が無い .gitignore では、空行 1 行を挟んで末尾へ足される"
o="$(new_workdir)/nosec"
mkdir -p "$o"
printf 'a\n!b\n\n\n' > "$o/.gitignore"
gen "$o"
assert_eq "$(sed -n '1,4p' "$o/.gitignore")" "$(printf 'a\n!b\n\n%s' "$BEGIN_MARK")"

# ── 壊れた区画は書き込む前に止まる（#538。#507 と同じ形にしない） ───────────

broken_case() { # label content extra_args...
  local label="$1" content="$2"; shift 2
  local d; d="$(new_workdir)/broken"
  mkdir -p "$d"
  printf '%s\n' "$content" > "$d/.gitignore"
  local before; before="$(cksum < "$d/.gitignore")"
  bash "$BOOTSTRAP" --project-name sep --languages node --base-image "$IMG" --output-dir "$d" "$@" >/dev/null 2>"$d.err"
  local rc=$?
  it "$label: 0 以外で止まる"
  if [[ "$rc" -ne 0 ]]; then pass; else fail "終了コード 0"; fi
  it "$label: .gitignore は変わらない"
  assert_eq "$(cksum < "$d/.gitignore")" "$before"
  it "$label: ほかの生成物も書かれない"
  assert_eq "$(find "$d" -mindepth 1 ! -name '.gitignore' | wc -l | tr -d ' ')" "0"
  it "$label: 直し方を案内する"
  if grep -q -- '--no-gitignore' "$d.err"; then pass; else fail "案内が無い"; fi
}
broken_case "開始行だけ" "$(printf 'mine\n%s\nx\nafter' "$BEGIN_MARK")"
broken_case "終了行だけ" "$(printf 'mine\n%s\nafter' "$END_MARK")"
broken_case "開始行だけ(--dry-run)" "$(printf 'mine\n%s\nx' "$BEGIN_MARK")" --dry-run
broken_case "終了行だけ(--force)" "$(printf '%s\nmine' "$END_MARK")" --force

it "壊れた .gitignore でも --no-gitignore なら生成できる"
d="$(new_workdir)/nogi"
mkdir -p "$d"
printf '%s\nmine\n' "$BEGIN_MARK" > "$d/.gitignore"
bash "$BOOTSTRAP" --project-name sep --languages node --base-image "$IMG" --output-dir "$d" --no-gitignore >/dev/null 2>&1
assert_eq "$?" "0"

exit_with_result
