#!/usr/bin/env bash
# DCB の配布ツリーと PACKAGE_ARCHIVE.tar.gz に devhost が含まれないことを検証する（#486）。
#
# devhost（packages/devcontainer-host/.）は、以前（#376）は DCB のリリースへ devhost/ として
# 同梱していた。独自の版を持つ公開リポジトリ（devcontainer-host）から配る形へ移したので、
# DCB の配布物へ戻らないことをここで固定する。同梱を戻す変更（DCB_DISTRIBUTED_FILES への
# 追加、配布ツリーへの devhost/ の展開）はここで赤になる。
#
# devcontainer-host 側の配布物（dev.sh・dev-up@.service の個別の資産、マニフェストの
# checksums など）の検査は tests/test-release-devcontainer-host.sh（プロジェクト層）が持つ。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-release-no-devhost-bundle"

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
  SUMS_TARGETS=(bootstrap.sh doctor.sh PACKAGE_ARCHIVE.tar.gz)
  prepare_dcb_release_repo "$rel"
  generate_standard_assets "$rel" "devcontainer-bootstrap" "0.0.0"
) >/dev/null 2>&1

it "配布ツリーが生成されている（以降の検査が空振りしない）"
if [[ -f "$rel/bootstrap.sh" && -f "$rel/doctor.sh" && -f "$rel/README.md" ]]; then
  pass
else
  fail "配布ツリーに bootstrap.sh / doctor.sh / README.md が無い: $(ls "$rel" 2>&1 | tr '\n' ' ')"
fi

it "配布ツリーに devhost/ が含まれない"
if [[ ! -e "$rel/devhost" ]]; then
  pass
else
  fail "配布ツリーに devhost/ がある: $(find "$rel/devhost" -type f 2>/dev/null | tr '\n' ' ')"
fi

it "配布ツリーのルート直下に devhost のファイルが無い"
leaked=""
for f in dev.sh "dev-up@.service" selftest.sh projects.example; do
  [[ -e "$rel/$f" ]] && leaked="$leaked $f"
done
if [[ -z "$leaked" ]]; then
  pass
else
  fail "devhost のファイルがルート直下に入っている:$leaked"
fi

it "PACKAGE_ARCHIVE.tar.gz に devhost のファイルが含まれない"
if [[ -f "$rel/PACKAGE_ARCHIVE.tar.gz" ]]; then
  listing="$(tar -tzf "$rel/PACKAGE_ARCHIVE.tar.gz")"
  leaked="$(printf '%s\n' "$listing" | grep -E 'devhost|/dev\.sh$|dev-up@' || true)"
  if [[ -n "$leaked" ]]; then
    fail "PACKAGE_ARCHIVE.tar.gz が devhost のファイルを含む: $(printf '%s' "$leaked" | tr '\n' ' ')"
  else
    pass
  fi
else
  fail "PACKAGE_ARCHIVE.tar.gz が生成されていない"
fi

it "DCB_DISTRIBUTED_FILES が packages/devcontainer-host/ を参照しない"
# 一覧は配布元のパスと配布先の名前の対。配布元に devcontainer-host が現れたら、同梱が戻っている。
if grep -E '^[[:space:]]*"packages/devcontainer-host/' "$RELEASE_SH" >/dev/null; then
  fail "release-packages.sh の配布一覧が packages/devcontainer-host/ を含む"
else
  pass
fi

it "SHA256SUMS の対象は bootstrap.sh / doctor.sh / PACKAGE_ARCHIVE.tar.gz（devhost のファイルは足さない）"
if [[ -f "$rel/SHA256SUMS" ]]; then
  names="$(awk '{print $2}' "$rel/SHA256SUMS" | tr '\n' ' ')"
  assert_eq "$names" "bootstrap.sh doctor.sh PACKAGE_ARCHIVE.tar.gz " "SHA256SUMS の対象"
else
  fail "SHA256SUMS が生成されていない"
fi

it "RELEASE-MANIFEST.json の checksums は標準の 2 つのまま（dev.sh などを足さない）"
if [[ -f "$rel/RELEASE-MANIFEST.json" ]] && command -v jq >/dev/null 2>&1; then
  keys="$(jq -r '.checksums | keys | join(" ")' "$rel/RELEASE-MANIFEST.json")"
  assert_eq "$keys" "PACKAGE_ARCHIVE.tar.gz SHA256SUMS" "checksums のキー"
else
  fail "RELEASE-MANIFEST.json が無い、または jq が無い"
fi

it "DCB の README が devhost の入手先を案内し、同梱を前提にした取り出し手順を持たない"
if grep -q 'devcontainer-host' "$PKG_DIR/README.md" \
   && ! grep -qE 'tar -xzf PACKAGE_ARCHIVE\.tar\.gz.*devhost' "$PKG_DIR/README.md"; then
  pass
else
  fail "DCB の README.md が移り先を案内していない、または同梱を前提にした取り出し手順が残っている"
fi

exit_with_result
