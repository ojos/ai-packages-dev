#!/usr/bin/env bash
# 開発リポジトリの codex 導入（版の下限つき）と、DCB 生成器が配る同等処理が
# 乖離しないことを機械照合する。test-agy-install-mirror.sh の codex 版。
#
# ## なぜ要るか
#
# scripts/install-ai-tools.sh は tests/test-template-mirror.sh の EXCLUDED_RELS に
# あり、逐語照合の対象外である（正本が __CODEX_FUNCTION_LINES__ を持ち、導入する
# CLI の選択で行が変わるため、バイト一致は原理的に成立しない）。つまり開発
# リポジトリの写しと生成物は自動では揃わない。
#
# 一方 codex の版判定（codex_version_is_old / install_codex_if_missing）と下限
# （CODEX_MIN_VERSION）は構成によらず内容が変わらない。ここだけは揃えられるし、
# 揃っていないと困る。片方で直した不具合（版の読み違い等）が他方に残る。
#
# ## 何を比べるか
#
# **コード行だけ**を比べ、コメントと空行は落とす。コメントは層ごとに正しく異なる
# （生成物側は「この devcontainer では」のような一般化した書き方になる一方、
# 開発リポジトリ側は自分自身の devcontainer を指して書ける）。ここで一致を求めると、
# 正しい記述の側を歪めることになる。検出したいのは処理の乖離なので、コードだけで
# 足りる。
#
# 依存はコアユーティリティのみ。bash 3.2 互換を維持する。

set -uo pipefail
export LC_ALL=C.UTF-8
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-codex-install-mirror"

CANON="$REPO_ROOT/scripts/install-ai-tools.sh"
BOOTSTRAP="$REPO_ROOT/packages/devcontainer-bootstrap/bootstrap.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-codex-install-mirror.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# シェル関数の本体を名前で切り出す。`<name>() {` から、桁 1 の `}` までを返す。
# 対象の関数はいずれもこの形で書かれている。
extract_func() {
  local file="$1" name="$2"
  NAME_WANT="$name" awk '
    BEGIN { want = ENVIRON["NAME_WANT"] "() {" }
    !inside && index($0, want) == 1 { inside = 1; print; next }
    inside { print; if ($0 == "}") exit }
  ' "$file"
}

# コメントと空行を落としたコード行だけを返す。
code_only() {
  grep -vE '^[[:space:]]*#' | grep -vE '^[[:space:]]*$'
}

# ── 生成 ──────────────────────────────────────────────────────────────────────

GEN="$TMP_ROOT/gen"
bash "$BOOTSTRAP" --project-name mirror --languages node \
  --output-dir "$GEN" --with-codex >/dev/null 2>&1
GENERATED="$GEN/scripts/install-ai-tools.sh"

it "--with-codex で install-ai-tools.sh が生成される"
if [[ -f "$GENERATED" ]]; then
  pass
else
  fail "生成物が無い: $GENERATED"
fi

# ── 関数ごとの照合 ────────────────────────────────────────────────────────────

for fn in codex_version_is_old install_codex_if_missing; do
  canon_body="$(extract_func "$CANON" "$fn" | code_only)"
  gen_body="$(extract_func "$GENERATED" "$fn" | code_only)"

  # 抽出が壊れて空になると、空同士の比較で無条件に緑になる（偽の緑）。
  it "$fn を両側から抽出できる"
  if [[ -n "$canon_body" && -n "$gen_body" ]]; then
    pass
  else
    fail "抽出結果が空（正本 $(printf '%s' "$canon_body" | grep -c .) 行 / 生成物 $(printf '%s' "$gen_body" | grep -c .) 行）"
  fi

  it "$fn のコードが正本と生成物で一致する"
  if [[ "$canon_body" == "$gen_body" ]]; then
    pass
  else
    fail "乖離あり:
$(diff <(printf '%s\n' "$canon_body") <(printf '%s\n' "$gen_body") | head -n 20)"
  fi
done

it "CODEX_MIN_VERSION の値が正本と生成物で一致する"
# 関数の外にある代入なので、上のループでは見ていない。ここがずれると、同じ判定
# ロジックが別の下限で版を評価する。
canon_min="$(grep -E '^CODEX_MIN_VERSION=' "$CANON" | head -n 1)"
gen_min="$(grep -E '^CODEX_MIN_VERSION=' "$GENERATED" | head -n 1)"
if [[ -n "$canon_min" && "$canon_min" == "$gen_min" ]]; then
  pass
else
  fail "正本='$canon_min' 生成物='$gen_min'"
fi

# ── 照合が生きていることの確認（対照） ────────────────────────────────────────

it "コードを 1 行変えると赤になる（意図的な乖離フィクスチャ）"
# 「一致した」が抽出の失敗や比較の空振りではないことを示す。正本の側は触らず、
# 生成物の写しを作って 1 行だけ壊す。
BROKEN="$TMP_ROOT/broken.sh"
sed 's/CODEX_MIN_VERSION="0\.156\.0"/CODEX_MIN_VERSION="0.0.0"/' "$GENERATED" > "$BROKEN"
broken_min="$(grep -E '^CODEX_MIN_VERSION=' "$BROKEN" | head -n 1)"
canon_min="$(grep -E '^CODEX_MIN_VERSION=' "$CANON" | head -n 1)"
if [[ -n "$broken_min" && "$broken_min" != "$canon_min" ]]; then
  pass
else
  fail "1 行変えても差分として現れない（照合が空振りしている）"
fi

exit_with_result
