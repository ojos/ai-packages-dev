#!/usr/bin/env bash
# scripts/update-release-status.sh が、「Release / タグが無い（未公開）」と「読めなかった」を
# 区別することを、偽物の gh で確かめる（#500）。
#
# 読めなかったとき（認証・権限・通信の失敗、リポジトリが無い）は、README を書き換えずに
# 非 0 で終わる。以前はどちらも <none> に倒し、公開済みでも「未公開」と書いて正常終了していた。
#
# 偽物の gh は、`gh api -i <path>` に状態行と本文を、`gh api --paginate .../tags --jq ...` に
# タグ名を返す。応答は環境変数で決める（リポジトリごとの HTTP の状態）。本物の gh と同じく、
# 2xx 以外では非 0 で終わる。ネットワークには出ない。依存: bash / awk / sed / jq / diff。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-update-release-status"

SCRIPT="$REPO_ROOT/scripts/update-release-status.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-release-status.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

cat > "$WORK/bin/gh" <<'FAKE'
#!/usr/bin/env bash
# 偽物の gh。FAKE_<名前>_RELEASE / FAKE_<名前>_REPO に HTTP の状態、FAKE_<名前>_TAG に Release のタグ、
# FAKE_PLAYBOOK_TAGS にタグの一覧（改行区切り）、FAKE_PLAYBOOK_TAGS_RC に tags の終了コードを入れる。
key_of() { case "$1" in devcontainer-bootstrap) echo DCB ;; devcontainer-host) echo HOST ;; ai-playbook) echo PLAYBOOK ;; *) echo OTHER ;; esac; }
path=""; inc=0; jq=0
for a in "$@"; do
  case "$a" in
    -i) inc=1 ;;
    --jq) jq=1 ;;
    repos/*) path="$a" ;;
  esac
done
repo="$(printf '%s' "$path" | cut -d/ -f3)"
k="$(key_of "$repo")"
case "$path" in
  */releases/latest)
    st_var="FAKE_${k}_RELEASE"; st="${!st_var:-404}"
    tag_var="FAKE_${k}_TAG"; tag="${!tag_var:-}"
    body='{"message":"x"}'; [[ "$st" == 200 ]] && body="{\"tag_name\":\"$tag\"}"
    # --jq '.tag_name' の呼び出しには、タグ名だけを返す（本物の gh と同じく、2xx 以外は非 0）
    if [[ "$jq" == 1 ]]; then [[ "$st" == 200 ]] && { printf '%s\n' "$tag"; exit 0; }; exit 1; fi
    ;;
  */tags)
    rc="${FAKE_PLAYBOOK_TAGS_RC:-0}"
    [[ "$rc" == 0 ]] || { echo "gh: error" >&2; exit "$rc"; }
    printf '%s\n' "${FAKE_PLAYBOOK_TAGS:-}"
    exit 0
    ;;
  *)
    st_var="FAKE_${k}_REPO"; st="${!st_var:-200}"
    body='{"name":"x"}'
    ;;
esac
# 本物の gh -i と同じく、状態行・見出しと区切りの空行は CRLF で出す
[[ "$inc" == 1 ]] && printf 'HTTP/2.0 %s X\r\nContent-Type: application/json\r\n\r\n' "$st"
printf '%s\n' "$body"
[[ "$st" == 2* ]] || exit 1
FAKE
chmod +x "$WORK/bin/gh"

README_SRC="$WORK/README.src.md"
cat > "$README_SRC" <<'EOF2'
# t
<!-- RELEASE_STATUS:START -->
古い内容
<!-- RELEASE_STATUS:END -->
EOF2

