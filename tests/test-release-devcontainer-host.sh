#!/usr/bin/env bash
# devcontainer-host（devhost）のリリース手順を機械照合する回帰テスト（#486）。
#
# ## 何を見るか
#
# devhost は、DCB のリリースへの同梱をやめ、公開リポジトリ devcontainer-host から独自の版で配る。
# 実際の公開は GitHub Actions でしか実行できない（scripts/release-packages.sh が拒否する）ので、
# ここでは副作用の無い範囲を確かめる。
#
#   1. 配布ツリーの生成と資産の生成（実物のスクリプトの関数を取り込んで通す）
#      - dev.sh・dev-up@.service・SHA256SUMS・RELEASE-MANIFEST.json・PACKAGE_ARCHIVE.tar.gz が揃う
#      - マニフェストの checksums と SHA256SUMS が、実物のハッシュと一致する
#      - 配布ツリーの dev.sh の `dev --version` が、指定した版を出す
#      - 公開済みの監査（verify_release_assets_dir）が通る
#   2. --host-version の dry-run（偽の gh で、公開側へ触れずに preflight と計画の表示まで）
#      - 公開済みの版は、副作用の前に止まる
#   3. release.yml の配線（入力・引数・GitHub App の対象リポジトリ・attestation の対象）
#   4. 古い版の dev（DCB に同梱されていた版）の self-update が、DCB から devhost/ が消えたとき
#      何も置き換えずに止まること
#
# 4 は tests/fixtures/legacy-dev-dcb-bundled.txt（#486 の直前の dev.sh をそのまま写したもの。
# 取得先が DCB のリリースで、archive から ./devhost/dev.sh を取り出す版）を実行して確かめる。
# 編集しないこと。編集すると「古い版」を確かめたことにならない。
#
# 依存: bash / tar / jq / python3（preflight のリンク検査）。ネットワークには出ない。
# bash 3.2 互換を維持する。

set -uo pipefail
export LC_ALL=C
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-release-devcontainer-host"

RELEASE_SH="$REPO_ROOT/scripts/release-packages.sh"
WF="$REPO_ROOT/.github/workflows/release.yml"
LEGACY_DEV="$TESTS_DIR/fixtures/legacy-dev-dcb-bundled.txt"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-release-host.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

sha_of() { sha256sum "$1" | awk '{print $1}'; }  # bsd-ok: このテストは Linux（Dev Container / CI）で回す

# ── 1. 配布ツリーと資産の生成 ────────────────────────────────────────────────

end="$(grep -n '^EXECUTE="false"' "$RELEASE_SH" | head -1 | cut -d: -f1)"
fns="$WORK/fns.sh"
head -n $((end - 1)) "$RELEASE_SH" > "$fns"

TEST_HOST_VER="9.8.7"
TEST_HOST_TAG="v$TEST_HOST_VER"
rel="$WORK/host-release"
(
  set -euo pipefail
  # shellcheck disable=SC1090
  . "$fns"
  cd "$REPO_ROOT"
  prepare_host_release_repo "$rel" "$TEST_HOST_TAG"
  # 実行ブロックと同じ指定（scripts/release-packages.sh の --host-version の節）。
  SUMS_TARGETS=("${HOST_SUMS_TARGETS[@]}")
  MANIFEST_CHECKSUM_TARGETS=("${HOST_INDIVIDUAL_ASSETS[@]}")
  generate_standard_assets "$rel" "devcontainer-host" "$TEST_HOST_VER"
) >"$WORK/stage.log" 2>&1
stage_rc=$?

it "配布ツリーと資産の生成が成功する"
if [[ $stage_rc -eq 0 ]]; then
  pass
else
  fail "生成に失敗した（終了コード $stage_rc）: $(tail -5 "$WORK/stage.log")"
fi

it "ステージングに dev.sh・dev-up@.service・SHA256SUMS・RELEASE-MANIFEST.json・PACKAGE_ARCHIVE.tar.gz がある"
missing=""
for f in dev.sh dev-up@.service SHA256SUMS RELEASE-MANIFEST.json PACKAGE_ARCHIVE.tar.gz; do
  [[ -f "$rel/$f" ]] || missing="$missing $f"
