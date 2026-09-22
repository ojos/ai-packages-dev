#!/usr/bin/env bash
# README の導入手順が「一時ディレクトリで取得・検証・実行し、後片付けを残さない」形を
# 保っていることを検査する。
#
# 旧手順は bootstrap.sh / doctor.sh / SHA256SUMS の 3 つをカレントディレクトリへ落として
# 実行し、後片付けを利用者の手作業に委ねていた。導入のたびに削除漏れが残り、診断にしか
# 使わない doctor.sh を検証のためだけに取得する必要もあった。
#
# 新手順は次の 3 つが揃って初めて成立する。1 つでも欠けると、生成物が trap で消える
# （--output-dir 省略）、検証が落ちる（検証の欠落）、後片付けが残る（trap 欠落）
# のいずれかになり、手順として機能しない。文面の書き戻しを検出できるようにここで固定する。
#
#   1. mktemp -d による作業ディレクトリと trap による破棄
#   2. 取得した行だけを抜き出した検証（bootstrap.sh だけを取得するため）
#   3. --output-dir の明示（既定は $PWD/<project-name> = 一時ディレクトリの中）
#
# 検査は README の記述だけでなく、その前提が実装側で成立していることまで見る。README に
# 手順を書いても、bootstrap.sh の既定出力先や doctor.sh のオプションが変われば手順は壊れる。
# 最後に、手順どおりの実行（スクリプトの置き場所とカレントディレクトリの双方が生成先と
# 異なる状態）で生成先が守られることを実際に確かめる。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-readme-install"

README="$PKG_DIR/README.md"
DOCTOR="$PKG_DIR/doctor.sh"

# 導入手順の範囲は「## 公開リリースからの利用」から「### doctor.sh を後から取得する」の
# 直前まで。後続の「### リリース資産」には配布物そのものを検証する別手順があり、そちらは
# カレントディレクトリへ資産を並べる前提なので、同じ規則で見ると誤検出になる。
install_section() {
  awk '
    /^## 公開リリースからの利用/ { inside = 1; next }
    inside && /^### doctor\.sh を後から取得する/ { exit }
    inside && /^## / { exit }
    inside { print }
  ' "$README"
}

# doctor.sh の入手手順（次の見出しまで）。
doctor_fetch_section() {
  awk '
    /^### doctor\.sh を後から取得する/ { inside = 1; next }
    inside && /^#/ { exit }
    inside { print }
  ' "$README"
}

