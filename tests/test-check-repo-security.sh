#!/usr/bin/env bash
# scripts/check-repo-security.sh の読み分けを、偽物の gh で確かめる（#394）。
#
# 本物の GitHub は、権限のあるトークンでは「有効」か「無効」しか返さない。**読めなかった
# ときの形（403・応答なし・壊れた本文）は、本物へ何度回しても現れない。** そこで PATH の
# 先頭に偽物の gh を置き、応答を表で与える。偽物は本物がしないことをしない:
# `gh api -i` は状態行・ヘッダ・空行・本文を出し、2xx 以外では非 0 で終わる。
#
# bash 3.2 互換を維持する（連想配列・mapfile を使わない）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-check-repo-security"

TARGET="$REPO_ROOT/scripts/check-repo-security.sh"

it "照合スクリプトが存在する"
if [[ -f "$TARGET" ]]; then
  pass
else
  fail "見つからない: $TARGET"
fi

if ! command -v jq >/dev/null 2>&1; then
  it "jq がある（検査対象の依存）"
  fail "jq が見つからない"
  exit 1
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/test-check-repo-security.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# 偽物の gh。応答は $FAKE_GH_DIR/<パスの / を _ にした名前> に「状態コード」「本文」の 2 行で置く。
# ファイルが無いパスは、応答なし（到達できない）として何も出さずに失敗する。
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  echo "fake-owner/fake-repo"
  exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == "-i" && -n "${3:-}" ]]; then
  file="$FAKE_GH_DIR/$(printf '%s' "$3" | tr '/' '_')"
  [[ -f "$file" ]] || exit 1
  status="$(sed -n 1p "$file")"
  body="$(sed -n 2p "$file")"
  printf 'HTTP/2.0 %s X\r\nContent-Type: application/json\r\n\r\n' "$status"
  [[ -n "$body" ]] && printf '%s' "$body"
  case "$status" in 2*) exit 0 ;; *) echo "gh: (HTTP $status)" >&2; exit 1 ;; esac
fi
echo "fake gh: unsupported: $*" >&2
exit 2
EOF
chmod +x "$tmp/bin/gh"

REPO="fake-owner/fake-repo"
ADMIN='{"permissions":{"admin":true}}'

# respond <パス> <状態コード> [本文]
respond() {
  printf '%s\n%s\n' "$2" "${3:-}" >"$FAKE_GH_DIR/$(printf '%s' "$1" | tr '/' '_')"
}

# 3 つとも有効な応答から始め、各ケースで 1 か所だけ崩す。
setup_all_enabled() {
  FAKE_GH_DIR="$tmp/case-$TESTS_RUN"
  rm -rf "$FAKE_GH_DIR"
  mkdir -p "$FAKE_GH_DIR"
  respond "repos/$REPO" 200 "$ADMIN"
  respond "repos/$REPO/private-vulnerability-reporting" 200 '{"enabled":true}'
  respond "repos/$REPO/vulnerability-alerts" 204
  respond "repos/$REPO/automated-security-fixes" 200 '{"enabled":true,"paused":false}'
}

# expect <期待する終了コード> <出力に含むべき語> <出力に含んではいけない語（空なら見ない）> [引数...]
expect() {
  local want_rc="$1" needle="$2" forbidden="$3" out got_rc=0
  shift 3
  out="$(PATH="$tmp/bin:$PATH" FAKE_GH_DIR="$FAKE_GH_DIR" bash "$TARGET" "$@" 2>&1)" || got_rc=$?
  if [[ "$got_rc" != "$want_rc" ]]; then
    fail "終了コード $got_rc（期待 $want_rc）: $out"
  elif ! grep -qF -- "$needle" <<<"$out"; then
    fail "出力に「$needle」が無い: $out"
  elif [[ -n "$forbidden" ]] && grep -qF -- "$forbidden" <<<"$out"; then
    fail "出力に「$forbidden」が出ている: $out"
  else
    pass
  fi
}

