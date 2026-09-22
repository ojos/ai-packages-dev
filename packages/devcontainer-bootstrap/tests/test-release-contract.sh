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
# DCB のリリース直前に宣言されているものを取る。冒頭の空初期化や ai-playbook 用の
# 宣言と取り違えないよう、DCB の資産生成呼び出しの直前にある宣言を対象にする。
export DCB_SUMS_TARGETS
DCB_SUMS_TARGETS="$(grep -B3 'generate_standard_assets "\$DCB_DIR"' "$RELEASE_SH" \
  | grep -oE 'SUMS_TARGETS=\([^)]*\)' | head -1 | sed 's/^SUMS_TARGETS=(//; s/)$//')"

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
  elif ( cd "$user" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then  # bsd-ok: CI（Linux）でしか実行しないテスト
    pass
  else
    # 報告の中身を先に変数へ取る。文字列の中へ埋めたままだと、その行へ逃げ道の印を
    # 書けない（行コメントが報告文の一部になってしまう）。
    here="$(cd "$user" && ls | tr '\n' ' ')"
    detail="$(cd "$user" && sha256sum -c SHA256SUMS 2>&1 | head -5)"  # bsd-ok: CI（Linux）でしか実行しないテスト
    fail "README が取得させるファイルだけでは検証が失敗する（手元: $here）:
$detail"
  fi
fi

it "マニフェストの検証チェーンが繋がっている"
if [[ -f "$rel/RELEASE-MANIFEST.json" ]]; then
  claimed="$(jq -r '.checksums.SHA256SUMS' "$rel/RELEASE-MANIFEST.json" 2>/dev/null)"
  actual="$(sha256sum "$rel/SHA256SUMS" | awk '{print $1}')"  # bsd-ok: CI（Linux）でしか実行しないテスト
  if [[ -n "$claimed" && "$claimed" == "$actual" ]]; then
    pass
  else
    fail "マニフェストが記録した SHA256SUMS のハッシュが実際と一致しない ($claimed vs $actual)"
  fi
else
  fail "RELEASE-MANIFEST.json が生成されていない"
fi

it "マニフェストの assets が README の入手対象をすべて含む"
# assets はリリースに何が添付されているかの機械可読な正本。README が公式手順として
# curl させるファイルが載っていないと、マニフェストだけを見た利用者は何を取得すれば
# よいか分からない。公開 v0.7.2 は実際にこの状態だった（assets が標準 3 資産のみ）。
if [[ -f "$rel/RELEASE-MANIFEST.json" ]]; then
  assets="$(jq -r '.assets[]' "$rel/RELEASE-MANIFEST.json" 2>/dev/null | tr '\n' ' ')"
  missing_assets=""
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case " $assets " in *" $f "*) ;; *) missing_assets="$missing_assets $f" ;; esac
  done < <(grep -oE 'curl [^|]*/[A-Za-z0-9._-]+" -o [A-Za-z0-9._-]+' "$DCB_README" \
             | sed 's/.* -o //' | sort -u)
  if [[ -z "$missing_assets" ]]; then
    pass
  else
    fail "README が取得させるのに assets に無い資産:$missing_assets (assets: $assets)"
  fi
else
  fail "RELEASE-MANIFEST.json が生成されていない"
fi

it "マニフェストの assets が実際に添付する資産と一致する"
# tag_and_release へ渡すファイル一覧と assets がずれると、「載っているのに無い」
# 資産が生まれる。両者を同じ集合に保つ。
if [[ -f "$rel/RELEASE-MANIFEST.json" ]]; then
  uploaded="$(sed -n '/tag_and_release "\$DCB_DIR"/,/^fi$/p' "$RELEASE_SH" \
    | grep -oE '\$DCB_DIR/[A-Za-z0-9._-]+' | sed 's|^\$DCB_DIR/||' | sort -u | tr '\n' ' ')"
  assets_sorted="$(jq -r '.assets[]' "$rel/RELEASE-MANIFEST.json" | sort -u | tr '\n' ' ')"
  if [[ "$uploaded" == "$assets_sorted" ]]; then
    pass
  else
    fail "添付一覧と assets が不一致。添付: $uploaded / assets: $assets_sorted"
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


# ── パッケージ単位のリリース ──────────────────────────────────────────────────
# 片方のパッケージを直すたびに他方の公開物が巻き込まれると、タグを固定しても
# 内容の同一性が保証されない。実際に dotfiles v0.3.0 の資産が DCB のリリースに
# 巻き込まれて上書きされた。

it "パッケージ単位のリリースが可能（両方必須ではない）"
if grep -q 'specify at least one of --dcb-version or --playbook-version' "$RELEASE_SH"; then
  pass
else
  fail "両方のバージョン指定が必須のままになっている"
fi

it "どちらも指定しないと失敗する"
out="$(bash "$RELEASE_SH" --owner test 2>&1)"
if [[ $? -ne 0 ]]; then
  assert_contains "$out" "at least one" "エラー出力"
else
  fail "指定なしでも通ってしまった"
fi

it "--owner なしは失敗する"
out="$(bash "$RELEASE_SH" --dcb-version v9.9.9 2>&1)"
if [[ $? -ne 0 ]]; then
  assert_contains "$out" "owner is required" "エラー出力"
else
  fail "--owner なしでも通ってしまった"
fi

it "対象パッケージだけを処理する構造になっている"
# DCB / ai-playbook それぞれの実行ブロックが条件分岐の中にあること
if grep -q 'if \[\[ -n "\$DCB_TAG" \]\]; then' "$RELEASE_SH" \
   && grep -q 'if \[\[ -n "\$PLAYBOOK_TAG" \]\]; then' "$RELEASE_SH"; then
  pass
