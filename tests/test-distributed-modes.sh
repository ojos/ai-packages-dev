#!/usr/bin/env bash
# 配布されるスクリプトの実行ビットが落ちていないことを機械照合する回帰テスト。
#
# ## なぜ要るか
#
# #343 の作業中に bootstrap.sh のモードが 100755 から 100644 へ落ちた（awk の出力を
# mv で置いたため権限が引き継がれなかった）。**CI も既存の検査もすべて緑のままで、
# 拾ったのはローカル第二意見だけだった。** assert_mode は生成物に対しては使われて
# いるが、リポジトリ自身の追跡ファイルのモードを見る検査は 1 つも無い。
#
# ## 実行ビットは利用者まで届く
#
# scripts/release-packages.sh は cp で配布物を並べ、そのディレクトリを
# PACKAGE_ARCHIVE.tar.gz へ固める。cp も tar もモードを引き継ぐ（実測）。公開中の
# v0.11.0 の資産を展開すると bootstrap.sh / doctor.sh はいずれも -rwxr-xr-x だった。
# monorepo でモードが落ちれば、利用者が展開するアーカイブの中身も実行不可になる。
#
# 個別ダウンロード（curl で bootstrap.sh を取る形）はモードを持たないため影響しない。
#
# ## 対象の決め方
#
# **一覧を書き写さない。** 対象は scripts/release-packages.sh の *_DISTRIBUTED_FILES
# から `*.sh` を取る（共通規範「一覧の複製は機械照合で担保する」。
# tests/test-release-notes-issue-refs.sh と同じ形）。
#
# **「.sh はすべて 755」にはしない。** 追跡している *.sh のうち 30 本は実行ビットを
# 持たない（テストの一部）。一律の規則は 30 本の書き換えを迫る。利用者まで届くことを
# 実測できた配布物だけを対象にする。
#
# 依存はコアユーティリティ（sed / grep / git）のみ。bash 3.2 互換を維持する。

set -uo pipefail
export LC_ALL=C
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-distributed-modes"

RELEASE_SCRIPT="$REPO_ROOT/scripts/release-packages.sh"

# ── 抽出 ──────────────────────────────────────────────────────────────────────

# distributed_sh
#   配布物一覧から `*.sh` の開発リポジトリ側パスを列挙する。
#   形式は "src:dst" の対で、配列リテラルの行に 1 件ずつ並ぶ。
#   字下げは [[:space:]] で書く（`[ \t]` は BSD sed でタブにならない）。
distributed_sh() {
  sed -n 's/^[[:space:]]*"\([^":]*\.sh\):[^"]*".*$/\1/p' "$RELEASE_SCRIPT"
}

# tracked_mode <パス>
#   追跡されているモード（100644 / 100755 等）を返す。追跡外なら空。
#   **判定の本体はここ 1 つに置く。** 本番の配布物も負例フィクスチャも同じ経路を通す。
tracked_mode() {
  ( cd "$REPO_ROOT" && git ls-files -s -- "$1" 2>/dev/null | awk '{print $1; exit}' )
}

DIST_SH="$(distributed_sh)"

it "配布物一覧から *.sh を 1 件以上抽出できる"
# 抽出が壊れて 0 件になると、以降の検査は対象ゼロで無条件に通る（偽の緑）。
DIST_COUNT="$(printf '%s\n' "$DIST_SH" | grep -c . || true)"
if [[ "$DIST_COUNT" -gt 0 ]]; then
  pass
else
  fail "scripts/release-packages.sh から配布対象の *.sh を抽出できなかった"
fi

it "抽出した配布物がすべて実在する"
MISSING=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  [[ -f "$REPO_ROOT/$f" ]] || MISSING="$MISSING $f"
done <<DISTEOF
$DIST_SH
DISTEOF
if [[ -z "$MISSING" ]]; then
  pass
else
  fail "一覧にあるが実体が無い:$MISSING"
fi

