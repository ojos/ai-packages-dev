#!/usr/bin/env bash
# 依存の同期検査（scripts/check-deps-installed.sh）を検証する。
#
# この検査は「CI では緑のまま、手元でだけ出る」ずれを見る。CI は毎回 `npm ci` する
# ので、実行して再現する検査を書いても緑になる。**判定そのものをフィクスチャで
# 固定する以外に確かめる方法が無い。**
#
# **このリポジトリはこの検査の写しを持たない**（package.json が無いため。
# tests/test-template-mirror.sh の EXCLUDED_NO_COPY_RELS）。したがって、
# **壊れたときに気づける経路はこのテストだけである。** 陽性と陰性を対で置く。
#
# ネットワークには出ない。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-check-deps-installed"

REL="scripts/check-deps-installed.sh"

BASE="$(new_workdir)/base"
run_bootstrap "$BASE" >/dev/null 2>&1

# ── 生成と配線 ───────────────────────────────────────────────────────────────

it "node を選んだ構成で生成され、実行可能である"
if [[ -f "$BASE/$REL" ]]; then
  assert_mode "$BASE/$REL" "755"
else
  fail "生成されていない: $BASE/$REL"
fi

it "node を選ばない構成では生成されない"
# 常に「対象が無い」で飛ばすだけのスクリプトを配らない。
NONODE="$(new_workdir)/nonode"
bash "$BOOTSTRAP" --project-name test --languages go --output-dir "$NONODE" >/dev/null 2>&1
assert_file_absent "$NONODE/$REL"

it "生成された acceptance.sh が、テストの手前でこの検査を呼ぶ"
# ずれたまま走らせると、テストが Cannot find package で全滅し、自分の変更と
# 無関係な赤で原因が読めなくなる。順序に意味がある。
acc="$BASE/scripts/acceptance.sh"
deps_line="$(grep -n 'check-deps-installed.sh' "$acc" | sed -n 1p | cut -d: -f1)"
test_line="$(grep -n 'npm test' "$acc" | sed -n 1p | cut -d: -f1)"
if [[ -z "$deps_line" ]]; then
  fail "acceptance.sh がこの検査を呼んでいない"
elif [[ -z "$test_line" ]]; then
  fail "acceptance.sh に npm test が無い（前提が変わった）"
elif [[ "$deps_line" -ge "$test_line" ]]; then
  fail "この検査がテストより後ろにある（deps=$deps_line test=$test_line）"
else
  pass
fi

it "acceptance.sh の呼び出しが、package.json がある節の中に置かれている"
# 節の外へ出すと、マニフェストの無い構成でも呼ばれる。
if awk -v n="$deps_line" '
  NR < n && /^if \[\[ -f package\.json \]\]; then/ { inside = 1 }
  NR < n && /^fi$/ { inside = 0 }
  NR == n { exit inside ? 0 : 1 }
' "$acc"; then
  pass
else
  fail "package.json の節の外で呼ばれている"
fi

# ── フィクスチャ ─────────────────────────────────────────────────────────────
#
# 宣言（package-lock.json）と導入記録（node_modules/.package-lock.json）を組み立てる。
# 記録にある分だけ実体のディレクトリも置く。

# new_project <名前>: 検査だけを置いた作業ディレクトリを作り、そのパスを返す。
new_project() {
  local dir
  dir="$(new_workdir)/p"
  mkdir -p "$dir/scripts"
  cp "$BASE/$REL" "$dir/$REL"
  printf '{ "name": "t", "version": "1.0.0" }\n' > "$dir/package.json"
  printf '%s' "$dir"
}

# write_lock <dir> <ファイル名> <packages の中身>
write_lock() {
  printf '{ "lockfileVersion": 3, "packages": { %s } }\n' "$3" > "$1/$2"
}

# 実体のディレクトリを置く。
place() {
  local dir="$1"; shift
  local p
  for p in "$@"; do mkdir -p "$dir/$p"; done
}

ROOT_ENTRY='"": { "name": "t", "version": "1.0.0" }'

CHECK_OUT=""
CHECK_RC=0
run_check() {
  CHECK_OUT="$(cd "$1" && bash "$REL" 2>&1)"
  CHECK_RC=$?
}

assert_signal() {
  local what="$1" want="$2" rc_want="$3"
  if [[ "$CHECK_RC" -ne "$rc_want" ]]; then
    fail "$what: 終了コードが $rc_want でなく $CHECK_RC: $CHECK_OUT"
  elif ! printf '%s' "$CHECK_OUT" | grep -F "$want" >/dev/null; then
    fail "$what: $want が出ていない: $CHECK_OUT"
  else
    pass
  fi
}

