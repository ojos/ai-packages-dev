#!/usr/bin/env bash
# ブラケット式の中の `\t` が追跡対象のシェルスクリプトに無いことを検査する。
#
# BSD 系（macOS）の sed は、**ブラケット式の中では** `\t` をタブとして解釈しない。
# `[ \t]` は「空白・バックスラッシュ・t」の集合になり、タブ字下げの行を取りこぼす。
# POSIX の規定どおり（ブラケット式の中でバックスラッシュは特殊な意味を失う）。
# CI は Linux でしか走らないため、この差分は原理的にすり抜ける。
#
# 先例は tests/test-mktemp-template.sh（BSD mktemp のテンプレート必須・#218）と
# tests/test-pipefail-sigpipe.sh（GNU/BSD find の EPIPE 差・#285）。本検査はその 3 つ目。
#
# ## 実測（#296）
#
# macOS 26.5.2 / /usr/bin/sed / /usr/bin/awk version 20200816 で測定した。
#
#   ブラケット内の \t   sed 's/[ \t]/X/'
#                        a<TAB>b -> 一致しない / atb -> aXb（literal の t に一致）
#                        => タブとして効かない。**本検査が拾うのはこれだけ**
#
# 次の 3 つは #294 で検出対象にしていたが、測定で否定されたので外した。実際の対象
# プラットフォーム（macOS の BWK awk / devcontainer の mawk）のどちらでも動く。
# **実測に合っていない検査は、動くコードの書き換えを迫るぶん、検査が無いより悪い。**
#
#   ブラケット外の \t   sed 's/\t/TAB/'      -> aTABb（タブとして効く）
#   置換側の \n         sed 's/x/a\nb/'      -> 2 行（改行になる）
#   awk の間隔指定       awk '/^x{2,3}$/'     -> xx に一致。対照: リテラルの
#                        x{2,3} には一致しない（間隔指定として機能している）
#
# パターン側の `\n`（`/^$/N;/^\n$/D` の形）も効くことを確認済み。
#
# 測定を残すのは、検出対象を広げたくなったときに同じ手順で確かめられるようにするため。
# 手順は #296 の本文にある。
#
# bash 3.2 互換を維持する（連想配列・mapfile を使わない）。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-shell-portability"

