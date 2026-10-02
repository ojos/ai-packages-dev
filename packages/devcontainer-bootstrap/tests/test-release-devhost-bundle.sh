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