assert_fail_says() {
  local what="$1" needle="$2"
  if [[ "$CHECK_RC" -eq 0 ]]; then
    fail "$what: 落ちるべきところで通過した: $CHECK_OUT"
  elif ! printf '%s' "$CHECK_OUT" | grep -F 'DEPS_FAIL' >/dev/null; then
    fail "$what: DEPS_FAIL が出ていない: $CHECK_OUT"
  elif ! printf '%s' "$CHECK_OUT" | grep -F "$needle" >/dev/null; then
    fail "$what: 期待した報告 '$needle' が無い: $CHECK_OUT"
  else
    pass
  fi
}

# ── 陰性の基準線 ─────────────────────────────────────────────────────────────

it "宣言と実体が一致していれば DEPS_PASS（陰性の基準線）"
# これが通らないと、以降の陽性はすべて「常に落ちる検査」でも成立してしまう。
d="$(new_project)"
write_lock "$d" package-lock.json "$ROOT_ENTRY, \"node_modules/a\": { \"version\": \"1.0.0\" }"
write_lock "$d" node_modules/.package-lock.json "\"node_modules/a\": { \"version\": \"1.0.0\" }" 2>/dev/null || true
mkdir -p "$d/node_modules"
write_lock "$d" node_modules/.package-lock.json "\"node_modules/a\": { \"version\": \"1.0.0\" }"
place "$d" node_modules/a
run_check "$d"
assert_signal "一致" "DEPS_PASS" 0

# ── 陽性: 4 方向 ─────────────────────────────────────────────────────────────

it "宣言にあって記録に無い（npm ci していない）を検出する"
d="$(new_project)"; mkdir -p "$d/node_modules"
write_lock "$d" package-lock.json "$ROOT_ENTRY, \"node_modules/a\": { \"version\": \"1.0.0\" }, \"node_modules/b\": { \"version\": \"2.0.0\" }"
write_lock "$d" node_modules/.package-lock.json "\"node_modules/a\": { \"version\": \"1.0.0\" }"
place "$d" node_modules/a
run_check "$d"
assert_fail_says "未導入" "未導入: node_modules/b@2.0.0"

it "版が食い違う場合を検出する"
d="$(new_project)"; mkdir -p "$d/node_modules"
write_lock "$d" package-lock.json "$ROOT_ENTRY, \"node_modules/a\": { \"version\": \"1.0.0\" }"
write_lock "$d" node_modules/.package-lock.json "\"node_modules/a\": { \"version\": \"0.9.0\" }"
place "$d" node_modules/a
run_check "$d"
assert_fail_says "版ちがい" "版ちがい: node_modules/a 宣言=1.0.0 導入=0.9.0"

it "記録にあって宣言に無い（依存を削ったあと npm ci していない）を検出する"
d="$(new_project)"; mkdir -p "$d/node_modules"
write_lock "$d" package-lock.json "$ROOT_ENTRY"
write_lock "$d" node_modules/.package-lock.json "\"node_modules/a\": { \"version\": \"1.0.0\" }"
place "$d" node_modules/a
run_check "$d"
assert_fail_says "宣言に無い" "宣言に無い: node_modules/a@1.0.0"

it "記録にあるが実体のディレクトリが無い場合を検出する"
# 記録だけを信じると、ディレクトリを消した（退避した）状態を「一致」と報告する。
d="$(new_project)"; mkdir -p "$d/node_modules"
write_lock "$d" package-lock.json "$ROOT_ENTRY, \"node_modules/a\": { \"version\": \"1.0.0\" }"
write_lock "$d" node_modules/.package-lock.json "\"node_modules/a\": { \"version\": \"1.0.0\" }"
run_check "$d"
assert_fail_says "実体が無い" "実体が無い: node_modules/a@1.0.0"

# ── 陰性の対照群 ─────────────────────────────────────────────────────────────

it "optional な依存は、宣言にあって実体が無くても報告しない（対照群）"
# 他のプラットフォーム向けの依存は、入らないのが正常である。
d="$(new_project)"; mkdir -p "$d/node_modules"
write_lock "$d" package-lock.json "$ROOT_ENTRY, \"node_modules/opt\": { \"version\": \"1.0.0\", \"optional\": true }"
write_lock "$d" node_modules/.package-lock.json ""
run_check "$d"
assert_signal "optional" "DEPS_PASS" 0