# 標準入力のシェルスクリプトを読み、移植性の欠陥を報告する。
# 出力: KIND<TAB>行番号<TAB>該当行
#
# 制限:
#   - 引用符で囲まないプログラム（`sed -e s/a/b/`）は対象外。この形は追跡対象に無い
#   - awk / sed のプログラム中のコメント行は対象外。説明として書いた記述まで拾うと、
#     検査が文章の書き方に依存する（test-mktemp-template.sh と同じ理由）
portability_defects() {
  awk '
    # 行頭（空白のみを挟む）が # のコメント行か。シェルにも awk にも同じ規則を当てる。
    function is_comment(s) { return s ~ /^[[:space:]]*#/ }

    # prefix に cmd のトークンがあるか。名前の一部（`gawk` の `awk` など）を拾わない
    # よう左境界を必須にする。
    function has_cmd(prefix, cmd) {
      return prefix ~ ("(^|[^[:alnum:]_.-])" cmd "([[:space:]]|$)")
    }

    # prefix のうち、最後のコマンド区切りより後ろだけを返す。
    #
    # prefix 全体を見ると、同一行で連結した別コマンドまで持ち主を引き継ぐ。
    # `sed '"'"'s/a/b/'"'"' | grep '"'"'x\ty'"'"'` の grep の引数が sed のプログラムとして
    # 誤検知され、`awk '"'"'x'"'"' | sed '"'"'y'"'"'` の sed は awk と誤判定される。
    # 区切りの後ろだけを見れば、いま開いた引用がどのコマンドのものかが決まる。
    #
    # 区切りが引用の中にある場合（`echo '"'"'a|b'"'"' '"'"'x'"'"'`）は切り出しがずれるが、
    # ずれた結果は持ち主が空になる方向なので、誤検知ではなく検出漏れになる。
    function last_segment(prefix,   i, c, cut) {
      cut = 0
      for (i = 1; i <= length(prefix); i++) {
        c = substr(prefix, i, 1)
        if (c == "|" || c == ";" || c == "&" || c == "(" || c == "`" || c == "{") cut = i
      }
      return substr(prefix, cut + 1)
    }

    # sed のプログラム text の中に、ブラケット式の中の `\t` があるか。
    #
    # POSIX ではブラケット式の中でバックスラッシュが特殊な意味を失うため、`[ \t]` は
    # 「空白・バックスラッシュ・t」の集合になる。ブラケットの外の `\t` は macOS 26 の
    # sed でもタブとして効くので拾わない（#296 の測定）。
    #
    # 文字クラス（`[:space:]` など）はブラケット式の中に `[` と `]` を持つ。素朴に
    # 数えると閉じを取り違え、`[[:space:]\t]` の `\t` を外側と誤認して見落とす。
    # `[:` を見つけたら `:]` まで飛ばす。
    #
    # 制限: 置換側の `[` も開きとして数える。`s/x/[\t]/` のような、置換文字列に
    # ブラケットを含む形は誤検知になる。s/// の構造まで解析していないため。この形は
    # 追跡対象に無く、出たときに構造解析を足す方が安い。
    function sed_bracket_tab(t,   n, i, c, inb, j) {
      n = length(t)
      i = 1
      inb = 0
      while (i <= n) {
        c = substr(t, i, 1)
        if (!inb) {
          if (c == "\\") { i += 2; continue }
          if (c == "[") {
            inb = 1
            i++
            # `[^` の ^ と、その直後の ] はリテラルで、閉じではない。
            if (substr(t, i, 1) == "^") i++
            if (substr(t, i, 1) == "]") i++
            continue
          }
          i++
          continue
        }
        # ブラケットの中。ここでは \ はリテラルなので、次の 1 文字を飛ばさない。
        if (c == "[" && substr(t, i + 1, 1) == ":") {
          j = index(substr(t, i), ":]")
          if (j > 0) { i = i + j + 1; continue }
        }
        if (c == "]") { inb = 0; i++; continue }
        if (c == "\\" && substr(t, i + 1, 1) == "t") return 1
        i++
      }
      return 0
    }

    BEGIN { state = "OUT"; owner = "" }
    {
      line = $0
      n = length(line)
      sed_text = ""
      i = 1
      while (i <= n) {
        c = substr(line, i, 1)
        if (state == "OUT") {
          # 引用の外の # 以降は行末までシェルのコメント。引用状態の追跡へ入れない
          # （`# don'"'"'t` のような行で領域が開いたことになり、以降がずれ続ける）。
          if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:]]/)) break
          if (c == "\\") { i += 2; continue }
          if (c == "'"'"'" || c == "\"") {
            prefix = last_segment(substr(line, 1, i - 1))
            # awk のプログラムは検査対象が無いが、持ち主として区別しておく。
            # 空にすると sed の直後に awk が続く行で領域を sed とみなしうる。
            if (has_cmd(prefix, "awk")) owner = "awk"
            else if (has_cmd(prefix, "sed")) owner = "sed"
            else owner = ""
            state = (c == "'"'"'") ? "SQ" : "DQ"
          }
          i++
          continue
        }
        if (state == "SQ") {
          # シングルクォートの中にエスケープは無い。次の '"'"' が必ず閉じ。
          if (c == "'"'"'") { state = "OUT"; owner = ""; i++; continue }
          if (owner == "sed") sed_text = sed_text c
          i++
          continue
        }
        # DQ
        if (c == "\\") {
          if (owner == "sed") sed_text = sed_text substr(line, i, 2)
          i += 2
          continue
        }
        if (c == "\"") { state = "OUT"; owner = ""; i++; continue }
        if (owner == "sed") sed_text = sed_text c
        i++
      }

      # プログラム中のコメント行は対象外。行全体がコメントの場合だけ外す。
      if (is_comment(line)) next

      if (sed_bracket_tab(sed_text)) printf "SED_BRACKET_TAB\t%d\t%s\n", NR, line
    }
  '
}