done
if [[ -z "$missing" ]]; then
  pass
else
  fail "無い資産:$missing"
fi

it "ステージングのルートに、ツリーの中身（README・selftest・*.example・termux/・LICENSE・CHANGELOG.md）が並ぶ"
missing=""
for f in README.md selftest.sh projects.example ssh_config.plain.example ssh_config.cloudflared.example \
         ssh_config.tailscale.example termux/shortcut.example LICENSE CHANGELOG.md; do
  [[ -f "$rel/$f" ]] || missing="$missing $f"
done
if [[ -z "$missing" ]]; then
  pass
else
  fail "無いファイル:$missing"
fi

it "packages/devcontainer-host/ で追跡しているファイルが、すべてステージングのルートに入る"
# 一覧を持たず、ツリーごと写している。追加したファイルが黙って配布から漏れないことを確かめる。
missing=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  [[ -f "$rel/${f#packages/devcontainer-host/}" ]] || missing="$missing $f"
done < <(git -C "$REPO_ROOT" ls-files packages/devcontainer-host)
if [[ -z "$missing" ]]; then
  pass
else
  fail "配布ツリーに無い:$missing"
fi

it "SHA256SUMS は dev.sh・dev-up@.service・PACKAGE_ARCHIVE.tar.gz を対象にし（attestation からアーカイブまで辿れる）、チェックサムの照合が通る"
if [[ -f "$rel/SHA256SUMS" ]]; then
  names="$(awk '{print $2}' "$rel/SHA256SUMS" | tr '\n' ' ')"
  if [[ "$names" == "dev.sh dev-up@.service PACKAGE_ARCHIVE.tar.gz " ]] && (cd "$rel" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then  # bsd-ok: Linux で回す
    pass
  else
    fail "SHA256SUMS の対象が違う、または照合に失敗する: $names"
  fi
else
  fail "SHA256SUMS が無い"
fi

it "マニフェストの checksums が、実物（archive・SHA256SUMS・dev.sh・dev-up@.service）と一致する"
if [[ -f "$rel/RELEASE-MANIFEST.json" ]]; then
  bad=""
  for f in PACKAGE_ARCHIVE.tar.gz SHA256SUMS dev.sh dev-up@.service; do
    want="$(jq -r --arg k "$f" '.checksums[$k] // empty' "$rel/RELEASE-MANIFEST.json")"
    got="$(sha_of "$rel/$f")"
    [[ -n "$want" && "$want" == "$got" ]] || bad="$bad $f(manifest=${want:-なし})"
  done
  if [[ -z "$bad" ]]; then pass; else fail "一致しない:$bad"; fi
else
  fail "RELEASE-MANIFEST.json が無い"
fi

it "マニフェストの package と version が、指定したとおり（package=devcontainer-host / version=$TEST_HOST_VER）"
if [[ -f "$rel/RELEASE-MANIFEST.json" ]]; then
  assert_eq "$(jq -r '.package + " " + .version' "$rel/RELEASE-MANIFEST.json")" "devcontainer-host $TEST_HOST_VER" "package / version"
else
  fail "RELEASE-MANIFEST.json が無い"
fi

it "マニフェストの assets に、dev.sh と dev-up@.service を含む 5 資産が載る"
if [[ -f "$rel/RELEASE-MANIFEST.json" ]]; then
  assets="$(jq -r '.assets | sort | join(" ")' "$rel/RELEASE-MANIFEST.json")"
  assert_eq "$assets" "PACKAGE_ARCHIVE.tar.gz RELEASE-MANIFEST.json SHA256SUMS dev-up@.service dev.sh" "assets"
else
  fail "RELEASE-MANIFEST.json が無い"
fi

it "ステージングの dev.sh の dev --version が、指定した版を出す"
assert_eq "$(bash "$rel/dev.sh" --version 2>&1)" "dev $TEST_HOST_TAG" "dev --version"

it "ステージングの dev.sh の dev version が、同じ版を出す"
assert_eq "$(bash "$rel/dev.sh" version 2>&1)" "dev $TEST_HOST_TAG" "dev version"

it "ステージングの dev.sh は、DEV_VERSION の 1 行だけが開発リポジトリの dev.sh と違う"
diff_out="$(diff "$REPO_ROOT/packages/devcontainer-host/dev.sh" "$rel/dev.sh" || true)"
diff_lines="$(printf '%s\n' "$diff_out" | grep -c '^[<>]' || true)"
diff_ver_lines="$(printf '%s\n' "$diff_out" | grep -c '^[<>] DEV_VERSION=' || true)"
if [[ "$diff_lines" == "2" && "$diff_ver_lines" == "2" ]]; then
  pass
else
  fail "dev.sh の差分が DEV_VERSION の 1 行（2 行の差分）ではない: 差分 $diff_lines 行（うち DEV_VERSION $diff_ver_lines 行）"
fi

it "ステージングの dev.sh は実行権限を保ち、構文が通り、2 行目の接頭辞「# dev — 」を持つ"
l2="$(sed -n '2p' "$rel/dev.sh")"
if [[ -x "$rel/dev.sh" ]] && bash -n "$rel/dev.sh" && [[ "$l2" == '# dev — '* ]]; then
  pass
else
  fail "実行権限・構文・2 行目のどれかが外れている（2 行目: $l2）"
fi

it "PACKAGE_ARCHIVE.tar.gz に ./dev.sh があり、中の dev.sh も指定した版を出す（版の書き込みが archive の前）"
if [[ -f "$rel/PACKAGE_ARCHIVE.tar.gz" ]]; then
  xd="$WORK/extract"
  mkdir -p "$xd"
  if tar -xzf "$rel/PACKAGE_ARCHIVE.tar.gz" -C "$xd" ./dev.sh ./termux/shortcut.example >/dev/null 2>&1 \
     && [[ "$(bash "$xd/dev.sh" --version 2>&1)" == "dev $TEST_HOST_TAG" ]]; then
    pass
  else
    fail "archive から ./dev.sh を取り出せない、または版が違う"
  fi
else
  fail "PACKAGE_ARCHIVE.tar.gz が無い"
fi

it "ステージングの selftest.sh が DEVHOST_SELFTEST_PASS（配布先でそのまま自己試験が回る）"
selftest_out="$(bash "$rel/selftest.sh" 2>/dev/null || true)"
if [[ -f "$rel/selftest.sh" ]] && [[ $'\n'"$selftest_out"$'\n' == *$'\nDEVHOST_SELFTEST_PASS\n'* ]]; then
  pass
else
  fail "配布ツリーの selftest.sh が通らない"
fi

it "公開済みの監査（verify_release_assets_dir）が、ステージングを整合ありと判定する"
# shellcheck disable=SC1090
if (. "$fns"; verify_release_assets_dir "$rel" "staging" >"$WORK/audit.log" 2>&1); then
  pass
else
  fail "監査が不整合を報告した: $(grep FAIL "$WORK/audit.log" | head -3)"
fi

it "監査は、dev.sh を書き換えたステージングを落とす（検査が死んでいない）"
tampered="$WORK/tampered"
cp -R "$rel" "$tampered"
printf '\n# tampered\n' >> "$tampered/dev.sh"
# shellcheck disable=SC1090
if (. "$fns"; verify_release_assets_dir "$tampered" "tampered" >/dev/null 2>&1); then
  fail "書き換えた dev.sh を整合ありと判定した"
else
  pass
fi

it "版の書き込みは、空や形の違うタグを拒む（stamp_host_version の負例）"
badtag="$WORK/badtag"
mkdir -p "$badtag"
cp "$REPO_ROOT/packages/devcontainer-host/dev.sh" "$badtag/dev.sh"
if ( . "$fns"; stamp_host_version "$badtag" "" ) >/dev/null 2>&1 \
   || ( . "$fns"; stamp_host_version "$badtag" "1.2.3" ) >/dev/null 2>&1; then
  fail "空や形の違うタグで書き込みが成功した"
else
  pass
fi

it "版の書き込みは、DEV_VERSION の行が無いと止まる（stamp_host_version の負例）"
nostamp="$WORK/nostamp"
mkdir -p "$nostamp"
grep -v '^DEV_VERSION=' "$REPO_ROOT/packages/devcontainer-host/dev.sh" > "$nostamp/dev.sh"
if ( . "$fns"; stamp_host_version "$nostamp" v1.2.3 ) >/dev/null 2>&1; then
  fail "DEV_VERSION の行が無いのに書き込みが成功した"
else
  pass
fi

it "開発リポジトリの dev.sh に DEV_VERSION=\"vX.Y.Z\" の行がちょうど 1 つある"
n="$(grep -cE '^DEV_VERSION="v[0-9]+\.[0-9]+\.[0-9]+"$' "$REPO_ROOT/packages/devcontainer-host/dev.sh" || true)"
assert_eq "$n" "1" "DEV_VERSION の行数"

# 現行の版は README の取得手順（TAG=）から読む。版を上げても、固定の版でこの試験が落ちないようにする。
CUR_TAG="$(sed -n 's/^TAG=\(v[0-9][0-9.]*\).*/\1/p' "$REPO_ROOT/packages/devcontainer-host/README.md" | sed -n '1p')"

it "追跡外のファイルは、配布ツリーに入らない"
untracked="$REPO_ROOT/packages/devcontainer-host/zz-untracked-$$.txt"
printf 'secret\n' > "$untracked"
rel2="$WORK/host-release-untracked"
( set -euo pipefail; . "$fns"; cd "$REPO_ROOT"; prepare_host_release_repo "$rel2" "$TEST_HOST_TAG" ) >/dev/null 2>&1
rc2=$?
rm -f "$untracked"
if [[ $rc2 -eq 0 && -f "$rel2/dev.sh" && ! -e "$rel2/zz-untracked-$$.txt" ]]; then
  pass
else
  fail "追跡外のファイルが配布ツリーに入った、または生成に失敗した（終了コード $rc2）"
fi

it "README の固定の版・リリースノートの見出しが公開するタグと食い違うと、preflight の文書検査が落ちる"
docs_ok=0
( . "$fns"; cd "$REPO_ROOT"; validate_host_docs "$CUR_TAG" ) >/dev/null 2>&1 || docs_ok=1
( . "$fns"; cd "$REPO_ROOT"; validate_host_docs v9.9.9 ) >/dev/null 2>&1 && docs_ok=2
[[ -n "$CUR_TAG" ]] || docs_ok=3
if [[ $docs_ok -eq 0 ]]; then
  pass
else
  fail "validate_host_docs の判定が期待と違う（$docs_ok: 1 = 現行の版で落ちた / 2 = 食い違う版で通った）"
fi

it "文書の照合は語の境界で行う（v0.1.0 に対して v0.1.00 や v0.1.0-rc を通さない）"
docs_fx="$WORK/docs-fx"
mkdir -p "$docs_fx/packages/devcontainer-host" "$docs_fx/docs/release"
printf '## v0.1.0\n' > "$docs_fx/docs/release/release-notes-devcontainer-host.md"
check_docs() { # 引数: README の本文。公開するタグは v0.1.0。0 = 通った
  printf '%s\n' "$1" > "$docs_fx/packages/devcontainer-host/README.md"
  ( . "$fns"; cd "$docs_fx"; validate_host_docs v0.1.0 ) >/dev/null 2>&1
}
bad=""
check_docs $'TAG=v0.1.0\n固定は `--version v0.1.0` で行う' || bad="$bad 一致する本文が落ちた"
check_docs $'TAG=v0.1.00\n--version v0.1.0' && bad="$bad TAG=v0.1.00"
check_docs $'TAG=v0.1.0\n--version v0.1.00' && bad="$bad --version=v0.1.00"
check_docs $'TAG=v0.1.0-rc1\n--version v0.1.0' && bad="$bad TAG=v0.1.0-rc1"
check_docs $'TAG=v0.1.0.1\n--version v0.1.0' && bad="$bad TAG=v0.1.0.1"
check_docs $'TAG=vX0Y1Z0\n--version v0.1.0' && bad="$bad ドットが任意の文字に一致"
printf '## v0.1.00\n' > "$docs_fx/docs/release/release-notes-devcontainer-host.md"
check_docs $'TAG=v0.1.0\n--version v0.1.0' && bad="$bad リリースノートの見出し v0.1.00"
if [[ -z "$bad" ]]; then pass; else fail "境界の判定が期待と違う:$bad"; fi

it "文書の照合は、入手手順の TAG= の行と --version の例の行そのものを見る（説明文に新しい版があるだけでは通らない）"
bad=""
printf '## v0.1.0\n' > "$docs_fx/docs/release/release-notes-devcontainer-host.md"
check_docs $'TAG=v0.1.0   # 最新\n`dev self-update --version v0.1.0`' || bad="$bad 一致する本文が落ちた"
check_docs $'TAG=v0.0.9\n最新は v0.1.0 です。TAG=v0.1.0 を使ってください\n`--version v0.1.0`' && bad="$bad 説明文にだけ新しい TAG=v0.1.0 がある"
check_docs $'TAG=v0.0.9\n新しい版は v0.1.0 です\n`--version v0.1.0`' && bad="$bad 説明文にだけ新しい版がある"
check_docs $'  TAG=v0.1.0\n`--version v0.1.0`' && bad="$bad TAG= が行頭でない"
check_docs $'TAG=v0.1.0\nTAG=v0.0.9\n`--version v0.1.0`' && bad="$bad 古い TAG= の行が残っている"
check_docs $'TAG=v0.1.0\n`--version v0.0.9`' && bad="$bad --version の例が古い"
check_docs $'TAG=v0.1.0\n`--version v0.0.9` と `--version v0.1.0`' && bad="$bad 古い --version の例が混ざっている"
check_docs $'TAG=v0.1.0\n--version の例は無い' && bad="$bad --version の例が無い"
check_docs $'説明だけ\n`--version v0.1.0`' && bad="$bad TAG= の行が無い"
if [[ -z "$bad" ]]; then pass; else fail "照合の対象が期待と違う:$bad"; fi

# ── README の入手手順を、食い違うハッシュで実行する（#491） ───────────────────

HOST_README="$REPO_ROOT/packages/devcontainer-host/README.md"

# fenced code block のうち、needle を含む最初の 1 つの中身を返す。
extract_block() { # $1 = ファイル, $2 = needle
  awk -v n="$2" '
    /^```/ { if (inb) { if (hit) { printf "%s", buf; exit } inb = 0; buf = ""; hit = 0 } else { inb = 1 } ; next }
    inb { buf = buf $0 "\n"; if (index($0, n)) hit = 1 }
  ' "$1"
}
BLOCK_ARCHIVE="$(extract_block "$HOST_README" 'mkdir devhost')"
BLOCK_DEVSH="$(extract_block "$HOST_README" '-o dev.sh')"

# 偽の curl: URL 末尾のファイル名で $FAKE_REL_DIR のファイルを写す（ネットワークには出ない）。
rb_bin="$WORK/readme-bin"
mkdir -p "$rb_bin"
cat > "$rb_bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
cp "$FAKE_REL_DIR/${url##*/}" "$out"
STUB
chmod +x "$rb_bin/curl"

# README の block を、偽の curl と作業ディレクトリで実行する。$1 = リリース資産、$2 = コード。
run_readme_code() {
  local reldir="$1" code="$2"
  RUN_WORK="$(mktemp -d "$WORK/readme-run.XXXXXX")"
  ( cd "$RUN_WORK" && PATH="$rb_bin:$PATH" FAKE_REL_DIR="$reldir" bash -c "$code" >/dev/null 2>&1 )
  RUN_RC=$?
}

it "README の入手手順（アーカイブ・dev.sh）のコードブロックを抜き出せる"
if [[ -n "$BLOCK_ARCHIVE" && -n "$BLOCK_DEVSH" ]]; then pass; else fail "block を抜き出せない（アーカイブ: ${#BLOCK_ARCHIVE} 字 / dev.sh: ${#BLOCK_DEVSH} 字）"; fi

it "対照: 正しい資産では、アーカイブは展開され、dev.sh は設置される"
run_readme_code "$rel" "$BLOCK_ARCHIVE"
ok_a=$RUN_RC; dir_a="$RUN_WORK"
run_readme_code "$rel" "$BLOCK_ARCHIVE
$BLOCK_DEVSH"
if [[ $ok_a -eq 0 && -f "$dir_a/devhost/dev.sh" && $RUN_RC -eq 0 && -f "$RUN_WORK/dev.sh" ]]; then
  pass
else
  fail "正しい資産で失敗した（アーカイブ rc=$ok_a / dev.sh rc=$RUN_RC）"
fi

it "アーカイブのハッシュが食い違うと、展開されず非 0 で終わる"
bad_rel="$WORK/bad-archive"
cp -R "$rel" "$bad_rel"
jq '.checksums["PACKAGE_ARCHIVE.tar.gz"] = "0000000000000000000000000000000000000000000000000000000000000000"' "$rel/RELEASE-MANIFEST.json" > "$bad_rel/RELEASE-MANIFEST.json"
run_readme_code "$bad_rel" "$BLOCK_ARCHIVE"
if [[ $RUN_RC -ne 0 && ! -e "$RUN_WORK/devhost" ]]; then pass; else fail "終了コード $RUN_RC、展開: $(ls "$RUN_WORK" | tr '\n' ' ')"; fi

it "dev.sh のハッシュが食い違うと、dev.sh を消し、非 0 で終わる"
bad_dev="$WORK/bad-devsh"
cp -R "$rel" "$bad_dev"
printf '# 改ざん\n' >> "$bad_dev/dev.sh"
run_readme_code "$bad_dev" "$BLOCK_ARCHIVE
$BLOCK_DEVSH"
# アーカイブ側は正しいので、最後の終了コードが dev.sh の照合の結果になる。
if [[ $RUN_RC -ne 0 && ! -e "$RUN_WORK/dev.sh" ]]; then pass; else fail "終了コード $RUN_RC、設置: $(ls "$RUN_WORK" | tr '\n' ' ')"; fi

# ── 2. --host-version の dry-run ─────────────────────────────────────────────

stub="$WORK/bin"
mkdir -p "$stub"
real_git="$(command -v git)"
# gh: release view は「未公開」（exit 1）、ほかの呼び出しは副作用の兆候として記録して落とす。
cat > "$stub/gh" <<STUB
#!/usr/bin/env bash
echo "gh \$*" >> "$WORK/gh-calls.log"
if [[ "\${1:-}" == "release" && "\${2:-}" == "view" ]]; then exit "\${STUB_RELEASE_VIEW_RC:-1}"; fi
echo "STUB: unexpected gh call: \$*" >&2
exit 1
STUB
# git: status は clean と答える（作業ツリーの汚れでテストの結果が変わらないように）。
cat > "$stub/git" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "status" ]]; then exit 0; fi
exec "$real_git" "\$@"
STUB
chmod +x "$stub/gh" "$stub/git"

it "--host-version の dry-run が 0 で終わり、計画に配布物と資産が出る"
: > "$WORK/gh-calls.log"
out="$(cd "$REPO_ROOT" && PATH="$stub:$PATH" timeout 300 bash "$RELEASE_SH" --owner test --host-version "$CUR_TAG" 2>&1)"
code=$?
if [[ $code -eq 0 ]] \
   && [[ "$out" == *'[ok] preflight checks passed'* ]] \
   && [[ "$out" == *'devcontainer-host distributed files'* ]] \
   && [[ "$out" == *'dev.sh dev-up@.service RELEASE-MANIFEST.json SHA256SUMS PACKAGE_ARCHIVE.tar.gz'* ]] \
   && [[ "$out" == *'dry-run mode'* ]]; then
  pass
else
  fail "dry-run が期待どおりでない（終了コード $code）: $(printf '%s' "$out" | tail -8)"
fi

it "dry-run は devcontainer-host の公開有無だけを問い合わせ、公開側へ触れない"
calls="$(grep -v "^gh release view $CUR_TAG --repo test/devcontainer-host" "$WORK/gh-calls.log" || true)"
if [[ -z "$calls" ]] && grep -q "gh release view $CUR_TAG --repo test/devcontainer-host" "$WORK/gh-calls.log"; then
  pass
else
  fail "想定外の gh の呼び出し: $calls"
fi

it "公開済みの版は、副作用の前に止まる"
out="$(cd "$REPO_ROOT" && PATH="$stub:$PATH" STUB_RELEASE_VIEW_RC=0 GITHUB_ACTIONS=true timeout 60 bash "$RELEASE_SH" --owner test --host-version "$CUR_TAG" --execute 2>&1)"
code=$?
if [[ $code -ne 0 ]] && [[ "$out" == *"test/devcontainer-host already has a release for $CUR_TAG"* ]]; then
  pass
else
  fail "公開済みの版で止まらなかった（終了コード $code）: $(printf '%s' "$out" | tail -3)"
fi

it "版の形が違うと止まる"
out="$(cd "$REPO_ROOT" && PATH="$stub:$PATH" timeout 60 bash "$RELEASE_SH" --owner test --host-version 0.1.0 2>&1)"
code=$?
if [[ $code -ne 0 ]] && [[ "$out" == *'invalid tag format'* ]]; then
  pass
else
  fail "形の違う版で止まらなかった（終了コード $code）"
fi

it "版の指定が 1 つも無いと止まる（--host-version を指定対象に数えている）"
out="$(cd "$REPO_ROOT" && PATH="$stub:$PATH" timeout 60 bash "$RELEASE_SH" --owner test 2>&1)"
code=$?
if [[ $code -ne 0 ]] && [[ "$out" == *'--host-version'* ]]; then
  pass
else
  fail "エラーが --host-version に触れていない（終了コード $code）"
fi

it "監査の対象に devcontainer-host を含む"
if grep -q 'local repos=("\$owner/devcontainer-bootstrap" "\$owner/devcontainer-host")' "$RELEASE_SH"; then
  pass
else
  fail "audit_release_assets の repos に devcontainer-host が無い"
fi

# ── 3. release.yml の配線 ────────────────────────────────────────────────────

it "release.yml が host-version の入力を持ち、release-packages.sh の --host-version へ渡す"
if grep -qE "^[[:space:]]+host-version:" "$WF" \
   && grep -q "inputs\['host-version'\]" "$WF" \
   && grep -q -- '--host-version' "$WF"; then
  pass
else
  fail "release.yml の host-version の入力、または --host-version への受け渡しが無い"
fi

it "release.yml の GitHub App のトークンが devcontainer-host を対象に含む"
repos_step="$(awk '/- name: Resolve the repositories/,/- name: Generate a release bot token/' "$WF")"
# devcontainer-host は host-version を指定したときだけ加える（常に含めると、App が install されていない間は
# DCB だけ・ai-playbook だけのリリースまで落ちる）。
if [[ "$repos_step" == *'if [ -n "$HOST_VERSION" ]'*'echo devcontainer-host'* ]] \
   && [[ "$(cat "$WF")" == *'repositories: ${{ steps.repos.outputs.list }}'* ]]; then
  pass
else
  fail "create-github-app-token の対象に devcontainer-host を host-version のときだけ加える手前のステップが無い"
fi

it "release.yml の App のトークンの repositories に、devcontainer-host を固定で書いていない"
tokblock="$(awk '/- name: Generate a release bot token/,/repositories:/' "$WF")"
if [[ "$tokblock" == *devcontainer-host* ]]; then
  fail "トークンのステップに devcontainer-host が固定で書かれている"
else
  pass
fi

it "release.yml の入力検証が host-version だけの指定を許す"
validate_block="$(awk '/- name: Validate inputs/,/- uses: actions\/checkout/' "$WF")"
if [[ "$validate_block" == *HOST_VERSION* ]]; then
  pass
else
  fail "Validate inputs が HOST_VERSION を扱っていない（host-version だけの実行が弾かれる）"
fi

it "release.yml が devcontainer-host の SHA256SUMS を attestation の対象にしている"
if grep -qF 'devcontainer-host:digest-host' "$WF"; then
  pass
else
  fail "attestation の対象に devcontainer-host の digest が無い"
fi

# ── 4. 古い版の dev の self-update ───────────────────────────────────────────

it "古い版の dev の取得物が、取得先を DCB のリリースとし、archive から ./devhost/dev.sh を取り出す版である"
# この前提が変わると、下の 2 件は古い版を確かめたことにならない。
if [[ -f "$LEGACY_DEV" ]] \
   && grep -q '^RELEASE_BASE_URL="https://github.com/ojos/devcontainer-bootstrap/releases"$' "$LEGACY_DEV" \
   && grep -q './devhost/dev.sh' "$LEGACY_DEV"; then
  pass
else
  fail "tests/fixtures/legacy-dev-dcb-bundled.txt が古い版の dev.sh でない（編集しないこと）"
fi

# 偽の curl: DCB のリリースの URL だけを受け、URL 末尾のファイル名で $FAKE_DCB_DIR のファイルを写す。
cat > "$stub/curl" <<'STUB'
#!/usr/bin/env bash
[[ $# -eq 4 && "$1" == "-fsSL" && "$3" == "-o" ]] || { echo "fake curl: 想定外の呼び出し: $*" >&2; exit 2; }
case "$2" in
  https://github.com/ojos/devcontainer-bootstrap/releases/latest/download/* | https://github.com/ojos/devcontainer-bootstrap/releases/download/v*/*) ;;
  *) echo "fake curl: DCB のリリースの URL ではない: $2" >&2; exit 2 ;;
esac
cp "$FAKE_DCB_DIR/${2##*/}" "$4"
STUB
chmod +x "$stub/curl"

# 同梱をやめた後の、DCB の最新リリース（本物の配布ツリーと資産の生成）。
dcb_after="$WORK/dcb-after"
(
  set -euo pipefail
  # shellcheck disable=SC1090
  . "$fns"
  cd "$REPO_ROOT"
  SUMS_TARGETS=(bootstrap.sh doctor.sh PACKAGE_ARCHIVE.tar.gz)
  prepare_dcb_release_repo "$dcb_after"
  generate_standard_assets "$dcb_after" "devcontainer-bootstrap" "0.0.0"
) >/dev/null 2>&1

# 同梱していた頃の、DCB のリリース（対照群。古い版の dev が、本来は更新できる形）。
dcb_before="$WORK/dcb-before"
mkdir -p "$dcb_before/devhost"
printf '%s\n%s\necho from-old-dcb-release\n' "$(sed -n '1p' "$LEGACY_DEV")" "$(sed -n '2p' "$LEGACY_DEV")" > "$dcb_before/devhost/dev.sh"
(cd "$dcb_before" && tar -czf PACKAGE_ARCHIVE.tar.gz ./devhost)
printf '{ "package": "devcontainer-bootstrap", "version": "0.0.0", "checksums": { "PACKAGE_ARCHIVE.tar.gz": "%s" } }\n' \
  "$(sha_of "$dcb_before/PACKAGE_ARCHIVE.tar.gz")" > "$dcb_before/RELEASE-MANIFEST.json"

selfdir="$WORK/self"
mkdir -p "$selfdir"
self="$selfdir/dev"

it "対照: 同梱していた頃の DCB のリリースなら、古い版の dev は更新できる（試験の枠組みが動いている）"
cp "$LEGACY_DEV" "$self"
chmod 0755 "$self"
out="$(PATH="$stub:$PATH" FAKE_DCB_DIR="$dcb_before" DEV_SELF_PATH="$self" bash "$self" self-update 2>&1)"
code=$?
if [[ $code -eq 0 ]] && grep -q 'from-old-dcb-release' "$self"; then
  pass
else
  fail "古い版の dev が、同梱していた頃のリリースで更新できない（終了コード $code）: $(printf '%s' "$out" | tail -3)"
fi

it "同梱をやめた後の DCB の最新リリースでは、古い版の dev の self-update は何も置き換えずに止まる（終了コード 1）"
cp "$LEGACY_DEV" "$self"
chmod 0755 "$self"
out="$(PATH="$stub:$PATH" FAKE_DCB_DIR="$dcb_after" DEV_SELF_PATH="$self" bash "$self" self-update 2>&1)"
code=$?
if [[ $code -eq 1 ]] && cmp -s "$LEGACY_DEV" "$self" && [[ "$out" == *'何も置き換えていません'* ]]; then
  pass
else
  fail "安全に止まらなかった（終了コード $code、置き換え先の変化: $(cmp -s "$LEGACY_DEV" "$self" && echo なし || echo あり)）: $(printf '%s' "$out" | tail -3)"
fi

it "止まったあとの置き換え先に、一時ファイルが残らない"
if [[ "$(ls -A "$selfdir")" == "dev" ]]; then
  pass
else
  fail "残っている: $(ls -A "$selfdir")"
fi

exit_with_result