else
  fail "実行ブロックがパッケージごとに分岐していない"
fi

# ── 公開済みリリースの不変性 ──────────────────────────────────────────────────

it "公開済みバージョンの検査が存在する"
if grep -q 'require_version_unpublished' "$RELEASE_SH"; then pass; else fail "検査がない"; fi

it "検査が副作用の前（preflight）にある"
# init_and_push_release_repo は公開 main を全置換する。それより後に気づいても手遅れ。
# DCB の実行フローで、版の重複検査が DCB の全置換より前にあることを見る。
# （関数定義内の呼び出しではなく、DCB を対象にした実行行を比較する）
guard="$(grep -n 'require_version_unpublished "\$OWNER/devcontainer-bootstrap"' "$RELEASE_SH" | head -1 | cut -d: -f1)"
push="$(grep -n 'init_and_push_release_repo "\$DCB_DIR"' "$RELEASE_SH" | head -1 | cut -d: -f1)"
if [[ -n "$guard" && -n "$push" && "$guard" -lt "$push" ]]; then
  pass
else
  fail "検査（$guard 行）が DCB の公開置換（$push 行）より後、または欠落"
fi

it "既存リリースを上書きしない"
# tag_and_release から --clobber 経路が消えていること。コメント行は対象外。
if grep -vE '^\s*#' "$RELEASE_SH" | grep 'gh release upload .*--clobber' >/dev/null; then
  fail "--clobber による資産上書きが残っている"
else
  pass
fi

it "公開済みなら副作用ゼロで止まる"
# 実トークンにも公開リポジトリにも触れずに検証する。
# - gh: release view へ「存在する」と応答し、他のコマンドが呼ばれたら記録する
#       （呼ばれること自体が副作用の兆候）
# - git: status を clean と応答する。作業ツリーの汚れでテストの結果が変わらないようにする
stub="$(new_workdir)/bin"
mkdir -p "$stub"
cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "release" && "${2:-}" == "view" ]]; then exit 0; fi
echo "STUB: unexpected gh call: $*" >&2
exit 0
STUB
real_git="$(command -v git)"
cat > "$stub/git" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "status" ]]; then exit 0; fi
exec "$real_git" "\$@"
STUB
chmod +x "$stub/gh" "$stub/git"

# 版の重複は preflight の先頭で判定されるため、README の版と一致しない任意の版でよい。
# GITHUB_ACTIONS は明示する。--execute は Actions 上でのみ実行できるため、
# 実行環境（CI かローカルか）で結果が変わらないよう固定する
# （ガードそのものの検証は test-release-execution-guard.sh が持つ）。
out="$(cd "$REPO_ROOT" && PATH="$stub:$PATH" GITHUB_ACTIONS=true timeout 60 bash "$RELEASE_SH" \
        --owner test --dcb-version v9.9.9 --execute 2>&1)"
code=$?
if [[ $code -eq 0 ]]; then
  fail "公開済みでも成功してしまった"
elif printf '%s' "$out" | grep -q 'unexpected gh call'; then
  fail "止まる前に gh の別コマンドが呼ばれた（副作用の恐れ）:
$(printf '%s' "$out" | grep 'unexpected' | head -3)"
else
  assert_contains "$out" "already has a release" "エラー出力"
fi

it "ai-playbook もタグ検査が全置換より前にある"
# ai-playbook は push_source_and_tag（内部で init_and_push_release_repo）で全置換する。
# タグの重複検査がそれより前（preflight）にあること。
pb_guard="$(grep -n 'require_tag_unpublished "\$OWNER/ai-playbook"' "$RELEASE_SH" | head -1 | cut -d: -f1)"
pb_push="$(grep -n 'push_source_and_tag "\$PLAYBOOK_DIR"' "$RELEASE_SH" | head -1 | cut -d: -f1)"
if [[ -n "$pb_guard" && -n "$pb_push" && "$pb_guard" -lt "$pb_push" ]]; then
  pass
else
  fail "ai-playbook のタグ検査（$pb_guard 行）が全置換（$pb_push 行）より後、または欠落"
fi

it "ai-playbook は Release を作らない（タグのみ配布）"
# ai-playbook の実行ブロックに generate_standard_assets / tag_and_release が無いこと。
pb_block="$(sed -n '/if \[\[ -n "\$PLAYBOOK_TAG" \]\]; then/,/^fi$/p' "$RELEASE_SH" | tail -n +2)"
if printf '%s' "$pb_block" | grep -qE 'generate_standard_assets|tag_and_release'; then
  fail "ai-playbook が Release 資産を生成している（タグのみのはず）"
else
  pass
fi

it "版の重複はテスト実行より先に判定される"
# release-packages.sh の preflight から run_dcb_tests がテスト一式を起動するため、
# テストがこのスクリプトを呼ぶと再帰する。版の重複を先に判定することで、
# 再帰へ到達する前に止まる。順序が崩れると無限再帰でハングする。
guard="$(grep -n 'require_version_unpublished "\$OWNER/devcontainer-bootstrap"' "$RELEASE_SH" | head -1 | cut -d: -f1)"
tests_line="$(grep -n '^  run_dcb_tests$' "$RELEASE_SH" | head -1 | cut -d: -f1)"
if [[ -n "$guard" && -n "$tests_line" && "$guard" -lt "$tests_line" ]]; then
  pass
else
  fail "版の重複判定（$guard 行）が run_dcb_tests（$tests_line 行）より後、または欠落"
fi

exit_with_result