# コマンド形の検査は本文ではなくコードブロックだけを見る。本文には「curl | bash 形式は
# 採らない」のように、採らない形をあえて名指しする説明があり、本文ごと見ると説明文自体を
# 違反として拾ってしまう。
code_blocks() {
  awk '
    /^```/ { inside = !inside; next }
    inside { print }
  '
}

INSTALL="$(install_section)"
INSTALL_CODE="$(install_section | code_blocks)"
FETCH_DOCTOR="$(doctor_fetch_section)"
FETCH_DOCTOR_CODE="$(doctor_fetch_section | code_blocks)"

it "README に導入手順の節がある"
if [[ -n "$INSTALL" ]]; then pass; else fail "「公開リリースからの利用」節を抽出できなかった"; fi

# ── 一時ディレクトリと後片付け ────────────────────────────────────────────────

it "導入手順が mktemp で作業ディレクトリを確保している"
assert_contains "$INSTALL" 'mktemp -d' "導入手順"

it "導入手順が trap で作業ディレクトリを破棄している"
# 手作業の削除に戻っていないこと。trap を外すと利用者の後片付けが復活する。
assert_contains "$INSTALL" "trap 'rm -rf" "導入手順"

it "導入手順がカレントディレクトリへ資産を落としていない"
# 旧形式（-o bootstrap.sh）の書き戻しを検出する。取得先は必ず作業ディレクトリ配下。
if printf '%s\n' "$INSTALL_CODE" | grep -qE '^[^#]*curl[^#]*-o +[^"$]'; then
  fail "導入手順にカレントディレクトリへ取得する curl が残っている"
else
  pass
fi

# ── 検証 ──────────────────────────────────────────────────────────────────────

it "導入手順が、取得した行だけを抜き出して検証している"
# SHA256SUMS は doctor.sh も対象にするため、bootstrap.sh だけを取得する手順では
# 取得した行を選ぶ必要がある。--ignore-missing は実装と版によって有無が違うので
# 使わない（sha256sum は GNU coreutils のコマンドで、macOS には無い）。
assert_contains "$INSTALL" "grep ' bootstrap.sh\$' SHA256SUMS" "導入手順"

it "導入手順が sha256sum の不在へ分岐している"  # bsd-ok: CI（Linux）でしか実行しないテスト
# **macOS には sha256sum が無い。** 分岐が無いと、利用者は取得の 1 行目で落ちる。
assert_contains "$INSTALL" 'command -v sha256sum' "導入手順"
assert_contains "$INSTALL" 'shasum -a 256' "導入手順"

# ── 手順を実際に走らせる ────────────────────────────────────────────────────
#
# **綴りの照合だけでは「手順が通ること」を保証しない。** 旧手順は sha256sum を直に
# 呼んでおり、綴りとしては正しく書かれていたが、macOS には sha256sum が無いため
# 利用者は取得の 1 行目で落ちた。README から検証部分を取り出し、実際に実行する。

# README の導入手順から、分岐の定義行と検証行を取り出す。
#
# 導入手順のブロックは 2 つある（基本形と、規範の取得元を足した形）。どちらも同じ
# 検証を持つので、**最初の 1 組だけ**を取る。全部を連ねても動くが、何を実行して
# いるのかが読めなくなる。
verify_lines() {
  printf '%s\n' "$INSTALL_CODE" | awk '
    !seen_branch && /command -v sha256sum/ { seen_branch = 1; print; next }
    !seen_verify && /SHA256SUMS \| \$sha256c -c -/ {
      seen_verify = 1
      sub(/[[:space:]]*&&[[:space:]]*$/, "")
      print
    }
  '
}

# 検証を 1 回走らせる。$1 = PATH、$2 = 作業ディレクトリ。終了コードを返す。
run_readme_verify() {
  local path="$1" dir="$2" code
  code="$(verify_lines)"
  ( cd "$dir" && PATH="$path" d="$dir" bash -c "$code" ) >/dev/null 2>&1
}

# sha256sum を隠した PATH を作る（macOS を模す）。
NOSUM_BIN="$(new_workdir)/nosum"
mkdir -p "$NOSUM_BIN"
for c in shasum grep awk sed cat ls env bash sh coreutils; do
  src="$(command -v "$c" 2>/dev/null || true)"
  [[ -n "$src" ]] && ln -sf "$src" "$NOSUM_BIN/$c"
done
NOSUM_PATH="$NOSUM_BIN"

# 検証対象を用意する。SHA256SUMS は doctor.sh も対象にするが、doctor.sh は取得しない
# （README が想定する状況そのもの）。
make_verify_dir() {
  local dir
  dir="$(new_workdir)/rel"
  mkdir -p "$dir"
  printf 'bootstrap\n' > "$dir/bootstrap.sh"
  printf 'doctor\n' > "$dir/doctor.sh"
  # 印で黙らせず、README へ書いたのと同じ分岐で作る。移植性の手順を検査する側が
  # 移植性を欠いていると、macOS の手元でこのテストだけが落ちる。
  ( cd "$dir" && if command -v sha256sum >/dev/null 2>&1; then
      sha256sum bootstrap.sh doctor.sh > SHA256SUMS  # bsd-ok: 分岐の中（else 側に shasum の枝がある）
    else
      shasum -a 256 bootstrap.sh doctor.sh > SHA256SUMS
    fi )
  rm -f "$dir/doctor.sh"
  printf '%s' "$dir"
}

it "README から検証部分を取り出せる（0 行なら以降が無条件に通る）"
# 取り出せないまま以降を走らせると、空のコードが「通った」ことになり、全部が緑になる。
extracted="$(verify_lines)"
if [[ "$(printf '%s\n' "$extracted" | grep -c .)" -eq 2 ]] \
  && printf '%s' "$extracted" | grep -F 'command -v sha256sum' >/dev/null \
  && printf '%s' "$extracted" | grep -F '$sha256c -c -' >/dev/null; then
  pass
else
  fail "分岐の定義行と検証行を 1 組だけ取り出せない: $(printf '%s' "$extracted" | tr '\n' '/')"
fi

it "手順どおりの検証が通る（sha256sum がある環境）"                    # bsd-ok: 検査名に綴りが入るだけ
vdir="$(make_verify_dir)"
if run_readme_verify "$PATH" "$vdir"; then pass; else fail "正しい入力で検証が落ちた"; fi

it "手順どおりの検証が通る（sha256sum が無い環境。macOS を模す）"      # bsd-ok: 検査名に綴りが入るだけ
# **これが本題である。** sha256sum が無いだけで落ちるなら、README は macOS 利用者を
# 取得の 1 行目で止める。
vdir="$(make_verify_dir)"
if [[ -z "$(command -v shasum 2>/dev/null)" ]]; then
  fail "shasum がこの環境に無く、分岐の片側を検査できない（検査が成立しないため失敗させる）"
elif run_readme_verify "$NOSUM_PATH" "$vdir"; then
  pass
else
  fail "sha256sum が無い環境で検証が落ちた（macOS 利用者が取得の 1 行目で止まる）"  # bsd-ok: 検査名に綴りが入るだけ
fi

it "改竄した SHA256SUMS では非 0 で止まる（対照群。両方の分岐で）"
# 対照が無いと、「常に通る手順」へ退化させても気づけない。
bad_ok=1
for p in "$PATH" "$NOSUM_PATH"; do
  vdir="$(make_verify_dir)"
  awk '{ sub(/^./, "0"); print }' "$vdir/SHA256SUMS" > "$vdir/SHA256SUMS.new"
  mv "$vdir/SHA256SUMS.new" "$vdir/SHA256SUMS"
  run_readme_verify "$p" "$vdir" && bad_ok=0
done
if [[ "$bad_ok" -eq 1 ]]; then pass; else fail "改竄した入力で検証が通ってしまう"; fi

it "SHA256SUMS に載っていても取得していないファイルは検証を妨げない（両方の分岐で）"
# --ignore-missing に相当する挙動。上の make_verify_dir は doctor.sh を消してあるので、
# 「通る」検査が同時にこれを見ている。ここでは行が抜き出せなかった場合に**素通り
# しない**ことを固定する（検証が成立しないまま緑になる経路を塞ぐ）。
miss_ok=1
for p in "$PATH" "$NOSUM_PATH"; do
  vdir="$(make_verify_dir)"
  awk '{ sub(/ bootstrap\.sh$/, " renamed.sh"); print }' "$vdir/SHA256SUMS" > "$vdir/SHA256SUMS.new"
  mv "$vdir/SHA256SUMS.new" "$vdir/SHA256SUMS"
  run_readme_verify "$p" "$vdir" && miss_ok=0
done
if [[ "$miss_ok" -eq 1 ]]; then pass; else fail "一致する行が無いのに検証が通ってしまう"; fi

it "検証とスクリプト実行が && で連結されている"
# この手順は対話シェルへ貼って使う。set -e が効かないため、検証と実行を別の行に
# 置くとチェックサムが失敗しても次の bash が走り、「実行前に必ず検証する」という
# 手順の目的が文面だけのものになる。導入手順と doctor.sh 入手手順の両方を見る。
unchained="$(printf '%s\n' "$INSTALL_CODE" "$FETCH_DOCTOR_CODE" | awk '
  # $d 配下のスクリプトを起動する行は、直前の行が && で終わっていなければならない。
  /^bash "\$d\// { if (prev !~ /&&[[:space:]]*$/) print "  " $0 }
  { prev = $0 }
')"
if [[ -z "$unchained" ]]; then
  pass
else
  fail "検証と連結されていない実行行:
$unchained"
fi

it "導入手順が検証を省く curl | bash 形式を含まない"
if printf '%s\n' "$INSTALL_CODE" | grep -qE 'curl[^|]*\| *(bash|sh)\b'; then
  fail "検証を挟まない curl | bash 形式が導入手順にある"
else
  pass
fi

# ── 生成先の指定 ──────────────────────────────────────────────────────────────

it "導入手順が --output-dir を明示している"
# 省略すると出力先が一時ディレクトリの中になり、trap で消える。
assert_contains "$INSTALL" '--output-dir' "導入手順"

it "導入手順が規範の取得元指定に触れている"
# 一時ディレクトリからの実行では隣接チェックアウトが無く、指定しないと規範が配置されない。
case "$INSTALL" in
  *--playbook-version*|*--playbook-from*) pass ;;
  *) fail "--playbook-version / --playbook-from のどちらにも触れていない" ;;
esac

# ── doctor.sh の入手 ──────────────────────────────────────────────────────────

it "README に doctor.sh の入手手順がある"
if [[ -n "$FETCH_DOCTOR" ]]; then
  pass
else
  fail "「doctor.sh を後から取得する」節を抽出できなかった"
fi

it "doctor.sh の入手手順が取得・検証・実行を揃えている"
missing=""
for needle in '/doctor.sh' 'SHA256SUMS' 'command -v sha256sum' 'shasum -a 256' '--target-dir'; do
  case "$FETCH_DOCTOR" in
    *"$needle"*) ;;
    *) missing="$missing $needle" ;;
  esac
done
if [[ -z "$missing" ]]; then
  pass
else
  fail "doctor.sh の入手手順に無い要素:$missing"
fi

it "Doctor 自己診断の節から入手手順へ辿れる"
# 導入手順が doctor.sh を取得しなくなったため、診断側に入手経路が無いと行き止まりになる。
if awk '
     /^## Doctor 自己診断/ { inside = 1; next }
     inside && /^## / { exit }
     inside { print }
   ' "$README" | grep -q '#doctorsh-を後から取得する'; then
  pass
else
  fail "Doctor 自己診断の節に doctor.sh 入手手順へのリンクが無い"
fi

# ── 手順が前提にしている実装 ──────────────────────────────────────────────────

it "bootstrap.sh の既定出力先が \$PWD/<project-name> のままである"
# README が --output-dir の明示を必須と説明する根拠。既定が変わったら説明を見直す。
if grep -q 'OUTPUT_DIR="\$PWD/\$PROJECT_NAME"' "$BOOTSTRAP"; then
  pass
else
  fail "bootstrap.sh の既定出力先が \$PWD/\$PROJECT_NAME ではない"
fi

it "doctor.sh が --target-dir で診断対象を受け取る"
# 一時ディレクトリから doctor.sh を実行できる根拠。
if grep -q -- '--target-dir' "$DOCTOR"; then
  pass
else
  fail "doctor.sh に --target-dir が無い"
fi

# ── 手順どおりの実行 ──────────────────────────────────────────────────────────

it "スクリプトの置き場所と無関係に --output-dir の生成先へ出力される"
# 手順の核心（作業ディレクトリを捨てても生成物が残る）を実際に確かめる。
# スクリプトの置き場所・カレントディレクトリ・生成先の 3 つをすべて別にして実行する。
script_dir="$(mktemp -d "$TEST_TMP_ROOT/scripts.XXXXXX")"
cp "$BOOTSTRAP" "$script_dir/bootstrap.sh"
work="$(new_workdir)"
cwd="$work/cwd"
out="$work/myapp"
mkdir -p "$cwd"
( cd "$cwd" && bash "$script_dir/bootstrap.sh" \
    --project-name myapp --languages node --output-dir "$out" ) >/dev/null 2>&1
rc=$?
if [[ "$rc" -ne 0 ]]; then
  fail "bootstrap.sh が終了コード $rc で失敗した"
elif [[ ! -f "$out/.devcontainer/devcontainer.json" ]]; then
  fail "生成先 $out に devcontainer.json が無い"
else
  pass
fi

it "スクリプトの置き場所とカレントディレクトリに生成物が残らない"
# ここへ書き出されていると、作業ディレクトリを捨てる手順で生成物ごと失われる。
stray=""
[[ -e "$script_dir/.devcontainer" ]] && stray="$stray $script_dir/.devcontainer"
[[ -e "$script_dir/myapp" ]] && stray="$stray $script_dir/myapp"
[[ -e "$cwd/.devcontainer" ]] && stray="$stray $cwd/.devcontainer"
[[ -e "$cwd/myapp" ]] && stray="$stray $cwd/myapp"
if [[ -z "$stray" ]]; then
  pass
else
  fail "生成先の外へ書き出されたもの:$stray"
fi

exit_with_result
