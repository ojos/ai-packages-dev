#!/usr/bin/env bash
# BSD 系（macOS）で黙って壊れる sed / awk の書き方が追跡対象のシェルスクリプトに
# 無いことを検査する。
#
# CI は Linux でしか走らないため、このクラスの欠陥は原理的に CI をすり抜ける。
# #291 の実装 1 本だけで 3 件出た（うち 2 件は「#285 の再発防止を名乗る検査」自身に
# 入っていた）。3 件とも人の目でしか止まっていない。
#
# 先例は tests/test-mktemp-template.sh（BSD mktemp のテンプレート必須・#218）と
# tests/test-pipefail-sigpipe.sh（GNU/BSD find の EPIPE 差・#285）。本検査はその 3 つ目。
#
# ## 検出する 2 クラス（#294）
#
#   SED_TAB          sed のプログラム中の `\t`。BSD sed はタブとして解釈せず
#                    `\` と `t` の 2 文字として扱う。ブラケット式の中でも同じで、
#                    `[ \t]` は「空白・バックスラッシュ・t」の集合になる
#   SED_REPL_NEWLINE s/// の**置換側**の `\n`。BSD sed は改行として出力しない
#   AWK_INTERVAL     awk の正規表現の間隔指定 `{n,m}`。対応が実装ごとに分かれ、
#                    非対応の環境では literal 扱いになって照合が全滅する
#
# s/// の**パターン側**の `\n` は対象外とする。`/^$/N;/^\n$/D`（連続する空行の圧縮）は
# 広く使われる idiom で、パターン空間内の改行照合として動く。
# **この除外は実測に基づかない。** 手元に BSD sed が無く確認できていない。macOS で
# 確認できる機会があれば確認し、動かないと分かった場合はパターン側も対象へ入れる。
#
# `awk -v` のエスケープ解釈（代入値の `\t` がタブへ変わる）は検出対象に入れない。
# 追跡対象に 10 箇所あり大半が無害で、「任意の文字列を渡しているか」は機械判定でき
# ない。一律に落とすと動いているコードの書き換えを迫る。偽陽性は「正しい記述を直そう
# として戻す」方向の修正を招くため、検出漏れと同じくらい避ける（#294 スコープ外）。
#
# ## 判定の仕組み
#
# 対象の文字列がどのコマンドへ渡るかは、行単位の grep では決められない。awk / sed の
# プログラムは複数行にまたがる引用符の中に書かれ、コマンド名は先頭行にしか無いため。
# #291 の `{0,3}` も awk の呼び出しから 8 行下にあった。行単位の検査では捕まらない。
#
# そこでシェルの引用状態を追跡する。引用領域が開いた行のうち、引用符より前に awk /
# sed のトークンがあれば、その領域はそのコマンドのプログラムとみなす。領域は閉じ
# 引用符まで続き、途中の行もすべて同じ持ち主として扱う。
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

    # sed のプログラム text の中に、s/// の置換側の `\n` があるか。
    # 区切り文字は s の直後の 1 文字（英数字・空白・バックスラッシュ以外）。
    # `\` は次の 1 文字をエスケープする。
    function sed_repl_newline(t,   n, i, c, d, j, k, repl) {
      n = length(t)
      i = 1
      while (i <= n) {
        c = substr(t, i, 1)
        if (c == "s" && (i == 1 || substr(t, i - 1, 1) ~ /[^[:alnum:]_]/)) {
          d = substr(t, i + 1, 1)
          if (d != "" && d !~ /[[:alnum:][:space:]\\]/) {
            j = i + 2
            while (j <= n) {
              if (substr(t, j, 1) == "\\") { j += 2; continue }
              if (substr(t, j, 1) == d) break
              j++
            }
            if (j > n) { i++; continue }
            k = j + 1
            repl = ""
            while (k <= n) {
              if (substr(t, k, 1) == "\\") { repl = repl substr(t, k, 2); k += 2; continue }
              if (substr(t, k, 1) == d) break
              repl = repl substr(t, k, 1)
              k++
            }
            if (repl ~ /\\n/) return 1
            i = k + 1
            continue
          }
        }
        i++
      }
      return 0
    }

    BEGIN { state = "OUT"; owner = "" }
    {
      line = $0
      n = length(line)
      awk_text = ""
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
          if (owner == "awk") awk_text = awk_text c
          else if (owner == "sed") sed_text = sed_text c
          i++
          continue
        }
        # DQ
        if (c == "\\") {
          if (owner == "awk") awk_text = awk_text substr(line, i, 2)
          else if (owner == "sed") sed_text = sed_text substr(line, i, 2)
          i += 2
          continue
        }
        if (c == "\"") { state = "OUT"; owner = ""; i++; continue }
        if (owner == "awk") awk_text = awk_text c
        else if (owner == "sed") sed_text = sed_text c
        i++
      }

      # プログラム中のコメント行は対象外。行全体がコメントの場合だけ外す。
      if (is_comment(line)) next

      if (awk_text ~ /\{[0-9]+,[0-9]*\}/) printf "AWK_INTERVAL\t%d\t%s\n", NR, line
      if (sed_text ~ /\\t/)               printf "SED_TAB\t%d\t%s\n", NR, line
      if (sed_repl_newline(sed_text))     printf "SED_REPL_NEWLINE\t%d\t%s\n", NR, line
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

it "現行ツリーの .sh に BSD で壊れる sed / awk の記述が無い"
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
  fail "移植性の欠陥がある:
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

