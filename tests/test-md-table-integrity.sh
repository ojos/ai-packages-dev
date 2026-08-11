#!/usr/bin/env bash
# markdown の表が本文の挿入で分断され、後続の行が表の外へ取り残されていないことを
# 検査する。
#
# #289 の実装中に実際に混入させた。「親セッションが担う」表へ 1 行足す際、説明文を
# 表の途中へ挿入してしまい、既存の reviewer 行が表の外へ取り残された。
#
#   | consult-facilitator | 横断相談は… |
#   | planner | 計画の出力は… |
#
#   `planner` は当初サブエージェントとして…
#   ではありません。
#   | reviewer | 第二意見は別ベンダーの… |    <- 表の外。ただの文字列として描画される
#
# 差分を読み直して気づいたが、既存の検査は 1 つも落ちなかった。test-subagent-roles.sh
# は「委譲可能な役割とモデル配分」の表しか解析せず、test-doc-section-refs.sh は節名
# 参照だけを見る。汎用の markdown リンタはこのリポジトリに無い。
#
# 取り残された行は情報が欠落するのではなく、規範として読めなくなる。上の例では
# 「reviewer は親セッションが担う」という規範が、表の一部ではない浮いた文字列に
# なっていた。レビューで気づかなければそのまま残る（#291）。
#
# 判定は位置で行う。markdown の表は「ヘッダー行の次の行が区切り行」という位置規則で
# 決まり、区切り行だけを内容から見分ける方法は無い（`| - | - |` は 2 行目なら区切り、
# それ以外ならデータ行）。この検査も同じ位置規則に揃える。
#
# bash 3.2 互換を維持する（連想配列・mapfile を使わない）。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-md-table-integrity"

# ── 走査対象 ──────────────────────────────────────────────────────────────────
#
# test-doc-section-refs.sh と同じ集合に揃える。docs/records/ と docs/archive/ は
# 過去の記録で、後から整形しない方針のため除く。
SRC_FILES="$(cd "$REPO_ROOT" && git ls-files '*.md' | grep -v '^docs/records/' | grep -v '^docs/archive/')"

