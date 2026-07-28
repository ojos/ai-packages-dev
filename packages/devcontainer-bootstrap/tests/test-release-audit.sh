#!/usr/bin/env bash
# リリース資産の監査（audit）が、存在確認ではなく SHA256 の再計算で整合性を
# 検証していることを固定する。
#
# 存在するだけを見る検査は「実質を検査できず、儀式のみを検査できるもの」であり、
# 公開後に資産が差し替わっても素通りする（実際のリリース出力も
# `[audit] OK ... RELEASE-MANIFEST.json` と存在確認だけだった）。
# ここでは意図的に壊した入力で必ず落ちること、どのファイルのどの値が食い違ったかが
# 出力に現れること、そして打ち切った件数が隠されないことを固定する。
#
# ネットワークには出ない。公開リリースの取得は gh のスタブで置き換える。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-release-audit"

RELEASE_SH="$REPO_ROOT/scripts/release-packages.sh"
NOTIFY_SH="$REPO_ROOT/scripts/audit-failure-notify.sh"

# 実物のスクリプトから関数定義部分だけを取り込む（実行部の手前まで）。
# テスト側に検証ロジックを写すと、スクリプトを変えても検出できない。
FNS="$(new_workdir)/fns.sh"
end="$(grep -n '^EXECUTE="false"' "$RELEASE_SH" | head -1 | cut -d: -f1)"
head -n $((end - 1)) "$RELEASE_SH" > "$FNS"

# スクリプトが宣言している checksum 対象を読み取る（test-release-contract.sh と同じ流儀）。
DCB_SUMS_TARGETS="$(grep -B3 'generate_standard_assets "\$DCB_DIR"' "$RELEASE_SH" \
  | grep -oE 'SUMS_TARGETS=\([^)]*\)' | head -1 | sed 's/^SUMS_TARGETS=(//; s/)$//')"

# 正常なリリース資産一式を作る。実物の生成関数をそのまま使う。
make_release_dir() {
  local dir="$1"
  (
    set -euo pipefail
    # shellcheck disable=SC1090
    . "$FNS"
    cd "$REPO_ROOT"
    # shellcheck disable=SC2206
    SUMS_TARGETS=($DCB_SUMS_TARGETS)
    prepare_dcb_release_repo "$dir"
    generate_standard_assets "$dir" "devcontainer-bootstrap" "0.0.0"
  ) >/dev/null 2>&1
}

# 検証関数を単独で走らせ、出力を返す。戻り値は呼び出し側が $? で受ける。
run_verify() {
  local dir="$1"
  (
    # shellcheck disable=SC1090
    . "$FNS"
    verify_release_assets_dir "$dir" "test@v0.0.0" 2>&1
  )
}

BASE="$(new_workdir)/release"
make_release_dir "$BASE"

it "正常なリリース資産を生成できる"
assert_file_exists "$BASE/SHA256SUMS"

# ── 1. 正常な資産で成功する ──────────────────────────────────────────────────

it "正常なリリース資産に対して検証が成功する"
out="$(run_verify "$BASE")"
rc=$?
if [[ $rc -eq 0 ]]; then
  pass
else
  fail "正常な資産で失敗した（rc=$rc）:
$(printf '%s' "$out" | head -10)"
fi

it "正常な資産では OK 行に SHA256SUMS の対象が現れる"
assert_contains "$out" "bootstrap.sh" "検証出力"

# ── 2. ハッシュを 1 バイト改変した入力で落ちる ───────────────────────────────

it "配布ファイルを 1 バイト改変すると非ゼロで終了する"
d="$(new_workdir)/tampered-file"
cp -R "$BASE" "$d"
# 1 バイトだけ足す。中身の意味は変えず、ハッシュだけを変える。
printf ' ' >> "$d/bootstrap.sh"
out="$(run_verify "$d")"
rc=$?
if [[ $rc -ne 0 ]]; then
  pass
else
  fail "改変した資産で成功してしまった"
fi

it "改変されたファイル名が出力に現れる"
assert_contains "$out" "bootstrap.sh — SHA256SUMS の記載と実ファイルが不一致" "検証出力"