run() {
  cp "$README_SRC" "$WORK/README.md"
  env PATH="$WORK/bin:$PATH" "$@" bash "$SCRIPT" --readme "$WORK/README.md" >"$WORK/out" 2>&1
  echo $?
}
ok_env=(FAKE_DCB_RELEASE=200 FAKE_DCB_TAG=v0.18.0 FAKE_HOST_RELEASE=200 FAKE_HOST_TAG=v0.1.0 "FAKE_PLAYBOOK_TAGS=v0.8.1
v0.8.2
v0.10.0-rc1")

it "公開済みなら版を書き、0 で終わる"
assert_eq "$(run "${ok_env[@]}")" "0" "終了コード"

it "README に 3 つの版が書かれる（semver のタグの最大を採る）"
if grep -F 'ojos/devcontainer-bootstrap で v0.18.0 まで公開済み' "$WORK/README.md" >/dev/null \
  && grep -F 'ojos/devcontainer-host で v0.1.0 まで公開済み' "$WORK/README.md" >/dev/null \
  && grep -F 'ojos/ai-playbook で v0.8.2 まで公開済み' "$WORK/README.md" >/dev/null; then
  pass
else
  fail "README: $(cat "$WORK/README.md")"
fi

it "devcontainer-host の Release が 404（リポジトリはある）なら「未公開」と書き、0 で終わる"
assert_eq "$(run "${ok_env[@]}" FAKE_HOST_RELEASE=404 FAKE_HOST_REPO=200)" "0" "終了コード"
it "「未公開（Release なし）」と書かれる"
if grep -F 'ojos/devcontainer-host は未公開（Release なし）' "$WORK/README.md" >/dev/null; then pass; else fail "README: $(cat "$WORK/README.md")"; fi

for st in 401 403 500 502; do
  it "Release の取得が HTTP $st なら非 0 で終わり、README を書き換えない"
  rc="$(run "${ok_env[@]}" FAKE_HOST_RELEASE=$st)"
  if [[ "$rc" != 0 ]] && diff -q "$README_SRC" "$WORK/README.md" >/dev/null; then pass; else fail "rc=$rc / 出力: $(cat "$WORK/out")"; fi
done

it "Release が 404 で、リポジトリも 404（名前の誤り・改名）なら非 0 で終わり、README を書き換えない"
rc="$(run "${ok_env[@]}" FAKE_DCB_RELEASE=404 FAKE_DCB_REPO=404)"
if [[ "$rc" != 0 ]] && diff -q "$README_SRC" "$WORK/README.md" >/dev/null; then pass; else fail "rc=$rc / 出力: $(cat "$WORK/out")"; fi

it "失敗したときは、どのリポジトリを読めなかったかを出す"
if grep -F 'ojos/devcontainer-bootstrap' "$WORK/out" >/dev/null && grep -F 'README は書き換えていません' "$WORK/out" >/dev/null; then pass; else fail "出力: $(cat "$WORK/out")"; fi

it "応答が無い（状態行が取れない）なら非 0 で終わる"
mkdir -p "$WORK/bin2"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/bin2/gh"
chmod +x "$WORK/bin2/gh"
cp "$README_SRC" "$WORK/README.md"
rc="$(env PATH="$WORK/bin2:$PATH" bash "$SCRIPT" --readme "$WORK/README.md" >/dev/null 2>&1; echo $?)"
if [[ "$rc" != 0 ]] && diff -q "$README_SRC" "$WORK/README.md" >/dev/null; then pass; else fail "rc=$rc"; fi

it "ai-playbook のタグの一覧が読めなければ非 0 で終わり、README を書き換えない"
rc="$(run "${ok_env[@]}" FAKE_PLAYBOOK_TAGS_RC=1)"
if [[ "$rc" != 0 ]] && diff -q "$README_SRC" "$WORK/README.md" >/dev/null; then pass; else fail "rc=$rc / 出力: $(cat "$WORK/out")"; fi

it "ai-playbook のタグが読めて semver が 1 つも無ければ 0 で終わる（読めなかったとは区別する）"
assert_eq "$(run "${ok_env[@]}" "FAKE_PLAYBOOK_TAGS=latest")" "0" "終了コード"
it "そのとき ai-playbook は「未公開（タグなし）」と書かれる（<none> まで公開済み、とは書かない）"
if grep -F 'ojos/ai-playbook は未公開（タグなし）' "$WORK/README.md" >/dev/null && ! grep -F '<none>' "$WORK/README.md" >/dev/null; then pass; else fail "README: $(cat "$WORK/README.md")"; fi

it "devcontainer-bootstrap の Release が 404（リポジトリはある）なら「未公開（Release なし）」と書く"
assert_eq "$(run "${ok_env[@]}" FAKE_DCB_RELEASE=404 FAKE_DCB_REPO=200)" "0" "終了コード"
if grep -F 'ojos/devcontainer-bootstrap は未公開（Release なし）' "$WORK/README.md" >/dev/null && ! grep -F '<none>' "$WORK/README.md" >/dev/null; then pass; else fail "README: $(cat "$WORK/README.md")"; fi

exit_with_result
