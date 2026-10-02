#!/usr/bin/env bash
# devhost（packages/devhost/.）が DCB の配布ツリーと PACKAGE_ARCHIVE.tar.gz に
# サブディレクトリ構造（devhost/termux/）を保ったまま含まれることを検証する（#376）。
#
# devhost は複数ファイル・階層を持つため、既存の SHA256SUMS の対象
# （SUMS_TARGETS = bootstrap.sh / doctor.sh）には加えない（is_plain_asset_name が
# 単一ファイル名以外を拒む設計のため）。完全性は PACKAGE_ARCHIVE.tar.gz のハッシュ
# （RELEASE-MANIFEST.json の checksums）で守る。ここではその前提——配布ツリーに
# devhost 一式が実在し、PACKAGE_ARCHIVE.tar.gz にも同じものが入っている——を検査する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-release-devhost-bundle"

RELEASE_SH="$REPO_ROOT/scripts/release-packages.sh"

it "リリーススクリプトが存在する"
assert_file_exists "$RELEASE_SH"

# 実物のスクリプトから関数定義部分だけを取り込む（実行部の手前まで）。
# test-release-contract.sh と同じ抽出方法。
end="$(grep -n '^EXECUTE="false"' "$RELEASE_SH" | head -1 | cut -d: -f1)"
fns="$(new_workdir)/fns.sh"
head -n $((end - 1)) "$RELEASE_SH" > "$fns"

rel="$(new_workdir)/rel"
(
  set -euo pipefail
  # shellcheck disable=SC1090
  . "$fns"
  cd "$REPO_ROOT"
  SUMS_TARGETS=(bootstrap.sh doctor.sh)
  prepare_dcb_release_repo "$rel"
  generate_standard_assets "$rel" "devcontainer-bootstrap" "0.0.0"
) >/dev/null 2>&1

it "配布ツリーに devhost/dev.sh が含まれる"
assert_file_exists "$rel/devhost/dev.sh"

it "配布ツリーに devhost のサブディレクトリ（termux/）が保たれる"
assert_file_exists "$rel/devhost/termux/shortcut.example"

it "packages/devhost/ で追跡しているファイルがすべて配布ツリーに入る"
# DCB_DISTRIBUTED_FILES はファイルを 1 つずつ列挙するので、packages/devhost/ に
# ファイルを足して一覧への追加を忘れると、黙って配布から漏れる。ここで捕まえる。
missing=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  [[ -f "$rel/devhost/${f#packages/devhost/}" ]] || missing="${missing} ${f}"
done < <(git -C "$REPO_ROOT" ls-files packages/devhost)
if [[ -z "$missing" ]]; then
  pass
else
  fail "配布ツリーに無い（scripts/release-packages.sh の DCB_DISTRIBUTED_FILES へ足す）:${missing}"
fi

it "配布ツリーの devhost/README.md が DCB の README.md と衝突しない"
# devhost/README.md と DCB 自身の README.md はどちらも配布ツリーに存在し、
# 別パスとして共存すること（フラットな Release 資産と違い、配布ツリーは
# ディレクトリを持つため衝突しない）。
if [[ -f "$rel/README.md" && -f "$rel/devhost/README.md" ]]; then
  pass
else
  fail "README.md（DCB）と devhost/README.md のどちらかが無い"
fi

it "PACKAGE_ARCHIVE.tar.gz に devhost 一式が含まれる（サブディレクトリを含む）"
if [[ -f "$rel/PACKAGE_ARCHIVE.tar.gz" ]]; then
  listing="$(tar -tzf "$rel/PACKAGE_ARCHIVE.tar.gz")"
  if printf '%s\n' "$listing" | grep -qE '^\./devhost/dev\.sh$' \
     && printf '%s\n' "$listing" | grep -qE '^\./devhost/termux/shortcut\.example$'; then
    pass
  else
    fail "PACKAGE_ARCHIVE.tar.gz が devhost 一式を含まない。中身:
$(printf '%s\n' "$listing" | grep devhost || echo '(devhost を含む行が無い)')"
  fi
else
  fail "PACKAGE_ARCHIVE.tar.gz が生成されていない"
fi

it "README に書いた取り出しのコマンド（tar -xzf ... ./devhost）で devhost を取り出せる"
# 中の名前は ./devhost/... なので、GNU tar では devhost/ を指定すると一致しない。
# README の手順がそのまま通ることを、生成した archive で確かめる。
xdir="$(new_workdir)"
if [[ -f "$rel/PACKAGE_ARCHIVE.tar.gz" ]] \
   && (cd "$xdir" && tar -xzf "$rel/PACKAGE_ARCHIVE.tar.gz" ./devhost) >/dev/null 2>&1 \
   && [[ -f "$xdir/devhost/dev.sh" && -f "$xdir/devhost/termux/shortcut.example" ]]; then
  pass
else
  fail "tar -xzf PACKAGE_ARCHIVE.tar.gz ./devhost で devhost を取り出せない"
fi
for readme in "$PKG_DIR/README.md" "$REPO_ROOT/packages/devhost/README.md"; do
  if grep -qE 'tar -xzf PACKAGE_ARCHIVE\.tar\.gz devhost/?$' "$readme"; then
    fail "$readme が ./ の無い指定（devhost/）で取り出している"
  fi
done

it "SHA256SUMS の対象は変えない（bootstrap.sh / doctor.sh のみ）"
# devhost は個別の Release 資産として添付しないため、SHA256SUMS の対象に devhost を
# 加えない設計を固定する。加えると is_plain_asset_name（監査側）が単一ファイル名
# 以外を拒むため、SHA256SUMS に階層を持つ名前が入った時点で監査が壊れる。
if [[ -f "$rel/SHA256SUMS" ]]; then
  if grep -q 'devhost' "$rel/SHA256SUMS"; then
    fail "SHA256SUMS が devhost を列挙している: $(cat "$rel/SHA256SUMS")"
  else
    pass
  fi
else
  fail "SHA256SUMS が生成されていない"
fi

it "DCB の README が devhost への導線を持つ"
if grep -q 'devhost' "$PKG_DIR/README.md"; then
  pass
else
  fail "DCB の README.md に devhost への言及が無い"
fi

exit_with_result
