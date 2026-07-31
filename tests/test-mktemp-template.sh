#!/usr/bin/env bash
# 追跡対象のシェルスクリプトが、テンプレート引数を持たない mktemp を呼んでいない
# ことを検査する。
#
# BSD 系（macOS）の mktemp はテンプレート引数を必須とする（`-t prefix` を使う場合を
# 除く）。素の `mktemp` / `mktemp -d` は GNU coreutils でしか動かず、macOS では usage
# エラーで落ちる。この差分は Linux コンテナ内でしか動かさない限り一度も表面化せず、
# macOS ホストで実行した利用者の側で初めて落ちる。
#
# bootstrap.sh はホスト側で実行される配布スクリプトで、同じファイルの中で stat の
# GNU / BSD 差分は分岐しているのに mktemp は素のまま、という状態が 19 箇所まで積み
# 上がっていた（#218）。見つけたのは外部のレビューで、目視の規律では止まっていない。
# 呼び出しを足すたびに人が思い出す形にせず、機械で落とす。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-mktemp-template"

# テンプレート引数を持たない呼び出しの形。mktemp のあとにオプションだけが並び、
# コマンド置換の閉じ括弧やパイプ、行末で終わるものを拾う。
#
# 終端に引用符を含めない。`mktemp -d "$dir/x.XXXXXX"` のようにテンプレートを渡した
# 正しい呼び出しまで拾ってしまうため。
BARE_MKTEMP_RE='mktemp([[:space:]]+-[a-zA-Z-]+)*[[:space:]]*([)|;&`]|$)'

# 標準入力を読み、該当する行を "行番号:内容" で返す。
#
# ファイルではなく標準入力を受けるのは、この検査自身をファイルを作らずに検証できる
# ようにするため（プロジェクト層のテストはコアユーティリティだけで完結させる）。
#
# コメント行は除外する。説明文中の mktemp まで拾うと、検査が文章の書き方に依存する。
bare_mktemp_lines() {
  grep -nE "$BARE_MKTEMP_RE" | grep -vE '^[0-9]+:[[:space:]]*#'
}

# ── 検査ロジック自身の検証 ────────────────────────────────────────────────────
#
# 検査が何も拾わないまま緑になる状態を防ぐ。実装を直したあとは、対象が 0 件でも
# 検査が壊れていないことを別に示す必要がある。

# 悪い例をこのファイルへそのまま書くと、この検査が自分自身を拾う。名前を組み立てて
# 避ける（連結した結果は mktemp だが、ファイル上の文字列としては一致しない）。
bad_cmd="mk""temp"

it "テンプレート無しの呼び出しを検出する"
bad=0
for sample in "dir=\"\$($bad_cmd -d)\"" "f=\"\$($bad_cmd)\"" "$bad_cmd -d | head -1"; do
  if ! printf '%s\n' "$sample" | bare_mktemp_lines >/dev/null; then
    echo "  検出できなかった: $sample"
    bad=1
  fi
done
if [[ "$bad" -eq 0 ]]; then pass; else fail "テンプレート無しの呼び出しを取りこぼしている"; fi

it "テンプレート付きの呼び出しは検出しない"
# 誤検出すると、正しい呼び出しを直そうとして戻す方向の修正を招く。
bad=0
for sample in \
  'dir="$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")"' \
  'f="$(mktemp "$ROOT/y.XXXXXX")"' \
  '  # 素の mktemp は macOS で落ちる' \
; do
  if printf '%s\n' "$sample" | bare_mktemp_lines >/dev/null; then
    echo "  誤検出した: $sample"
    bad=1
  fi
done
if [[ "$bad" -eq 0 ]]; then pass; else fail "正しい呼び出しやコメントを誤検出している"; fi

# ── リポジトリ全体の検査 ──────────────────────────────────────────────────────

it "追跡対象の .sh にテンプレート無しの mktemp が無い"
hits=""
while IFS= read -r f; do
  [[ -f "$REPO_ROOT/$f" ]] || continue
  found="$(bare_mktemp_lines < "$REPO_ROOT/$f")"
  [[ -n "$found" ]] && hits="$hits$(printf '%s\n' "$found" | sed "s|^|$f:|")
"
done <<EOF
$(cd "$REPO_ROOT" && git ls-files '*.sh')
EOF

if [[ -z "$hits" ]]; then
  pass
else
  fail "テンプレート無しの mktemp が残っている:
$hits"
fi

exit_with_result
