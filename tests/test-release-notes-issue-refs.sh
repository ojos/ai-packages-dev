#!/usr/bin/env bash
# 配布される文書の issue 参照が、配布先で解決できる形かを機械照合する回帰テスト。
#
# リリースノートは各公開リポジトリへ `CHANGELOG.md` として配られる。issue の実体は
# この開発リポジトリにしか無いため、裸の `#NNN` を書くと GitHub のオートリンクが
# **配布先リポジトリの issue** として解決し、配布後は存在しない issue や無関係な
# issue を指す（issue #276）。修飾形 `ojos/ai-packages-dev#NNN` はどのリポジトリから
# 見ても同じ issue を指す。
#
# ## 対象の決め方
#
# 対象は決め打ちせず、配布物の一覧（scripts/release-packages.sh の
# *_DISTRIBUTED_FILES）から `*.md` を取る。ここを書き写すと、配布物が増えたときに
# 検査だけが古くなる（shared-ai-rules.md 12 章「一覧の複製は機械照合で担保する」）。
#
# ## 層が 2 つに割れる理由
#
# 配布物のうち packages/ と .ai-playbook/ は scripts/check-neutrality.sh の検査対象で、
# `ojos` を含む文字列を置けない（許可されるのは配布先リポジトリ名 2 つだけ）。
# つまりこの 2 層では修飾形そのものが書けないため、「修飾形へ直す」という指示は
# 成立しない。かわりに、そもそも開発リポジトリの issue を参照しないことを求める。
# 中立な規範層が特定リポジトリの票へ依存するのは層の逆転でもある。
#
#   - 中立性検査の外（docs/release/…）: 裸 `#NNN` を禁じ、修飾形を求める
#   - 中立性検査の内（packages/ .ai-playbook/）: issue 参照そのものを持たせない
#
# 両者を 1 つの規則にまとめると、片方で必ず矛盾する。
#
# ## 検出から除くもの
#
# GitHub がオートリンクしない位置は誤検知になるため、判定の前に落とす。
#
#   1. フェンス付きコードブロック（``` で囲まれた範囲）
#   2. インラインコードスパン（`…`）
#   3. markdown のリンク先（`](…)`）— 節アンカー `](#11-…)` が `#11` に見える
#
# 3 は実在する。`.ai-playbook/shared-ai-rules.md` の
# `[…](#11-セッション開始時の重複排除ゲート)` が該当し、落とさないと偽の赤になる。
#
# 依存はコアユーティリティ（awk / sed / grep）のみ。bash 3.2 互換を維持する
# （連想配列・mapfile を使わない）。

set -uo pipefail
export LC_ALL=C.UTF-8
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-release-notes-issue-refs"

RELEASE_SCRIPT="$REPO_ROOT/scripts/release-packages.sh"

# 修飾形。裸参照の検出はこの形を除いた `#NNN` を探す。
QUALIFIED_PREFIX='ojos/ai-packages-dev'

# ── 抽出 ──────────────────────────────────────────────────────────────────────

