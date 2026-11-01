#!/usr/bin/env bash
# 開発リポジトリの install-ai-tools.sh の、AI CLI の版の下限まわり（共通の関数と
# claude・gemini の導入行）と、DCB 生成器が配る同等処理が乖離しないことを機械照合する。
# test-agy-install-mirror.sh / test-codex-install-mirror.sh の共通部分・claude・gemini 版。
#
# ## なぜ要るか
#
# scripts/install-ai-tools.sh は tests/test-template-mirror.sh の EXCLUDED_RELS にあり、
# 逐語照合の対象外である（導入する CLI の選択で行が変わるため）。版の比較
# （ai_cli_version_is_old）・版の取得（ai_cli_version）・導入（install_if_missing）は
# 構成によらず内容が変わらない。片方で直した不具合が他方に残らないよう、関数ごとに揃える。
# claude・gemini は専用の関数を持たず、install_if_missing の第 3 引数に下限を渡す導入行
# （`install_if_missing claude "<パッケージ>" "<下限>"`）なので、その行も揃える。
#
# **コード行だけ**を比べ、コメントと空行は落とす（層ごとに正しく異なるため）。
# 依存はコアユーティリティのみ。bash 3.2 互換を維持する。

set -uo pipefail
export LC_ALL=C.UTF-8
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-ai-cli-version-mirror"

CANON="$REPO_ROOT/scripts/install-ai-tools.sh"
BOOTSTRAP="$REPO_ROOT/packages/devcontainer-bootstrap/bootstrap.sh"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-ai-cli-version-mirror.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# シェル関数の本体を名前で切り出す。`<name>() {` から、桁 1 の `}` までを返す。
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

GEN="$TMP_ROOT/gen"
bash "$BOOTSTRAP" --project-name mirror --languages node \
  --output-dir "$GEN" --with-claude --with-gemini >/dev/null 2>&1
GENERATED="$GEN/scripts/install-ai-tools.sh"

it "--with-claude --with-gemini で install-ai-tools.sh が生成される"
if [[ -f "$GENERATED" ]]; then pass; else fail "生成物が無い: $GENERATED"; fi

for fn in ai_cli_version_is_old ai_cli_version install_if_missing; do
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

for cli in claude gemini; do
  it "$cli の導入行（パッケージ名と下限）が正本と生成物で一致する"
  canon_line="$(grep -E "^install_if_missing $cli " "$CANON")"
  gen_line="$(grep -E "^install_if_missing $cli " "$GENERATED")"
  if [[ -n "$canon_line" && "$canon_line" == "$gen_line" && "$canon_line" =~ \"[0-9]+\.[0-9]+\.[0-9]+\"$ ]]; then
    pass
  else
    fail "正本='$canon_line' 生成物='$gen_line'"
  fi
done

it "claude の下限が doctor.sh の CLAUDE_MIN_VERSION と一致する"
doctor_min="$(sed -n 's/^CLAUDE_MIN_VERSION="\([0-9.]*\)".*/\1/p' "$REPO_ROOT/packages/devcontainer-bootstrap/doctor.sh" | head -n 1)"
canon_min="$(sed -n 's/^install_if_missing claude "[^"]*" "\([0-9.]*\)"$/\1/p' "$CANON" | head -n 1)"
if [[ -n "$doctor_min" && "$doctor_min" == "$canon_min" ]]; then pass; else fail "doctor.sh='$doctor_min' 正本='$canon_min'"; fi

# ── 照合が生きていることの確認（対照） ────────────────────────────────────────

it "コードを 1 行変えると赤になる（意図的な乖離フィクスチャ）"
BROKEN="$TMP_ROOT/broken.sh"
sed 's/if (h > w) { exit 1 }/if (h > w) { exit 0 }/' "$GENERATED" > "$BROKEN"
broken_body="$(extract_func "$BROKEN" ai_cli_version_is_old | code_only)"
canon_body="$(extract_func "$CANON" ai_cli_version_is_old | code_only)"
if [[ -n "$broken_body" && "$broken_body" != "$canon_body" ]]; then
  pass
else
  fail "1 行変えても差分として現れない（照合が空振りしている）"
fi

exit_with_result