it "食い違った両方の値が出力に現れる"
if printf '%s' "$out" | grep -q 'SHA256SUMS 記載:' \
   && printf '%s' "$out" | grep -q '実ファイル再計算:'; then
  pass
else
  fail "記載値と再計算値の対比が出力に無い:
$(printf '%s' "$out" | head -10)"
fi

# ── 3. SHA256SUMS ごと辻褄を合わせても、マニフェスト側で落ちる ───────────────
# 資産を差し替える側は SHA256SUMS も書き換えられる。SHA256SUMS の自己照合だけでは
# この場合に何も検出できない。マニフェストが SHA256SUMS 自身のハッシュを記録して
# いることが検証チェーンの根で、そこが切れていないことを固定する。

it "SHA256SUMS ごと書き換えるとマニフェストとの不一致で落ちる"
d="$(new_workdir)/tampered-sums"
cp -R "$BASE" "$d"
printf ' ' >> "$d/bootstrap.sh"
# 語分割は意図的（スクリプトが宣言する対象の一覧を展開する）。
# shellcheck disable=SC2086
( cd "$d" && sha256sum $DCB_SUMS_TARGETS > SHA256SUMS ) >/dev/null 2>&1
out="$(run_verify "$d")"
rc=$?
if [[ $rc -ne 0 ]]; then
  assert_contains "$out" "SHA256SUMS — RELEASE-MANIFEST.json の記載と実ファイルが不一致" "検証出力"
else
  fail "SHA256SUMS を辻褄合わせされた資産で成功してしまった"
fi

# ── 4. マニフェストと SHA256SUMS の矛盾を検出する ────────────────────────────

it "マニフェストと SHA256SUMS の記載が矛盾すると落ちる"
d="$(new_workdir)/contradiction"
cp -R "$BASE" "$d"
jq '.checksums["bootstrap.sh"] = "0000000000000000000000000000000000000000000000000000000000000000"' \
  "$d/RELEASE-MANIFEST.json" > "$d/m.tmp" && mv "$d/m.tmp" "$d/RELEASE-MANIFEST.json"
out="$(run_verify "$d")"
rc=$?
if [[ $rc -ne 0 ]]; then
  assert_contains "$out" "RELEASE-MANIFEST.json と SHA256SUMS の記載が矛盾" "検証出力"
else
  fail "矛盾した宣言で成功してしまった"
fi

it "マニフェストが記録するアーカイブの改変を検出する"
d="$(new_workdir)/tampered-archive"
cp -R "$BASE" "$d"
printf ' ' >> "$d/PACKAGE_ARCHIVE.tar.gz"
out="$(run_verify "$d")"
rc=$?
if [[ $rc -ne 0 ]]; then
  assert_contains "$out" "PACKAGE_ARCHIVE.tar.gz — RELEASE-MANIFEST.json の記載と実ファイルが不一致" "検証出力"
else
  fail "アーカイブを改変した資産で成功してしまった"
fi

it "必須資産が欠けると落ちる"
d="$(new_workdir)/missing-asset"
cp -R "$BASE" "$d"
rm -f "$d/PACKAGE_ARCHIVE.tar.gz"
out="$(run_verify "$d")"
rc=$?
if [[ $rc -ne 0 ]]; then
  assert_contains "$out" "必須資産が無い" "検証出力"
else
  fail "必須資産が欠けても成功してしまった"
fi

it "SHA256SUMS が空だと落ちる"
# 空の SHA256SUMS は sha256sum -c を無条件に通す。「検証していないのに緑」を防ぐ。
d="$(new_workdir)/empty-sums"
cp -R "$BASE" "$d"
: > "$d/SHA256SUMS"
out="$(run_verify "$d")"
rc=$?
if [[ $rc -ne 0 ]]; then
  assert_contains "$out" "SHA256SUMS が 1 行も列挙していない" "検証出力"
else
  fail "空の SHA256SUMS で成功してしまった"
fi