# ── フェンス除去 ──────────────────────────────────────────────────────────────
#
# 標準入力を読み、``` で囲まれたコード部分を空行へ置換して返す。コード外の行はそのまま
# 残し、行番号を保つ（報告する行番号が元ファイルとずれると、指摘を追えない）。
#
# フェンス内を除くのは、行頭が `|` になるコード例（表の書き方の説明そのものを含む）を
# 表として解析すると、正しい記述を直そうとして戻す方向の修正を招くため。
#
# フェンスの開閉は単純な反転で判定しない。文書では「コードブロックの書き方」を示すために
# フェンスを入れ子にすることがあり（外側を 4 個以上のバッククォートで囲む）、反転だと
# 内側の開始で外へ出たことになる。以降の内外がずれ続ける。開いたときの長さを覚え、
# それ以上の長さで、かつ言語指定を持たない行だけを閉じとして扱う（CommonMark の
# フェンス規則）。この判定は test-mktemp-template.sh の fenced_code_only() と同じ規則で、
# あちらはコード側を残す。内外が逆なだけで規則は共有している。
outside_fences() {
  awk '
    function fence_len(s,   n) {
      sub(/^[[:space:]]*/, "", s)
      n = 0
      while (substr(s, n + 1, 1) == "`") n++
      return n
    }
    {
      fl = fence_len($0)
      if (fl >= 3) {
        if (!inside) {
          inside = 1
          open_len = fl
        } else if (fl >= open_len && $0 ~ /^[[:space:]]*`+[[:space:]]*$/) {
          inside = 0
        }
        print ""
        next
      }
      if (inside) print ""; else print
    }
  '
}

# ── 表ブロックの判定 ──────────────────────────────────────────────────────────
#
# 標準入力（フェンス除去済み）を読み、`|` で始まる行の連続ブロックごとに 1 行返す。
#
#   OK            ヘッダー行 + 区切り行で始まる正しい表
#   NO_SEPARATOR  区切り行を持たないブロック。分断で取り残された行がこれになる
#   NO_HEADER     区切り行で始まるブロック。ヘッダー行が失われた形
#
# 出力: KIND<TAB>ファイル<TAB>ブロック先頭の行番号<TAB>ブロック先頭の行内容
#
# ファイル名は呼び出し元が sed で差し込まず、ここで awk へ渡して出力させる。
# sed で `\t` を書くと BSD sed（macOS）がタブとして解釈せずリテラルの `t` として
# 扱い、差し込みが黙って失敗する。Linux でだけ緑になる差分を持ち込まない（#285）。
#
# 渡し方は -v ではなく環境変数経由（ENVIRON）にする。-v は代入値のエスケープ
# シーケンスを解釈するため、`\` を含むパス名が変形して報告される（`a\test.md` の
# `\t` がタブになる）。パス名は表示だけでなく指摘を追う手掛かりなので、変形させない。
# 改行を含むパス名を扱う判断は #273 で済んでいる。同じ基準を当てる。
#
# 行頭の空白を 3 つまで許すのは CommonMark に合わせるため。4 つ以上の字下げは
# コードブロックであって表ではない。
table_blocks() {
  md_file="$1" awk '
    BEGIN { file = ENVIRON["md_file"] }
    # 字下げの上限は 3 つ。4 つ以上はコードブロックであって表ではない（CommonMark）。
    # 間隔指定 {0,3} を使わず 4 通りを並べる。interval expression は awk 実装ごとに
    # 対応が分かれ（POSIX 以前の awk と一部の設定では無効）、無効な環境では
    # `{0,3}` が literal として扱われて表行を 1 つも検出できなくなる。macOS 実機で
    # 走らせる前提のリポジトリでこの差分を残さない（#285 と同じ形の欠陥になる）。
    # 行頭のタブは表行としない。タブ 1 つは 4 桁扱いでコードブロックになるため。
    function is_table(s) {
      return s ~ /^\|/ || s ~ /^ \|/ || s ~ /^  \|/ || s ~ /^   \|/
    }
    # 区切り行は `|` と `-` `:` 空白だけで構成され、`-` を最低 1 つ含む。
    function is_sep(s) {
      return is_table(s) && s ~ /^[[:space:]]*\|[[:space:]:|-]+$/ && s ~ /-/
    }
    function flush(   kind) {
      if (n == 0) return
      if (sep1) kind = "NO_HEADER"
      else if (n >= 2 && sep2) kind = "OK"
      else kind = "NO_SEPARATOR"
      printf "%s\t%s\t%d\t%s\n", kind, file, ln1, txt1
      n = 0
    }
    {
      if (is_table($0)) {
        n++
        if (n == 1) { ln1 = NR; txt1 = $0; sep1 = is_sep($0); sep2 = 0 }
        else if (n == 2) { sep2 = is_sep($0) }
      } else {
        flush()
      }
    }
    END { flush() }
  '
}

# base 配下のファイル一覧を走査し、欠陥ブロックだけを TSV で返す。
# 出力: KIND<TAB>ファイル<TAB>行番号<TAB>行内容
scan_files() {
  local base="$1" files="$2" f
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    outside_fences < "$base/$f" | table_blocks "$f" | grep -v '^OK	'
  done <<FILEEOF
$files
FILEEOF
}

# base 配下の正しい表の総数。解析が壊れて 0 件になったまま緑になるのを防ぐ。
count_ok_blocks() {
  local base="$1" files="$2" f total=0 n
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    n="$(outside_fences < "$base/$f" | table_blocks "$f" | grep -c '^OK	' || true)"
    total=$((total + n))
  done <<FILEEOF
$files
FILEEOF
  printf '%s' "$total"
}

# ── 現行ツリーでの検査 ────────────────────────────────────────────────────────

it "走査対象の .md を 1 件以上取得できる"
FILE_COUNT="$(printf '%s\n' "$SRC_FILES" | grep -c . || true)"
if [[ "$FILE_COUNT" -gt 0 ]]; then
  pass
else
  fail "git ls-files が 0 件を返した"
fi

# 解析が壊れて「表を 1 つも見つけられない」状態になると、以降の検査は対象ゼロで
# 無条件に通る偽の緑になる。まず正しい表を 1 つ以上見つけられることを要求する。
it "現行ツリーから正しい表を 1 つ以上検出できる"
OK_COUNT="$(count_ok_blocks "$REPO_ROOT" "$SRC_FILES")"
if [[ "$OK_COUNT" -gt 0 ]]; then
  pass
else
  fail "正しい表を 1 つも検出できなかった（解析が壊れている）"
fi

it "現行ツリーの .md に分断された表が無い"
DEFECTS="$(scan_files "$REPO_ROOT" "$SRC_FILES")"
if [[ -z "$DEFECTS" ]]; then
  pass
else
  fail "分断された表がある:
$DEFECTS"
fi

# ── 検査ロジック自身の検証 ────────────────────────────────────────────────────
#
# 現行ツリーが緑なのは「欠陥が無い」からであって「検査が動いている」証明ではない。
# 意図的に壊したフィクスチャで赤になることを別に示す。
#
# フィクスチャは追跡せずテンポラリへ作る。追跡すると、この検査自身の走査対象
# （git ls-files '*.md'）へ壊れた md が入り、現行ツリーの検査が落ちる。
FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-md-table-integrity.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# #289 で実際に混入した形。表の途中へ本文を挿入し、後続行が取り残される。
cat > "$FIXTURE_DIR/broken-289.md" <<'EOF'
# 見出し

| 役割 | 理由 |
|---|---|
| intake-manager | 窓口が複数あると追跡できない |
| planner | 計画の出力は親が全量を必要とする |

`planner` は当初サブエージェントとして定義していましたが、親担当へ移しました。
ではありません。
| reviewer | 第二意見は別ベンダーのモデルで取ります |

続きの本文。
EOF

it "#289 で混入した形（表の途中へ本文を挿入し後続行が取り残される）を検出する"
B289="$(scan_files "$FIXTURE_DIR" "broken-289.md")"
if printf '%s\n' "$B289" | grep -q '^NO_SEPARATOR	broken-289.md	10	'; then
  pass
else
  fail "10 行目の取り残された reviewer 行を NO_SEPARATOR として報告しない: $B289"
fi

# 区切り行を持たないブロック（表として描画されない `|` 行の集まり）。
cat > "$FIXTURE_DIR/no-separator.md" <<'EOF'
本文。

| a | b |
| 1 | 2 |

続き。
EOF

it '区切り行を持たない `|` 行ブロックを報告する'
NOSEP="$(scan_files "$FIXTURE_DIR" "no-separator.md")"
if printf '%s\n' "$NOSEP" | grep -q '^NO_SEPARATOR	no-separator.md	3	'; then
  pass
else
  fail "区切り行の無いブロックを報告しない: $NOSEP"
fi

# ヘッダー行が失われ、区切り行から始まる形。
cat > "$FIXTURE_DIR/no-header.md" <<'EOF'
本文。

|---|---|
| 1 | 2 |

続き。
EOF

it "ヘッダー行を持たない区切り行を報告する"
NOHEAD="$(scan_files "$FIXTURE_DIR" "no-header.md")"
if printf '%s\n' "$NOHEAD" | grep -q '^NO_HEADER	no-header.md	3	'; then
  pass
else
  fail "ヘッダー行の無い区切り行を報告しない: $NOHEAD"
fi

# 対照群: フェンス内の `|` 行。表の書き方を説明する文書がこの形になる。
cat > "$FIXTURE_DIR/fenced.md" <<'MDEOF'
本文。

```
| a | b |
| 1 | 2 |
```

入れ子のフェンス。

````markdown
```
| c | d |
```
| e | f |
````

続き。
MDEOF

it 'フェンス済みコードブロック内の `|` 行を報告しない（対照）'
FENCED="$(scan_files "$FIXTURE_DIR" "fenced.md")"
if [[ -z "$FENCED" ]]; then
  pass
else
  fail "フェンス内の行を報告した: $FENCED"
fi

# 対照群: 正しい表だけを含む文書。字下げ 3 つまでと、データ行の無い表も含める。
cat > "$FIXTURE_DIR/valid.md" <<'EOF'
# 見出し

| a | b |
|---|---|
| 1 | 2 |

段落を挟む。

| c | d |
| :-- | --: |
| 3 | 4 |

字下げ 3 つまでは表とみなす。

   | e | f |
   |---|---|
   | 5 | 6 |

データ行の無い表。

| g | h |
|-|-|
EOF

it "正しい表だけの文書は報告しない（対照）"
VALID="$(scan_files "$FIXTURE_DIR" "valid.md")"
if [[ -z "$VALID" ]]; then
  pass
else
  fail "正しい表を報告した: $VALID"
fi

it "対照の文書から正しい表を 4 つ検出する（見落としで緑になっていない）"
assert_eq "$(count_ok_blocks "$FIXTURE_DIR" "valid.md")" "4" "valid.md の OK ブロック数"

exit_with_result