cat > "$FIXTURE_DIR/sed-tab.sh" <<EOF
sed -n 's/^[ ${TAB_ESC}]*x//p' f
sed 's/x/${TAB_ESC}/' f
EOF

cat > "$FIXTURE_DIR/sed-repl-newline.sh" <<EOF
sed 's/x/a${NL_ESC}b/' f
EOF

cat > "$FIXTURE_DIR/sed-pattern-newline.sh" <<EOF
sed '/^\$/N;/^${NL_ESC}\$/D' f
EOF

cat > "$FIXTURE_DIR/awk-inline.sh" <<EOF
awk '/^x$(iv 2,3)\$/ { print }' f
EOF

# #291 で実際に混入した形。awk の呼び出しから数行下に間隔指定がある。
cat > "$FIXTURE_DIR/awk-multiline.sh" <<EOF
awk -v file="\$1" '
  function is_table(s) { return s ~ /^[[:space:]]$(iv 0,3)\\|/ }
  { if (is_table(\$0)) print }
'
EOF

# awk -v q="'" の形。引用符の数え上げだけでは領域の内外がずれる。
cat > "$FIXTURE_DIR/awk-dq-quote.sh" <<EOF
awk -v q="'" '
  /x$(iv 1,2)/ { print }
'
EOF

cat > "$FIXTURE_DIR/comments.sh" <<EOF
# sed 's/x/${TAB_ESC}/' は BSD で壊れる
awk '
  # 間隔指定 $(iv 0,3) は使わない
  { print }
'
EOF

# 引用の外のコメント中のアポストロフィ。領域の開きと数えると以降がずれる。
cat > "$FIXTURE_DIR/apostrophe.sh" <<EOF
# don't do this
echo "x$(iv 0,3)y"
EOF

cat > "$FIXTURE_DIR/portable.sh" <<EOF
sed -n 's/^[[:space:]]*x//p' f
awk '/^x\$/ { print }' f
grep -c "$(iv 2,3)" f
EOF

# 指定した種別の報告行番号を空白区切りで返す。
detect() {
  portability_defects < "$FIXTURE_DIR/$1" | grep "^$2	" | cut -f2 | tr '\n' ' ' || true
}

it 'sed の `\t` をパターン側・置換側とも報告する'
LINES="$(detect sed-tab.sh SED_TAB)"
assert_eq "${LINES% }" "1 2" "SED_TAB の行番号"

it 'sed の s/// の置換側の `\n` を報告する'
LINES="$(detect sed-repl-newline.sh SED_REPL_NEWLINE)"
assert_eq "${LINES% }" "1" "SED_REPL_NEWLINE の行番号"

it 'sed の s/// のパターン側の `\n` は報告しない（対照）'
OUT="$(portability_defects < "$FIXTURE_DIR/sed-pattern-newline.sh")"
if [[ -z "$OUT" ]]; then pass; else fail "パターン側を報告した: $OUT"; fi

it 'awk の間隔指定を報告する（呼び出しと同一行）'
LINES="$(detect awk-inline.sh AWK_INTERVAL)"
assert_eq "${LINES% }" "1" "AWK_INTERVAL の行番号"

it 'awk の呼び出しから離れた行の間隔指定も報告する（#291 の形）'
LINES="$(detect awk-multiline.sh AWK_INTERVAL)"
assert_eq "${LINES% }" "2" "AWK_INTERVAL の行番号"

it '二重引用符を挟んで開く awk プログラムでも領域を見失わない'
LINES="$(detect awk-dq-quote.sh AWK_INTERVAL)"
assert_eq "${LINES% }" "2" "AWK_INTERVAL の行番号"

it 'コメント行の記述は報告しない（対照）'
OUT="$(portability_defects < "$FIXTURE_DIR/comments.sh")"
if [[ -z "$OUT" ]]; then pass; else fail "コメント行を報告した: $OUT"; fi

it '引用の外のコメントにアポストロフィがあっても以降がずれない（対照）'
OUT="$(portability_defects < "$FIXTURE_DIR/apostrophe.sh")"
if [[ -z "$OUT" ]]; then pass; else fail "領域がずれた: $OUT"; fi

it '可搬な書き方だけなら報告しない（対照）'
OUT="$(portability_defects < "$FIXTURE_DIR/portable.sh")"
if [[ -z "$OUT" ]]; then pass; else fail "可搬な記述を報告した: $OUT"; fi

# このファイル自身が悪い例を literal で持っていないことを固定する。持っていると
# 「現行ツリーの検査」が自分自身を拾って赤になる。組み立てを literal へ戻す変更を
# ここで止める。
# 同一行に別コマンドが連なる形。持ち主は最後のコマンド区切りより後ろで決める。
cat > "$FIXTURE_DIR/pipeline.sh" <<EOF
sed 's/a/b/' | grep 'x${TAB_ESC}y'
awk '/^a\$/ { print }' | sed 's/x/${TAB_ESC}/'
EOF

it 'パイプで連なる別コマンドの引数を sed のプログラムとみなさない（対照）'
LINES="$(detect pipeline.sh SED_TAB)"
assert_eq "${LINES% }" "2" "SED_TAB の行番号（1 行目の grep は対象外、2 行目の sed のみ）"

it '検査ファイル自身が悪い例を literal で持たない'
SELF="$(portability_defects < "$REPO_ROOT/tests/test-shell-portability.sh")"
if [[ -z "$SELF" ]]; then pass; else fail "自分自身が報告された: $SELF"; fi

exit_with_result
