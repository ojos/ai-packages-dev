#!/usr/bin/env bash
# 追跡対象のシェルスクリプトに、移植性を欠く綴りが無いことを検査する。踏んだ綴りを
# 見つけるたびにここへ検出を足していく運用（1 検査 = 1 綴り、ではなくこのファイルへ
# 集約する。個別の欠陥は SED_BRACKET_TAB / GREP_DASH_Z_FLAG のように別の KIND として
# 出す）。
#
# ══════════════════════════════════════════════════════════════════════════════
# SED_BRACKET_TAB: ブラケット式の中の `\t`
# ══════════════════════════════════════════════════════════════════════════════
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
# ══════════════════════════════════════════════════════════════════════════════
# GREP_DASH_Z_FLAG: grep -Z は GNU 拡張
# ══════════════════════════════════════════════════════════════════════════════
#
# `grep -Z`（該当ファイル名を NUL 区切りで返す）は GNU grep の拡張で、macOS / BSD の
# grep には無い。**この開発環境の grep（ugrep）は通ってしまうため、CI・手元のどちらも
# 気づけない。** macOS ではオプションエラーになり、対象ファイルがある正常なプロジェクト
# でも走査そのものが失敗する（scripts/check-control-chars.sh のコードレビューで
# 実際に指摘された綴り。同スクリプトは 1 ファイルずつ grep を呼ぶ形へ直し、-Z を
# 使わなくなっている）。
#
# 検出は「同じ行に `grep` という単語があり、かつ Z を含む短縮オプションの塊
# （`-Z` / `-lZa` 等、先頭が単一の `-` で残りがすべて英字）がある」ことで判定する。
# `--` で始まる長いオプション名は対象にならない（2 文字目が `-` になり、短縮
# オプションの塊の形に一致しないため）。全体を通した厳密な引数解析はしていない
# （SED_BRACKET_TAB と違い、同一行内の他コマンドとの持ち主の切り分けはしない）。
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

    # 行に grep コマンドがあり、かつ Z を含む短縮オプションの塊があるか
    # （GREP_DASH_Z_FLAG。冒頭のコメント参照）。
    function grep_z_flag(s) {
      if (s !~ /(^|[^[:alnum:]_.-])grep([[:space:]]|$)/) return 0
      return s ~ /(^|[[:space:]])-[A-Za-z]*Z[A-Za-z]*([[:space:]]|$)/
    }

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
      if (grep_z_flag(line)) printf "GREP_DASH_Z_FLAG\t%d\t%s\n", NR, line
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

# 現行ツリーを走査し、KIND ごとに欠陥を振り分ける（1 ファイルにつき
# portability_defects は 1 回だけ呼ぶ。ファイルごとに種別分だけ呼ぶと
# 走査の費用がその数に比例して増えるため）。
FOUND_BRACKET_TAB=""
FOUND_GREP_Z=""
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  out="$(portability_defects < "$REPO_ROOT/$f")"
  [[ -z "$out" ]] && continue
  bracket_tab_lines="$(printf '%s\n' "$out" | grep '^SED_BRACKET_TAB	' || true)"
  grep_z_lines="$(printf '%s\n' "$out" | grep '^GREP_DASH_Z_FLAG	' || true)"
  [[ -n "$bracket_tab_lines" ]] && FOUND_BRACKET_TAB="${FOUND_BRACKET_TAB}${f}
${bracket_tab_lines}
"
  [[ -n "$grep_z_lines" ]] && FOUND_GREP_Z="${FOUND_GREP_Z}${f}
${grep_z_lines}
"
done <<FILEEOF
$SRC_FILES
FILEEOF

it "現行ツリーの .sh にブラケット式の中の \`\\t\` が無い"
if [[ -z "$FOUND_BRACKET_TAB" ]]; then
  pass
else
  fail "ブラケット式の中の \`\\t\` がある:
$FOUND_BRACKET_TAB"
fi

it "現行ツリーの .sh に grep -Z（GNU 拡張）が無い"
if [[ -z "$FOUND_GREP_Z" ]]; then
  pass
else
  fail "grep -Z（GNU 拡張、macOS では通らない）がある:
$FOUND_GREP_Z"
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

# ── grep -Z（GREP_DASH_Z_FLAG）のフィクスチャ ────────────────────────────────

# 悪い例をこのファイルへ literal で書けない。追跡対象の .sh である以上、「現行ツリー
# の検査」が自分自身を走査して赤になる（bracket-tab.sh 系フィクスチャと同じ方針）。
# `Z` を変数で挟み、"grep" と `-Z` 形の並びがこのファイルの文字列として現れないよう
# 組み立てる。展開した結果だけが悪い例になる。
Z='Z'

# 検出したい形。コードレビューで実際に指摘された綴りそのもの
# （scripts/check-control-chars.sh が使っていた）。
cat > "$FIXTURE_DIR/grep-z.sh" <<EOF
xargs -0 grep -l -${Z} -a -f "\$PATTERN" -- < "\$TARGETS" > "\$SUSPECTS"
EOF

# 短縮オプションの塊の中に埋まった Z（先頭が -l ではなく -Z 単独でない形）も拾う。
cat > "$FIXTURE_DIR/grep-z-combined.sh" <<EOF
grep -l${Z}a -f pattern.txt -- "\$path"
EOF

# 対照: 小文字の -z（--null-data、NUL 区切り**入力**。-Z（--null、ファイル名の後に
# NUL）とは別の意味を持つ GNU 拡張だが、ここで検出したい綴りとは異なる）。
cat > "$FIXTURE_DIR/grep-lowercase-z.sh" <<'EOF'
grep -z -f pattern.txt -- "$path"
EOF

# 対照: 長いオプション名（--null）。短縮オプションの塊の形（先頭が単一の `-` で
# 残りが英字だけ）に一致しない。
cat > "$FIXTURE_DIR/grep-long-null.sh" <<'EOF'
grep --null -f pattern.txt -- "$path"
EOF

# 対照: grep を伴わない、無関係な -Z を含む行（別コマンドのオプション）。
cat > "$FIXTURE_DIR/unrelated-dash-z.sh" <<'EOF'
some-other-tool -Z "$path"
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

# ── grep -Z（GREP_DASH_Z_FLAG）──────────────────────────────────────────────

it 'grep -Z（GNU 拡張）を報告する'
assert_eq "$(detect grep-z.sh GREP_DASH_Z_FLAG)" "1 " "GREP_DASH_Z_FLAG の行番号"

it '短縮オプションの塊に埋まった -Z も報告する（-lZa の形）'
assert_eq "$(detect grep-z-combined.sh GREP_DASH_Z_FLAG)" "1 " "GREP_DASH_Z_FLAG の行番号"

it '小文字の -z は報告しない（対照。--null-data は別の意味を持つ拡張）'
expect_silent grep-lowercase-z.sh

it '長いオプション名 --null は報告しない（対照。短縮オプションの塊の形に一致しない）'
expect_silent grep-long-null.sh

it '検索コマンドを伴わない Z フラグは報告しない（対照）'
expect_silent unrelated-dash-z.sh

# このファイル自身が悪い例を literal で持っていないことを固定する。持っていると
# 「現行ツリーの検査」が自分自身を拾って赤になる。組み立てを literal へ戻す変更を
# ここで止める。
it '検査ファイル自身が悪い例を literal で持たない'
SELF="$(portability_defects < "$REPO_ROOT/tests/test-shell-portability.sh")"
if [[ -z "$SELF" ]]; then pass; else fail "自分自身が報告された: $SELF"; fi

exit_with_result