# ── 現行ツリーでの検査 ────────────────────────────────────────────────────────

SRC_FILES="$(cd "$REPO_ROOT" && git ls-files '*.sh')"

it "走査対象の .sh を 1 件以上取得できる"
FILE_COUNT="$(printf '%s\n' "$SRC_FILES" | grep -c . || true)"
if [[ "$FILE_COUNT" -gt 0 ]]; then
  pass
else
  fail "git ls-files が 0 件を返した"
fi

it "現行ツリーの .sh にブラケット式の中の \`\\t\` が無い"
FOUND=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  out="$(portability_defects < "$REPO_ROOT/$f")"
  [[ -n "$out" ]] && FOUND="${FOUND}${f}
${out}
"
done <<FILEEOF
$SRC_FILES
FILEEOF
if [[ -z "$FOUND" ]]; then
  pass
else
  fail "ブラケット式の中の \`\\t\` がある:
$FOUND"
fi


# ── 検査ロジック自身の検証 ────────────────────────────────────────────────────
#
# 現行ツリーが緑なのは「欠陥が無い」からであって「検査が動いている」証明ではない。
# 意図的に壊したフィクスチャで報告されることを別に示す。
#
# **悪い例をこのファイルへそのまま書けない。** 追跡対象の .sh である以上、上の
# 「現行ツリーの検査」が自分自身を走査して赤になる（実際に一度そうなった）。
# tests/test-mktemp-template.sh と同じ方針で、悪い例を組み立てて作る。ファイル上の
# 文字列としては一致せず、展開した結果だけが悪い例になる。
#
# フィクスチャはテンポラリの .sh へ書く。追跡すると同じ理由で走査対象へ入る。

BS='\'
TAB_ESC="${BS}t"   # 展開すると \t。この行に \t は現れない
NL_ESC="${BS}n"    # 展開すると \n
iv() { printf '{%s}' "$1"; }   # iv 0,3 -> {0,3}

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-shell-portability.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# 引用符を閉じないヒアドキュメントで書く。${TAB_ESC} や $(iv ...) を展開させるため。
# リテラルの $ は \$、リテラルのバックスラッシュは \\ と書く。

# 検出したい形。ブラケット式の中の \t。#294 が現行ツリーから掘り出した実欠陥と同じ形。
cat > "$FIXTURE_DIR/bracket-tab.sh" <<EOF
sed -n 's/^[ ${TAB_ESC}]*x//p' f
EOF

# 文字クラスを挟んだブラケット式。素朴に ] を数えると閉じを取り違えて見落とす。
cat > "$FIXTURE_DIR/bracket-tab-class.sh" <<EOF
sed -n 's/^[[:space:]${TAB_ESC}]*x//p' f
EOF

# 否定つきブラケットと、直後の ] がリテラルになる形。
cat > "$FIXTURE_DIR/bracket-tab-negated.sh" <<EOF
sed 's/[^]${TAB_ESC}]/X/' f
EOF

# ── 測定で否定された 3 形。いずれも報告しない（#296）──────────────────────────

cat > "$FIXTURE_DIR/outside-tab.sh" <<EOF
sed 's/${TAB_ESC}/X/' f
EOF

cat > "$FIXTURE_DIR/repl-newline.sh" <<EOF
sed 's/x/a${NL_ESC}b/' f
EOF

cat > "$FIXTURE_DIR/awk-interval.sh" <<EOF
awk '/^x$(iv 2,3)\$/ { print }' f
awk -v file="\$1" '
  function is_table(s) { return s ~ /^[[:space:]]$(iv 0,3)\\|/ }
  { if (is_table(\$0)) print }