# ── 4b. 監査対象ディレクトリの外を指す名前は FAIL ────────────────────────────
# SHA256SUMS / RELEASE-MANIFEST.json に載る名前は監査対象（＝外部）の入力で、
# そのまま "$dir/$name" へ連結すると外のファイルを照合してしまう。しかも外側に
# 辻褄の合うファイルを置けば「OK」と出せてしまい、検証が意味を失う。
# ここでは実際に外側へ正しいハッシュのファイルを置き、素通りしないことを固定する。

# 監査対象の 1 階層外に、ハッシュの一致する「囮」を置く。
setup_escape_target() {
  local root="$1"
  mkdir -p "$root/release"
  cp -R "$BASE"/. "$root/release"/
  printf 'escaped\n' > "$root/escape.txt"
  sha256sum "$root/escape.txt" | awk '{print $1}'
}

it "SHA256SUMS がディレクトリ外を指す名前を持つと落ちる"
d="$(new_workdir)/escape-sums"
mkdir -p "$d"
h="$(setup_escape_target "$d")"
printf '%s  ../escape.txt\n' "$h" >> "$d/release/SHA256SUMS"
out="$(run_verify "$d/release")"
rc=$?
if [[ $rc -ne 0 ]]; then
  assert_contains "$out" "SHA256SUMS の項目名が単一ファイル名でない" "検証出力"
else
  fail "ディレクトリ外を指す SHA256SUMS の項目で成功してしまった"
fi

it "checksums のキーがディレクトリ外を指すと落ちる"
d="$(new_workdir)/escape-checksums"
mkdir -p "$d"
h="$(setup_escape_target "$d")"
jq --arg h "$h" '.checksums["../escape.txt"] = $h' \
  "$d/release/RELEASE-MANIFEST.json" > "$d/m.tmp" && mv "$d/m.tmp" "$d/release/RELEASE-MANIFEST.json"
out="$(run_verify "$d/release")"
rc=$?
if [[ $rc -ne 0 ]]; then
  assert_contains "$out" "checksums のキーが単一ファイル名でない" "検証出力"
else
  fail "ディレクトリ外を指す checksums のキーで成功してしまった"
fi

it "assets の要素がディレクトリ外を指すと落ちる"
d="$(new_workdir)/escape-assets"
mkdir -p "$d"
setup_escape_target "$d" >/dev/null
jq '.assets += ["../escape.txt"]' \
  "$d/release/RELEASE-MANIFEST.json" > "$d/m.tmp" && mv "$d/m.tmp" "$d/release/RELEASE-MANIFEST.json"
out="$(run_verify "$d/release")"
rc=$?
if [[ $rc -ne 0 ]]; then
  assert_contains "$out" "assets の要素が単一ファイル名でない" "検証出力"
else
  fail "ディレクトリ外を指す assets の要素で成功してしまった"
fi

# ── 4c. マニフェストの型不正は FAIL ──────────────────────────────────────────
# checksums / assets が期待と違う型になると、後続の jq がエラーで何も出力せず
# 照合ループが空入力のまま素通りする。「検査していないのに緑」を防ぐ。

it "checksums が object でないと落ちる"
d="$(new_workdir)/bad-checksums-type"
cp -R "$BASE" "$d"
jq '.checksums = []' "$d/RELEASE-MANIFEST.json" > "$d/m.tmp" && mv "$d/m.tmp" "$d/RELEASE-MANIFEST.json"
out="$(run_verify "$d")"
rc=$?
if [[ $rc -ne 0 ]]; then
  assert_contains "$out" "checksums が object でない" "検証出力"
else
  fail "checksums の型が不正でも成功してしまった"
fi

it "assets が array でないと落ちる"
d="$(new_workdir)/bad-assets-type"
cp -R "$BASE" "$d"
jq '.assets = {}' "$d/RELEASE-MANIFEST.json" > "$d/m.tmp" && mv "$d/m.tmp" "$d/RELEASE-MANIFEST.json"
out="$(run_verify "$d")"
rc=$?
if [[ $rc -ne 0 ]]; then
  assert_contains "$out" "assets が array でない" "検証出力"