# ── 本体 ──────────────────────────────────────────────────────────────────────

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  it "配布される $f が実行ビットを持つ"
  mode="$(tracked_mode "$f")"
  if [[ -z "$mode" ]]; then
    fail "$f が git の追跡下に無い（モードを読めない）"
  elif [[ "$mode" == "100755" ]]; then
    pass
  else
    fail "$f のモードが $mode（100755 であるべき）。利用者が展開する PACKAGE_ARCHIVE.tar.gz の中身も実行不可になる"
  fi
done <<DISTEOF2
$DIST_SH
DISTEOF2

# ── 対照群 ────────────────────────────────────────────────────────────────────

it "同じ判定が、実行ビットの無い .sh を 100644 と読む（意図的な負例）"
# 「判定が存在する」ことと「判定が効いている」ことは別である。追跡下にあり、かつ
# 実行ビットを持たない **`.sh`** を同じ関数へ通し、100755 以外を返すことを見る。
# フィクスチャ側で git ls-files を書き直すと、判定を無効化しても緑を返す。
#
# **対象は `*.sh` を全件走査して選ぶ。** 当初は `*.md` の先頭 5 件から選んでいたが、
# それでは「配布対象でない `.sh` を赤にしない」という対照群にならない（レビューの
# 指摘）。拡張子が違えば、`.sh` の構成が変わっても反応しない。
NONEXEC=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  if [[ "$(tracked_mode "$f")" == "100644" ]]; then NONEXEC="$f"; break; fi
done <<PLAINEOF
$(cd "$REPO_ROOT" && git ls-files -- '*.sh')
PLAINEOF
if [[ -z "$NONEXEC" ]]; then
  fail "実行ビットの無い追跡 .sh を 1 件も見つけられない（対照群が成立しない）"
else
  pass
fi

it "対照群の対象が .sh である（候補の集合を固定する）"
# **拡張子まで見ないと、候補を `*.md` に替えても緑のままになる**（実測で踏んだ）。
# 「実行ビットの無い追跡ファイルがある」ことではなく、「実行ビットの無い **`.sh`** が
# ある」ことを要求する。前者なら `.md` でも満たせてしまい、対照群として成立しない。
case "$NONEXEC" in
  *.sh) pass ;;
  "")   fail "対照群の対象が決まっていない" ;;
  *)    fail "対照群に選ばれたのが .sh ではない: $NONEXEC（候補の集合が間違っている）" ;;
esac

# in_dist <パス>
#   配布物一覧に含まれるか。**判定をここ 1 つに置き、含む側と含まない側の両方を通す。**
in_dist() {
  printf '%s\n' "$DIST_SH" | grep -qxF "$1"
}

it "対照群に選んだ .sh が配布対象に含まれない（本体と対象が重なっていない）"
if [[ -z "$NONEXEC" ]]; then
  fail "対照群の対象が決まっていない"
elif in_dist "$NONEXEC"; then
  fail "対照群に選んだ $NONEXEC が配布物一覧に含まれている（本体と対象が重なっている）"
else
  pass
fi

it "同じ包含判定が、配布物に対しては真を返す（対照群の対照群）"
# 上の判定が「常に偽」でも緑になってしまうため、真を返す側も通す。
FIRST_DIST="$(printf '%s\n' "$DIST_SH" | grep -m1 . || true)"
if [[ -z "$FIRST_DIST" ]]; then
  fail "配布物一覧が空（抽出が壊れている）"
elif in_dist "$FIRST_DIST"; then
  pass
else
  fail "配布物 $FIRST_DIST を一覧に含まれないと判定した（包含判定が効いていない）"
fi

it "同じ判定が、追跡外のパスに対して空を返す（検査が成立しない状態を合格にしない）"
if [[ -z "$(tracked_mode 'no/such/path-for-this-test.sh')" ]]; then
  pass
else
  fail "追跡外のパスにモードを返した（判定が何を見ているか分からない）"
fi

exit_with_result