# sanitize <ファイル>
#
# オートリンクが働かない位置を落とした本文を標準出力へ書く。
#
# 落とす範囲は空行へ潰し、行を削除しない。削除すると以降の行番号がずれ、失敗時に
# 示す位置が実ファイルと食い違う（指摘を受けた人が別の行を見に行くことになる）。
sanitize() {
  awk '
    /^[ \t]*```/ { in_fence = !in_fence; print ""; next }
    { print in_fence ? "" : $0 }
  ' "$1" | sed -e 's/\]([^)]*)//g' -e 's/`[^`]*`//g'
}

# 以下 3 つの抽出関数は、いずれも「1 件も無い」が正常な結果である。grep はその
# ときに終了コード 1 を返し、pipefail 下ではパイプライン全体が 1 になる。呼び出し
# 側は出力の中身だけを見るので現状は影響しないが、set -e を足した瞬間に「問題が
# 無い状態でテストが落ちる」という逆向きの壊れ方をする。0 件を失敗として持ち回ら
# ないよう、抽出の側で 0 に畳んでおく。

# bare_refs <ファイル>
#
# 修飾されていない issue 参照を「行番号:該当文字列」で列挙する。
# 直前が名前文字（英数・_ / -）の場合は修飾形の末尾なので数えない。
bare_refs() {
  sanitize "$1" \
    | { grep -noE '(^|[^A-Za-z0-9_/-])#[0-9]+' || true; } \
    | sed 's/:[^:]*\(#[0-9]*\)$/:\1/'
}

# qualified_refs <ファイル>
qualified_refs() {
  sanitize "$1" | { grep -oE "$QUALIFIED_PREFIX#[0-9]+" || true; }
}

# any_refs <ファイル> — 裸・修飾を問わず issue 参照らしきものを数える。
any_refs() {
  sanitize "$1" | { grep -oE '#[0-9]+' || true; }
}

# 配布物一覧から `*.md` の開発リポジトリ側パスを取り出す。
# 形式は "src:dst" の対で、配列リテラルの行に 1 件ずつ並ぶ。
distributed_md() {
  # 字下げは [[:space:]] で書く。`[ \t]` は BSD sed（macOS）が `\t` をタブとして
  # 解釈せず「空白・バックスラッシュ・t」の集合になり、タブ字下げの行を取りこぼす
  # （#294）。空白字下げの現状では偶然動くため、実機で落ちるまで気づかない。
  sed -n 's/^[[:space:]]*"\([^":]*\.md\):[^"]*".*$/\1/p' "$RELEASE_SCRIPT"
}

DIST_MD="$(distributed_md)"

it "配布物一覧から *.md を 1 件以上抽出できる"
# 抽出が壊れて 0 件になると、以降の検査は対象ゼロで無条件に通る（偽の緑）。
#
# 0 件は「数え上げた結果」であって実行の失敗ではない。grep は 0 件で終了コード 1 を
# 返し、pipefail 下では代入全体が 1 になる。このテストは set -e を使っていないので
# 現状は止まらないが、意図を式の上に出しておく（tests/test-doc-section-refs.sh の
# count_form_matches と同じ扱い）。
DIST_COUNT="$(printf '%s\n' "$DIST_MD" | grep -c . || true)"
if [[ "$DIST_COUNT" -gt 0 ]]; then
  pass
else
  fail "scripts/release-packages.sh から配布対象の *.md を抽出できなかった"
fi

it "抽出した配布対象がすべて実在する"
MISSING=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  [[ -f "$REPO_ROOT/$f" ]] || MISSING="$MISSING $f"
done <<DISTEOF
$DIST_MD
DISTEOF
if [[ -z "$MISSING" ]]; then
  pass
else
  fail "一覧にあるが実体が無い:$MISSING"
fi

# 中立性検査の内側か外側かで層を分ける。
NEUTRAL_MD=""
NOTES_MD=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    packages/*|.ai-playbook/*) NEUTRAL_MD="$NEUTRAL_MD$f
" ;;
    *) NOTES_MD="$NOTES_MD$f
" ;;
  esac
done <<DISTEOF2
$DIST_MD
DISTEOF2

it "中立性検査の外側の配布文書が 1 件以上ある（リリースノート層）"
NOTES_COUNT="$(printf '%s' "$NOTES_MD" | grep -c . || true)"
if [[ "$NOTES_COUNT" -gt 0 ]]; then
  pass
else
  fail "リリースノート層の配布文書が 0 件だった"
fi

it "リリースノート層に裸の issue 参照が 1 件も無い"
BARE_HITS=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  hits="$(bare_refs "$REPO_ROOT/$f")"
  [[ -n "$hits" ]] && BARE_HITS="${BARE_HITS}${f}: $(printf '%s' "$hits" | tr '\n' ' ')
"
done <<NOTESEOF
$NOTES_MD
NOTESEOF
if [[ -z "$BARE_HITS" ]]; then
  pass
else
  fail "配布先で別の issue を指す裸参照が残っている:
$BARE_HITS"
fi

it "リリースノート層から修飾済み参照を 1 件以上抽出できる"
# 「裸参照ゼロ」だけでは、参照を全部消しても緑になる。修飾形が現に使われている
# ことを併せて要求し、検査が空回りしていないことを示す。
QUAL_TOTAL=0
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  n="$(qualified_refs "$REPO_ROOT/$f" | grep -c . || true)"
  QUAL_TOTAL=$((QUAL_TOTAL + n))
done <<NOTESEOF2
$NOTES_MD
NOTESEOF2
if [[ "$QUAL_TOTAL" -gt 0 ]]; then
  pass
else
  fail "修飾済み参照が 1 件も無い（検査対象が空の可能性）"
fi

it "中立性検査の対象となる配布物は issue 参照そのものを持たない"
# この層では修飾形が書けない（ojos を置けない）ため、裸参照だけを禁じると
# 直しようのない指摘になる。参照を持たないことを求める。
NEUTRAL_HITS=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  hits="$(any_refs "$REPO_ROOT/$f" | tr '\n' ' ')"
  [[ -n "$hits" ]] && NEUTRAL_HITS="${NEUTRAL_HITS}${f}: ${hits}
"
done <<NEUTRALEOF
$NEUTRAL_MD
NEUTRALEOF
if [[ -z "$NEUTRAL_HITS" ]]; then
  pass
else
  fail "中立性検査の対象に issue 参照がある（修飾形も書けないため参照自体を外す）:
$NEUTRAL_HITS"
fi

# ── フィクスチャでの負例検査（リポジトリの実ファイルは書き換えない） ────────

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-release-notes-issue-refs.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

it "裸の issue 参照を検出する（意図的な負例フィクスチャ）"
cat > "$FIXTURE_DIR/bare.md" <<'EOF'
- 判定を末尾のトークンへ変更した（#267）。挙動変更。
EOF
if [[ -n "$(bare_refs "$FIXTURE_DIR/bare.md")" ]]; then
  pass
else
  fail "裸参照 #267 を検出できなかった"
fi

it "修飾済みの参照は検出しない（対照群）"
cat > "$FIXTURE_DIR/qualified.md" <<'EOF'
- 判定を末尾のトークンへ変更した（ojos/ai-packages-dev#267）。挙動変更。
EOF
if [[ -z "$(bare_refs "$FIXTURE_DIR/qualified.md")" ]]; then
  pass
else
  fail "修飾済み参照を裸参照として誤検出した: $(bare_refs "$FIXTURE_DIR/qualified.md")"
fi

it "コードブロック内の #NNN は検出しない（オートリンクが働かない位置）"
cat > "$FIXTURE_DIR/fence.md" <<'EOF'
実行例:

```bash
# 268 番の差分を見る
git show #268
```
EOF
if [[ -z "$(bare_refs "$FIXTURE_DIR/fence.md")" ]]; then
  pass
else
  fail "コードブロック内を誤検出した: $(bare_refs "$FIXTURE_DIR/fence.md")"
fi

it "インラインコードスパン内の #NNN は検出しない"
cat > "$FIXTURE_DIR/span.md" <<'EOF'
記法の例として `#268` のような裸の番号を挙げる。
EOF
if [[ -z "$(bare_refs "$FIXTURE_DIR/span.md")" ]]; then
  pass
else
  fail "コードスパン内を誤検出した: $(bare_refs "$FIXTURE_DIR/span.md")"
fi

it "節アンカーへの markdown リンクは検出しない（実在の誤検知源）"
# .ai-playbook/shared-ai-rules.md の [...](#11-セッション開始時の重複排除ゲート)。
cat > "$FIXTURE_DIR/anchor.md" <<'EOF'
証跡は[セッション開始時の重複排除ゲート](#11-セッション開始時の重複排除ゲート)で使う。
EOF
if [[ -z "$(bare_refs "$FIXTURE_DIR/anchor.md")" ]]; then
  pass
else
  fail "節アンカーを誤検出した: $(bare_refs "$FIXTURE_DIR/anchor.md")"
fi

it '見出し記号そのものは検出しない（`## v0.9.1` の形）'
cat > "$FIXTURE_DIR/heading.md" <<'EOF'
## v0.9.1

### 4) 事後確認
EOF
if [[ -z "$(bare_refs "$FIXTURE_DIR/heading.md")" ]]; then
  pass
else
  fail "見出しを誤検出した: $(bare_refs "$FIXTURE_DIR/heading.md")"
fi

exit_with_result