else
  fail "assets の型が不正でも成功してしまった"
fi

# ── 5. 検査範囲の明示（何件中何件を見たか）──────────────────────────────────
# 打ち切った件数を黙って隠すと、出力が「全部見た」と読める。

# gh のスタブ。監査が使ってよいのは release list / release download だけで、
# それ以外が呼ばれたら記録する（呼ばれること自体が公開状態への副作用の兆候）。
STUB_DIR="$(new_workdir)/bin"
FIXTURE="$(new_workdir)/fixture"
mkdir -p "$STUB_DIR" "$FIXTURE/releases"

# 13 件公開されている状況を作る。実際の公開リポジトリと同じ件数。
: > "$FIXTURE/tags.txt"
i=13
while [[ $i -ge 1 ]]; do
  echo "v0.0.$i" >> "$FIXTURE/tags.txt"
  i=$((i - 1))
done

cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
FIXTURE="$FIXTURE"
if [[ "\${1:-}" == "release" && "\${2:-}" == "list" ]]; then
  cat "\$FIXTURE/tags.txt"
  exit 0
fi
if [[ "\${1:-}" == "release" && "\${2:-}" == "download" ]]; then
  tag="\${3:-}"
  dir=""
  while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--dir" ]]; then dir="\$2"; fi
    shift
  done
  src="\$FIXTURE/releases/\$tag"
  [[ -d "\$src" ]] || src="\$FIXTURE/releases/default"
  mkdir -p "\$dir"
  cp "\$src"/* "\$dir"/
  exit 0
fi
echo "STUB: unexpected gh call: \$*" >&2
exit 1
STUB
chmod +x "$STUB_DIR/gh"

cp -R "$BASE" "$FIXTURE/releases/default"

run_audit() {
  (
    # shellcheck disable=SC1090
    . "$FNS"
    PATH="$STUB_DIR:$PATH" audit_release_assets "test-owner" 2>&1
  )
}

it "既定件数で監査すると、検査件数と範囲外の件数が出力に現れる"
out="$(run_audit)"
rc=$?
if [[ $rc -ne 0 ]]; then
  fail "正常な資産で監査が失敗した:
$(printf '%s' "$out" | grep -v '^\[audit\] OK' | head -10)"
else
  assert_contains "$out" "公開 13 件中 10 件を検査（範囲外・未検査: 3 件）" "監査出力"
fi

it "総括行にも検査件数と範囲外の件数が現れる"
assert_contains "$out" "検査 10 件 / 範囲外・未検査 3 件" "監査出力"

it "監査は公開状態を変更しない（読み取り以外の gh を呼ばない）"
if printf '%s' "$out" | grep -q 'unexpected gh call'; then
  fail "読み取り以外の gh 呼び出しがあった:
$(printf '%s' "$out" | grep 'unexpected' | head -3)"
else
  pass
fi

it "検査件数は AUDIT_RELEASE_LIMIT で変更できる"
out="$(AUDIT_RELEASE_LIMIT=2 run_audit)"
rc=$?
if [[ $rc -eq 0 ]]; then
  assert_contains "$out" "公開 13 件中 2 件を検査（範囲外・未検査: 11 件）" "監査出力"
else
  fail "件数を変えた監査が失敗した:
$(printf '%s' "$out" | grep -v '^\[audit\] OK' | head -10)"
fi

it "AUDIT_RELEASE_LIMIT が不正なら実行しない"
out="$(AUDIT_RELEASE_LIMIT=abc run_audit)"
rc=$?
if [[ $rc -ne 0 ]]; then
  assert_contains "$out" "AUDIT_RELEASE_LIMIT" "監査出力"
else
  fail "不正な件数指定でも実行してしまった"
fi

it "範囲内の 1 件でも改変されていれば監査が非ゼロで終了する"
mkdir -p "$FIXTURE/releases/v0.0.13"
cp "$BASE"/* "$FIXTURE/releases/v0.0.13"/
printf ' ' >> "$FIXTURE/releases/v0.0.13/bootstrap.sh"
out="$(run_audit)"
rc=$?
if [[ $rc -ne 0 ]]; then
  assert_contains "$out" "bootstrap.sh — SHA256SUMS の記載と実ファイルが不一致" "監査出力"
else
  fail "改変された資産を含むのに監査が成功した"
fi
rm -rf "$FIXTURE/releases/v0.0.13"

it "通常の件数では取得上限の警告を出さない"
if printf '%s' "$out" | grep -q '取得上限'; then
  fail "上限に達していないのに警告が出た"
else
  pass
fi

# ── 5b. リリース名（外部入力）を作業ディレクトリのパスへ使わない ─────────────
# タグ名は公開リポジトリ側が決める値で、監査プロセスにとっては外部入力。これを
# パスへ埋め込むと `../` を含むタグで mkdir -p / rm -rf が想定外の場所へ作用する。
# ここでは作業領域の外に「消えては困るファイル」を置き、それが残ることを固定する。

it "タグ名に ../ を含んでも作業領域の外を壊さない"
TRAVERSAL_ROOT="$(new_workdir)/traversal"
mkdir -p "$TRAVERSAL_ROOT/tmp" "$TRAVERSAL_ROOT/victim"
printf 'keep me\n' > "$TRAVERSAL_ROOT/victim/keep.txt"
# 作業ディレクトリ（mktemp -d）から 3 つ上がると $TRAVERSAL_ROOT に届く配置にする。
# タグをパスへ連結する実装なら victim を作り直したうえで rm -rf する。
: > "$FIXTURE/tags.txt"
echo '/../../../victim' >> "$FIXTURE/tags.txt"
out="$(TMPDIR="$TRAVERSAL_ROOT/tmp" run_audit)"
rc=$?
if [[ -f "$TRAVERSAL_ROOT/victim/keep.txt" ]]; then
  pass
else
  fail "タグ名の ../ で作業領域の外のファイルが消えた（rc=$rc）:
$(printf '%s' "$out" | grep -v '^\[audit\] OK' | head -10)"
fi

# ── 5c. リリース一覧が取得上限で切れたことを隠さない ─────────────────────────
# 総数は取得した一覧を数えて出しているため、一覧が上限で切れると「公開 N 件中」の
# N が実際より小さくなる。切り捨てた範囲は必ず出力へ明示する（#193）。

LIST_LIMIT="$(
  # shellcheck disable=SC1090
  . "$FNS"
  printf '%s' "$AUDIT_RELEASE_LIST_LIMIT"
)"

it "リリース一覧が取得上限に達したら件数が不完全であることを警告する"
: > "$FIXTURE/tags.txt"
i=1
while [[ $i -le $LIST_LIMIT ]]; do
  echo "v9.9.$i" >> "$FIXTURE/tags.txt"
  i=$((i + 1))
done
out="$(AUDIT_RELEASE_LIMIT=1 run_audit)"
rc=$?
if [[ $rc -eq 0 ]]; then
  assert_contains "$out" "リリース一覧が取得上限 $LIST_LIMIT 件に達した" "監査出力"
else
  fail "上限ちょうどの一覧で監査が失敗した:
$(printf '%s' "$out" | grep -v '^\[audit\] OK' | head -10)"
fi

# ── 6. 連続失敗時だけ起票する ────────────────────────────────────────────────
# 1 回目の失敗で起票しないのは、一過性の失敗で issue が溜まると本当の不整合が
# 埋もれるため。判定は GitHub API を叩かずに検査できる形にしてある。

it "通知スクリプトが存在する"
assert_file_exists "$NOTIFY_SH"

# --dry-run で GitHub へ触れていないことを確かめるため、呼ばれたら記録する gh を置く。
NOTIFY_STUB="$(new_workdir)/notify-bin"
mkdir -p "$NOTIFY_STUB"
GH_CALLED="$(new_workdir)/gh-called"
cat > "$NOTIFY_STUB/gh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$GH_CALLED"
exit 0
STUB
chmod +x "$NOTIFY_STUB/gh"

run_notify() {
  PATH="$NOTIFY_STUB:$PATH" bash "$NOTIFY_SH" --repo owner/repo --dry-run "$@" 2>&1
}

it "1 回目の失敗では起票しない"
out="$(run_notify --result failure --previous success --existing-issue none)"
assert_contains "$out" "decision=none" "判定出力"

it "直前の実行結果が取得できない場合も起票しない"
out="$(run_notify --result failure --previous none --existing-issue none)"
assert_contains "$out" "decision=none" "判定出力"

it "2 回連続の失敗で起票する"
out="$(run_notify --result failure --previous failure --existing-issue none)"
assert_contains "$out" "decision=create" "判定出力"

it "同じ失敗の open issue があればコメント追記に留める"
out="$(run_notify --result failure --previous failure --existing-issue 42)"
assert_contains "$out" "decision=comment" "判定出力"

it "監査が成功していれば何もしない"
out="$(run_notify --result success --previous failure --existing-issue none)"
assert_contains "$out" "decision=none" "判定出力"

it "判定に GitHub API を使わない"
if [[ -s "$GH_CALLED" ]]; then
  fail "--dry-run で gh が呼ばれた: $(head -3 "$GH_CALLED" | tr '\n' ' ')"
else
  pass
fi

it "不正な --result は実行前に止まる"
out="$(run_notify --result maybe --previous failure --existing-issue none)"
rc=$?
if [[ $rc -ne 0 ]]; then
  assert_contains "$out" "--result" "エラー出力"
else
  fail "不正な値でも通ってしまった"
fi

# 本文の一時ファイルは gh の失敗経路でも残してはならない。set -e で途中終了すると
# 末尾の rm まで届かないため、mktemp 直後の trap で片付いていることを固定する。
it "起票に失敗しても一時ファイルを残さない"
FAIL_STUB="$(new_workdir)/notify-fail-bin"
mkdir -p "$FAIL_STUB"
cat > "$FAIL_STUB/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "issue" && "${2:-}" == "create" ]]; then
  echo "STUB: gh issue create failed" >&2
  exit 1
fi
exit 0
STUB
chmod +x "$FAIL_STUB/gh"
NOTIFY_TMP="$(new_workdir)/notify-tmp"
mkdir -p "$NOTIFY_TMP"
out="$(PATH="$FAIL_STUB:$PATH" TMPDIR="$NOTIFY_TMP" \
  bash "$NOTIFY_SH" --repo owner/repo --result failure --previous failure --existing-issue none 2>&1)"
rc=$?
leftover="$(find "$NOTIFY_TMP" -mindepth 1 | head -5)"
if [[ $rc -eq 0 ]]; then
  fail "起票が失敗したのにスクリプトが成功した"
elif [[ -n "$leftover" ]]; then
  fail "起票の失敗で一時ファイルが残った: $(printf '%s' "$leftover" | tr '\n' ' ')"
else
  pass
fi

# ── 7. 定期実行の配線 ────────────────────────────────────────────────────────
# 公開後の差し替えは、リリース直後の 1 回だけでは検出できない。定期実行が無いと
# ハッシュ照合へ変えた意味が出ない。

WORKFLOW="$REPO_ROOT/.github/workflows/release-audit.yml"

it "定期実行のワークフローが存在する"
assert_file_exists "$WORKFLOW"

it "schedule と workflow_dispatch の両方で起動できる"
if grep -q '^  schedule:' "$WORKFLOW" && grep -q '^  workflow_dispatch:' "$WORKFLOW"; then
  pass
else
  fail "schedule / workflow_dispatch のいずれかが無い"
fi

it "ワークフローが監査スクリプトを呼ぶ"
assert_contains "$(cat "$WORKFLOW")" "release-packages.sh --owner" "ワークフロー"

it "ワークフローが失敗時に通知スクリプトを呼ぶ"
if grep -q 'if: failure()' "$WORKFLOW" && grep -q 'audit-failure-notify.sh' "$WORKFLOW"; then
  pass
else
  fail "失敗時の通知が配線されていない"
fi

exit_with_result