it "link（workspace 参照）は報告しない（対照群）"
# 実体の版を持たないため、照合の対象にならない。
d="$(new_project)"; mkdir -p "$d/node_modules"
write_lock "$d" package-lock.json "$ROOT_ENTRY, \"node_modules/w\": { \"link\": true, \"resolved\": \"packages/w\" }"
write_lock "$d" node_modules/.package-lock.json ""
run_check "$d"
assert_signal "link" "DEPS_PASS" 0

# ── 対象が無い場合（スキップ）─────────────────────────────────────────────────

it "package.json が無ければ 0 で終わる"
d="$(new_workdir)/nomanifest"
mkdir -p "$d/scripts"; cp "$BASE/$REL" "$d/$REL"
run_check "$d"
assert_signal "対象なし" "DEPS_SKIP" 0

it "スキップの信号が、通過の信号と別である"
# **同じにすると「検査していない」と「一致を確認した」が読み分けられなくなる。**
# このリポジトリはこの検査の写しを持たず、配布先でも Node を使わない構成があるため、
# ここが曖昧だと「動いていない」ことに誰も気づけない。
if printf '%s' "$CHECK_OUT" | grep -F 'DEPS_PASS' >/dev/null; then
  fail "スキップ時に DEPS_PASS も出ている: $CHECK_OUT"
else
  pass
fi

# ── 検査が成立しないことを合格にしない ──────────────────────────────────────

it "package.json はあるが package-lock.json が無ければ落ちる"
d="$(new_project)"
run_check "$d"
assert_fail_says "宣言なし" "package-lock.json がありません"

it "package.json はあるが node_modules が無ければ落ちる"
d="$(new_project)"
write_lock "$d" package-lock.json "$ROOT_ENTRY"
run_check "$d"
assert_fail_says "実体なし" "node_modules がありません"

it "node_modules はあるが導入記録が無ければ落ちる"
d="$(new_project)"; mkdir -p "$d/node_modules"
write_lock "$d" package-lock.json "$ROOT_ENTRY"
run_check "$d"
assert_fail_says "記録なし" "npm が導入時に書く記録"

it "package-lock.json が壊れた JSON なら落ち、原因が読める"
d="$(new_project)"; mkdir -p "$d/node_modules"
printf '{ broken\n' > "$d/package-lock.json"
write_lock "$d" node_modules/.package-lock.json ""
run_check "$d"
assert_fail_says "壊れた JSON" "読めませんでした"

it "壊れた JSON のとき、node のスタックを件数として表示しない"
# 標準エラーを混ぜると、スタックの 1 行目が「差分 N 件」の N として出る。
if printf '%s' "$CHECK_OUT" | grep -E '差分 [^0-9]' >/dev/null; then
  fail "件数でないものを件数として表示している: $CHECK_OUT"
else
  pass
fi

it "node が無ければ落ち、導入手順を示す"
d="$(new_project)"; mkdir -p "$d/node_modules"
write_lock "$d" package-lock.json "$ROOT_ENTRY"
write_lock "$d" node_modules/.package-lock.json ""
NONODE_BIN="$(new_workdir)/nonode-bin"
mkdir -p "$NONODE_BIN"
for c in bash sh sed grep cat printf mkdir dirname cd pwd; do
  src="$(command -v "$c" 2>/dev/null || true)"
  [[ -n "$src" ]] && ln -sf "$src" "$NONODE_BIN/$c"
done
CHECK_OUT="$(cd "$d" && PATH="$NONODE_BIN" bash "$REL" 2>&1)"
CHECK_RC=$?
assert_fail_says "node なし" "Node.js を導入してください"

# ── 直さないこと ─────────────────────────────────────────────────────────────

it "実行しても node_modules の中身を変えない（判定と修復を混ぜない）"
# 黙って npm ci を走らせると、何が起きたのかが見えないまま結果だけが変わる。
d="$(new_project)"; mkdir -p "$d/node_modules"
write_lock "$d" package-lock.json "$ROOT_ENTRY, \"node_modules/a\": { \"version\": \"1.0.0\" }, \"node_modules/b\": { \"version\": \"2.0.0\" }"
write_lock "$d" node_modules/.package-lock.json "\"node_modules/a\": { \"version\": \"1.0.0\" }"
place "$d" node_modules/a
before="$(cd "$d" && find node_modules -print | sort | tr '\n' '/')"
run_check "$d"
after="$(cd "$d" && find node_modules -print | sort | tr '\n' '/')"
if [[ "$CHECK_RC" -eq 0 ]]; then
  fail "この前提では落ちるはずが通過した: $CHECK_OUT"
elif [[ "$before" != "$after" ]]; then
  fail "node_modules が変化した（直してしまっている）"
else
  pass
fi

exit_with_result