'
EOF

# ── その他の対照 ────────────────────────────────────────────────────────────

cat > "$FIXTURE_DIR/comments.sh" <<EOF
# sed 's/[ ${TAB_ESC}]/X/' は BSD で壊れる
awk '
  # 間隔指定 $(iv 0,3) は使わない
  { print }
'
EOF

# 引用の外のコメント中のアポストロフィ。領域の開きと数えると以降がずれる。
cat > "$FIXTURE_DIR/apostrophe.sh" <<EOF
# don't do this
sed 's/[ ${TAB_ESC}]/X/' f
EOF

# 同一行に別コマンドが連なる形。持ち主は最後のコマンド区切りより後ろで決める。
cat > "$FIXTURE_DIR/pipeline.sh" <<EOF
awk '/^a\$/ { print }' | grep '[ ${TAB_ESC}]'
awk '/^a\$/ { print }' | sed 's/[ ${TAB_ESC}]/X/'
EOF

cat > "$FIXTURE_DIR/portable.sh" <<EOF
sed -n 's/^[[:space:]]*x//p' f
awk '/^x\$/ { print }' f
grep -c "[ ${TAB_ESC}]" f
EOF

# 指定した種別の報告行番号を空白区切りで返す。
detect() {
  portability_defects < "$FIXTURE_DIR/$1" | grep "^$2	" | cut -f2 | tr '\n' ' ' || true
}

# 報告が無いことを確かめる。
expect_silent() {
  local out
  out="$(portability_defects < "$FIXTURE_DIR/$1")"
  if [[ -z "$out" ]]; then pass; else fail "報告された: $out"; fi
}

it 'ブラケット式の中の `\t` を報告する'
assert_eq "$(detect bracket-tab.sh SED_BRACKET_TAB)" "1 " "SED_BRACKET_TAB の行番号"

it '文字クラスを挟んだブラケット式の中の `\t` も報告する'
assert_eq "$(detect bracket-tab-class.sh SED_BRACKET_TAB)" "1 " "SED_BRACKET_TAB の行番号"

it '否定つきブラケット式の中の `\t` も報告する'
assert_eq "$(detect bracket-tab-negated.sh SED_BRACKET_TAB)" "1 " "SED_BRACKET_TAB の行番号"

# ── 測定で否定された形は報告しない（#296 の実測 D / C / F・G）────────────────

it 'ブラケット式の外の `\t` は報告しない（対照・測定 D）'
expect_silent outside-tab.sh

it 's/// の置換側の `\n` は報告しない（対照・測定 C）'
expect_silent repl-newline.sh

it 'awk の間隔指定は報告しない（対照・測定 F / G）'
expect_silent awk-interval.sh

# ── 領域の追跡に関する対照 ──────────────────────────────────────────────────

it 'コメント行の記述は報告しない（対照）'
expect_silent comments.sh

it '引用の外のコメントにアポストロフィがあっても以降がずれない（対照）'
assert_eq "$(detect apostrophe.sh SED_BRACKET_TAB)" "2 " "SED_BRACKET_TAB の行番号"

it 'パイプで連なる別コマンドの引数を sed のプログラムとみなさない（対照）'
assert_eq "$(detect pipeline.sh SED_BRACKET_TAB)" "2 " "SED_BRACKET_TAB の行番号（1 行目の grep は対象外）"

it '可搬な書き方だけなら報告しない（対照）'
expect_silent portable.sh

# このファイル自身が悪い例を literal で持っていないことを固定する。持っていると
# 「現行ツリーの検査」が自分自身を拾って赤になる。組み立てを literal へ戻す変更を
# ここで止める。
it '検査ファイル自身が悪い例を literal で持たない'
SELF="$(portability_defects < "$REPO_ROOT/tests/test-shell-portability.sh")"
if [[ -z "$SELF" ]]; then pass; else fail "自分自身が報告された: $SELF"; fi

exit_with_result