it "3 つとも有効なら 0"
setup_all_enabled
expect 0 "3 つとも有効です" "FAIL"

it "引数を省くと gh repo view のリポジトリを照合する"
setup_all_enabled
expect 0 "${REPO}: 3 つとも有効です" ""

it "引数で渡したリポジトリを照合する"
setup_all_enabled
expect 0 "${REPO}: 3 つとも有効です" "" "$REPO"

# ── 乖離（無効）: 1 ─────────────────────────────────────────────────────────

it "非公開の報告窓口が無効なら 1"
setup_all_enabled
respond "repos/$REPO/private-vulnerability-reporting" 200 '{"enabled":false}'
expect 1 "FAIL  Private vulnerability reporting が無効です" "前提の不成立"

it "Dependabot alerts が無効（404）なら 1"
setup_all_enabled
respond "repos/$REPO/vulnerability-alerts" 404 '{"message":"Vulnerability alerts are disabled."}'
expect 1 "FAIL  Dependabot alerts が無効です" "前提の不成立"

it "Dependabot security updates が無効なら 1"
setup_all_enabled
respond "repos/$REPO/automated-security-fixes" 200 '{"enabled":false,"paused":false}'
expect 1 "FAIL  Dependabot security updates が無効です" "前提の不成立"

# ── 前提の不成立（読めない）: 2。「無効」とは読まない ──────────────────────────

it "Dependabot alerts が 403 なら、無効ではなく前提の不成立として 2"
setup_all_enabled
respond "repos/$REPO/vulnerability-alerts" 403 '{"message":"Resource not accessible by personal access token"}'
expect 2 "前提の不成立: Dependabot alerts を読めません（HTTP 403）" "FAIL  Dependabot alerts"

it "Dependabot security updates が 403 なら前提の不成立として 2"
setup_all_enabled
respond "repos/$REPO/automated-security-fixes" 403 '{"message":"Resource not accessible by personal access token"}'
expect 2 "前提の不成立: Dependabot security updates を読めません（HTTP 403）" "FAIL"

it "応答が無ければ前提の不成立として 2"
setup_all_enabled
rm -f "$FAKE_GH_DIR/repos_${REPO//\//_}_private-vulnerability-reporting"
expect 2 "前提の不成立: Private vulnerability reporting を読めません（応答がありません）" "FAIL"

it "enabled が真偽値でなければ有効と読まず 2"
setup_all_enabled
respond "repos/$REPO/private-vulnerability-reporting" 200 '{"enabled":"true"}'
expect 2 "enabled が真偽値ではありません" "OK    Private"

it "本文が JSON でなければ有効と読まず 2"
setup_all_enabled
respond "repos/$REPO/automated-security-fixes" 200 'not json'
expect 2 "enabled が真偽値ではありません" "OK    Dependabot security"

# リポジトリに届かない 404 を「alerts が無効」の 404 と取り違えない。
it "リポジトリに届かなければ、項目を見ずに前提の不成立として 2"
setup_all_enabled
respond "repos/$REPO" 404 '{"message":"Not Found"}'
respond "repos/$REPO/vulnerability-alerts" 404 '{"message":"Not Found"}'
expect 2 "前提の不成立: リポジトリ ${REPO} を読めません（HTTP 404）" "FAIL"

it "管理者権限が無ければ前提の不成立として 2"
setup_all_enabled
respond "repos/$REPO" 200 '{"permissions":{"admin":false}}'
expect 2 "管理者権限がありません" "FAIL"

it "無効と読めないが混ざれば 2（読めない項目は確かめられていない）"
setup_all_enabled
respond "repos/$REPO/private-vulnerability-reporting" 200 '{"enabled":false}'
respond "repos/$REPO/vulnerability-alerts" 403 '{"message":"Forbidden"}'
expect 2 "FAIL  Private vulnerability reporting が無効です" ""

exit_with_result
