#!/usr/bin/env bash
# 開発リポジトリの agy 導入・テレメトリ無効化と、DCB 生成器が配る同等処理が
# 乖離しないことを機械照合する。
#
# ## なぜ要るか
#
# scripts/install-ai-tools.sh は tests/test-template-mirror.sh の EXCLUDED_RELS に
# あり、逐語照合の対象外である（正本が __AI_INSTALL_LINES__ を持ち、導入する CLI の
# 選択で行が変わるため、バイト一致は原理的に成立しない）。つまり開発リポジトリの
# 写しと生成物は自動では揃わない。
#
# 一方 agy の 2 関数（install_agy_if_missing / disable_agy_telemetry）は構成に
# よらず内容が変わらない。ここだけは揃えられるし、揃っていないと困る。片方で
# 直した不具合が他方に残るためで、実際 `.enableTelemetry // empty` の誤り
# （jq の // は false も代替側へ落とす）は開発リポジトリ側の回帰テストが見つけた。
# 生成物側が同じ誤りを抱えたままになる経路を塞ぐ。
#
# ## 何を比べるか
#
# **コード行だけ**を比べ、コメントと空行は落とす。コメントは層ごとに正しく異なる
# （開発リポジトリ側は scripts/acceptance.sh を引き合いに出すが、生成物にそんな
# ファイルの前提は無い）。ここで一致を求めると、正しい記述の側を歪めることになる。
# 検出したいのは処理の乖離なので、コードだけで足りる。
#
# 依存はコアユーティリティのみ。bash 3.2 互換を維持する。

set -uo pipefail
export LC_ALL=C.UTF-8
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-agy-install-mirror"

CANON="$REPO_ROOT/scripts/install-ai-tools.sh"
BOOTSTRAP="$REPO_ROOT/packages/devcontainer-bootstrap/bootstrap.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-agy-install-mirror.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# シェル関数の本体を名前で切り出す。`<name>() {` から、桁 1 の `}` までを返す。
# 対象の 2 関数はいずれもこの形で書かれている。
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
  --output-dir "$GEN" --with-antigravity >/dev/null 2>&1
GENERATED="$GEN/scripts/install-ai-tools.sh"

it "--with-antigravity で install-ai-tools.sh が生成される"
if [[ -f "$GENERATED" ]]; then
  pass
else
  fail "生成物が無い: $GENERATED"
fi

# ── 関数ごとの照合 ────────────────────────────────────────────────────────────

for fn in install_agy_if_missing disable_agy_telemetry; do
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

it "AGY_SETTINGS の指す先が正本と生成物で一致する"
# 関数の外にある代入なので、上のループでは見ていない。ここがずれると、同じコードが
# 別のファイルを読み書きする。
canon_path="$(grep -E '^AGY_SETTINGS=' "$CANON" | head -n 1)"
gen_path="$(grep -E '^AGY_SETTINGS=' "$GENERATED" | head -n 1)"
if [[ -n "$canon_path" && "$canon_path" == "$gen_path" ]]; then
  pass
else
  fail "正本='$canon_path' 生成物='$gen_path'"
fi

# ── 照合が生きていることの確認（対照） ────────────────────────────────────────

it "コードを 1 行変えると赤になる（意図的な乖離フィクスチャ）"
# 「一致した」が抽出の失敗や比較の空振りではないことを示す。正本の側は触らず、
# 生成物の写しを作って 1 行だけ壊す。
BROKEN="$TMP_ROOT/broken.sh"
sed 's/jq -r .\.enableTelemetry./jq -r ".enableTelemetry \/\/ empty"/' "$GENERATED" > "$BROKEN"
broken_body="$(extract_func "$BROKEN" disable_agy_telemetry | code_only)"
canon_body="$(extract_func "$CANON" disable_agy_telemetry | code_only)"
if [[ -n "$broken_body" && "$broken_body" != "$canon_body" ]]; then
  pass
else
  fail "1 行変えても差分として現れない（照合が空振りしている）"
fi

exit_with_result
