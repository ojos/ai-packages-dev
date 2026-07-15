#!/usr/bin/env bash
# リリース資産の契約を検証する。
#
# SHA256SUMS が列挙するファイルと、README がユーザーに取得させるファイルが一致
# しないと、documented な検証手順が非ゼロ終了する。公開中の v0.2.1 は実際に
# この状態だった（SHA256SUMS が doctor.sh を含むのに README は取得させない）。
#
# 検証ファイルは「検証する人が手元に持っているもの」を列挙しなければ意味がない。
# ここではその一致を、実際に sha256sum -c を走らせて確認する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-release-contract"

RELEASE_SH="$REPO_ROOT/scripts/release-packages.sh"
DCB_README="$PKG_DIR/README.md"

it "リリーススクリプトが存在する"
assert_file_exists "$RELEASE_SH"

# ── SHA256SUMS の対象と README の取得対象が一致するか ────────────────────────

# スクリプトが実際に宣言している checksum 対象を読み取る。テスト側で決め打ちすると
# スクリプトを変えても検出できない。
# DCB のリリース直前に宣言されているものを取る。冒頭の空初期化や dotfiles 用の
# 宣言と取り違えないよう、DCB の資産生成呼び出しの直前にある宣言を対象にする。
export DCB_SUMS_TARGETS
DCB_SUMS_TARGETS="$(grep -B2 'generate_standard_assets "\$DCB_DIR"' "$RELEASE_SH" \
  | grep -oE '^SUMS_TARGETS=\([^)]*\)' | head -1 | sed 's/^SUMS_TARGETS=(//; s/)$//')"

it "SHA256SUMS の対象がスクリプトで明示されている"
if [[ -n "$DCB_SUMS_TARGETS" ]]; then
  pass
else
  fail "SUMS_TARGETS の宣言が見つからない"
fi

it "README が SHA256SUMS の対象をすべて取得させる"
# README のコードブロックから curl 対象のファイル名を抽出する
fetched="$(grep -oE 'curl [^|]*/[A-Za-z0-9._-]+" -o [A-Za-z0-9._-]+' "$DCB_README" \
  | sed 's/.* -o //' | sort -u | tr '\n' ' ')"
missing=""
for f in $DCB_SUMS_TARGETS; do
  case " $fetched " in *" $f "*) ;; *) missing="$missing $f" ;; esac
done
if [[ -z "$missing" ]]; then
  pass
else
  fail "SHA256SUMS が列挙するが README が取得させないファイル:$missing (README の curl 対象: $fetched)"
fi

# ── 実際に資産を生成して documented な手順を通す ──────────────────────────────

it "生成した資産で README の検証手順が通る"
# 実物のスクリプトから関数定義部分だけを取り込む（実行部の手前まで）
end="$(grep -n '^EXECUTE="false"' "$RELEASE_SH" | head -1 | cut -d: -f1)"
fns="$(new_workdir)/fns.sh"
head -n $((end - 1)) "$RELEASE_SH" > "$fns"

rel="$(new_workdir)/rel"
(
  set -euo pipefail
  # shellcheck disable=SC1090
  . "$fns"
  cd "$REPO_ROOT"
  # shellcheck disable=SC2206
  SUMS_TARGETS=($DCB_SUMS_TARGETS)
  prepare_dcb_release_repo "$rel"
  generate_standard_assets "$rel" "devcontainer-bootstrap" "0.0.0"
) >/dev/null 2>&1

if [[ ! -f "$rel/SHA256SUMS" ]]; then
  fail "資産を生成できなかった"
else
  # README の手順を忠実に再現する。テスト側で対象を決め打ちにすると、SHA256SUMS が
  # 余計なファイルを列挙するようになっても気づけない。README が curl する
  # ファイルだけを手元に置くこと。
  user="$(new_workdir)/user"
  mkdir -p "$user"
  copied=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ -f "$rel/$f" ]]; then cp "$rel/$f" "$user/"; copied=$((copied + 1)); fi
  done < <(grep -oE 'curl [^|]*/[A-Za-z0-9._-]+" -o [A-Za-z0-9._-]+' "$DCB_README" \
             | sed 's/.* -o //' | sort -u)

  if [[ "$copied" -eq 0 ]]; then
    fail "README から curl 対象を抽出できなかった"
  elif ( cd "$user" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
    pass
  else
    fail "README が取得させるファイルだけでは検証が失敗する（手元: $(cd "$user" && ls | tr '\n' ' ')）:
$( cd "$user" && sha256sum -c SHA256SUMS 2>&1 | head -5 )"
  fi
fi

it "マニフェストの検証チェーンが繋がっている"
if [[ -f "$rel/RELEASE-MANIFEST.json" ]]; then
  claimed="$(jq -r '.checksums.SHA256SUMS' "$rel/RELEASE-MANIFEST.json" 2>/dev/null)"
  actual="$(sha256sum "$rel/SHA256SUMS" | awk '{print $1}')"
  if [[ -n "$claimed" && "$claimed" == "$actual" ]]; then
    pass
  else
    fail "マニフェストが記録した SHA256SUMS のハッシュが実際と一致しない ($claimed vs $actual)"
  fi
else
  fail "RELEASE-MANIFEST.json が生成されていない"
fi

# ── 二重所有の再発防止 ────────────────────────────────────────────────────────

it "公開リポジトリへ release workflow を配布しない"
# 公開側に CI を置くと、タグ push で発火してこのスクリプトと同じリリースを作り、
# 資産を上書きしてマニフェストの検証チェーンを壊す（v0.2.1 で実際に発生）。
if grep -q 'release\.yml' "$RELEASE_SH"; then
  fail "release-packages.sh が release.yml を公開側へ配布している"
else
  pass
fi

it "パッケージが release workflow を持たない"
if [[ -f "$PKG_DIR/.github/workflows/release.yml" ]]; then
  fail "パッケージに release.yml が残っている（公開側へ渡ると二重所有になる）"
else
  pass
fi

exit_with_result
