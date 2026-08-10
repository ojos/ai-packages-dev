#!/usr/bin/env bash
# リリース preflight の Markdown アンカー検証が、GitHub のアンカー生成規則と
# 一致していることを検査する。
#
# 背景:
#   scripts/release-packages.sh の validate_markdown_links_in_tree は、見出しから
#   アンカー ID を再現して `[...](#anchor)` の指し先を照合する。この再現規則が
#   GitHub とずれていると、**正しいリンクを壊れていると報告して リリースを止める**
#   （逆向きに、壊れたリンクを見逃す形にもなりうる）。
#
#   実際に v0.9.1 のリリース dry-run が 4 件の誤検知で落ちた。原因は再現規則の
#   2 点のずれで、いずれも ASCII の句読点だけを列挙していたことに由来する。
#
#     - `_` を落としていた（GitHub は残す）
#     - 全角括弧 `（）` を残していた（GitHub は落とす）
#
#   期待値は GitHub が実際に生成した ID を実測して採った（gh api の
#   Accept: application/vnd.github.html で描画結果の id を取得）。推測ではない。
#
# この検査が止めるもの:
#   規則を将来また ASCII 前提へ戻す変更、および文字クラスの取りこぼし。
#   リリース時にしか走らない検査は、壊れていても次のリリースまで誰も気づかない。
#   ここへ載せることで、通常の verify で落ちるようにする。
#
# 依存: python3（検証実装そのものが python3 で書かれているため。テストが新たに
#       持ち込む依存ではない）。ネットワークへは出ない。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-release-anchor-slug"

RELEASE_SH="$REPO_ROOT/scripts/release-packages.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-anchor-slug.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# 検証実装の python ブロックを取り出す。行番号は決め打ちしない（release-packages.sh は
# 行がずれる）。アンカーはヒアドキュメントの開始行と終端の PY。
extract_validator() {
  awk '
    /python3 - "\$base_dir" <<.PY./ { inside = 1; next }
    inside && /^PY$/ { exit }
    inside { print }
  ' "$RELEASE_SH"
}

VALIDATOR="$TMP_ROOT/validator.py"
extract_validator > "$VALIDATOR"

it "検証実装の python ブロックを抽出できる"
# 抽出に失敗したまま以降を回すと、何も検査していないのに緑になる。
if [[ -s "$VALIDATOR" ]] && grep -q "def slugify" "$VALIDATOR"; then
  pass
else
  fail "validate_markdown_links_in_tree の python ブロックを抽出できなかった"
fi

# ── GitHub の実測値との照合 ──────────────────────────────────────────────────
#
# 見出しと、GitHub が実際に生成したアンカー ID の対。
# 取得方法（再現手順）:
#   gh api repos/<owner>/<repo>/contents/<path> -H "Accept: application/vnd.github.html" \
#     | grep -oE 'id="user-content-[^"]*"'
it "GitHub が生成するアンカー ID を再現する"
# slugify だけを使いたいので、抽出したブロックから関数定義を切り出して評価する。
# ブロック全体は実行時に sys.argv[1] をディレクトリとして要求するため、そのまま
# 評価するとメイン処理が走ってしまう。
#
# 切り出しの目印が消えていたら、黙って全体を評価せず**その場で落とす**。
# 目印が無いまま先へ進むと、メイン処理がファイルをディレクトリとして扱って
# 別の理由で落ち、原因が読めなくなる。
python3 - "$VALIDATOR" <<'PY' > "$TMP_ROOT/slug_result.txt" 2>&1
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
if "def slugify" not in src or "def heading_slugs" not in src:
    print("SLUG_NG 切り出しの目印（def slugify / def heading_slugs）が見つからない")
    raise SystemExit(0)
head = "import re\nimport unicodedata\n" + src[src.index("def slugify"):src.index("def heading_slugs")]
ns = {}
exec(head, ns)
slugify = ns["slugify"]

cases = [
    # _ は残る（旧実装は落としていた）
    ("`GITHUB_TOKEN` は設定しない", "github_token-は設定しない"),
    # 全角括弧は落ちる（旧実装は残していた）
    ("利用側の設定手順（許可 author email）", "利用側の設定手順許可-author-email"),
    ("マージ確認フック（Claude Code）", "マージ確認フックclaude-code"),
    # 連続する - は畳まない。記号を挟んだ空白は -- になる（旧実装は畳んでいた）
    ("受け入れ条件の二層（ローカル層 / 外部層）", "受け入れ条件の二層ローカル層--外部層"),
    ("装備オプション（--with-*）", "装備オプション--with-"),
    # 素の見出し
    ("資格情報の扱い", "資格情報の扱い"),
    ("GitHub 認証だけが例外である理由", "github-認証だけが例外である理由"),
]
bad = 0
for heading, want in cases:
    got = slugify(heading)
    if got != want:
        print(f"NG heading={heading!r} got={got!r} want={want!r}")
        bad = 1
print("SLUG_OK" if bad == 0 else "SLUG_NG")
PY
if grep -q '^SLUG_OK$' "$TMP_ROOT/slug_result.txt"; then
  pass
else
  fail "アンカー ID の再現が GitHub とずれている: $(cat "$TMP_ROOT/slug_result.txt")"
fi

# ── 検証器そのものの両方向 ────────────────────────────────────────────────────

mk_tree() {
  local dir="$1"
  mkdir -p "$dir"
  printf '%s\n' "$2" > "$dir/README.md"
}

it "正しいアンカーのリンクを壊れていると報告しない"
mk_tree "$TMP_ROOT/ok" '# 見出し

- [設定しない](#github_token-は設定しない)
- [手順](#利用側の設定手順許可-author-email)

### `GITHUB_TOKEN` は設定しない

本文。

### 利用側の設定手順（許可 author email）

本文。'
out="$(python3 "$VALIDATOR" "$TMP_ROOT/ok" 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]]; then pass; else fail "正しいリンクを落とした (exit $rc): $out"; fi

it "実在しないアンカーは報告する（対照）"
mk_tree "$TMP_ROOT/ng" '# 見出し

- [壊れた参照](#存在しない見出し)

### 実在する見出し

本文。'
out="$(python3 "$VALIDATOR" "$TMP_ROOT/ng" 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]] && printf '%s' "$out" | grep -q 'missing local anchor'; then
  pass
else
  fail "壊れたアンカーを見逃した (exit $rc): $out"
fi

exit_with_result
