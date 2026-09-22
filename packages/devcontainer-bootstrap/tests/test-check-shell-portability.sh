#!/usr/bin/env bash
# 移植性検査（scripts/check-shell-portability.sh）を検証する。
#
# この検査は「CI では原理的に再現しない壊れ方」を綴りで見る検知層である。したがって
# 陽性（当たるべき入力で落ちる）だけでは足りない。**陰性（当たってはいけない入力で
# 通る）を対で見ないと、「常に落ちるだけの検査」と区別が付かない。**
#
# 逆向きも同じで、陰性だけでは「何も当たらない検査」と区別が付かない。この形は常に
# 緑を返すため、赤にならない限り誰も気づけない。**両方向を対にして固定する。**
#
# フィクスチャの綴りはこのファイル自身にも現れる。このリポジトリの
# scripts/check-shell-portability.sh は tests/ も自分自身も走査対象にするため、
# **フィクスチャの行には `# bsd-ok: 理由` を付ける**（除外ではなく印で通すのが、この
# 検査の方針そのものである）。印が**フィクスチャの中身へ入らない**よう、綴りは
# printf の引数として渡し、印はシェルの行コメントとして置く。入ると検査対象の側が
# 逃げ道で素通りし、陽性の検査が成立しなくなる。
#
# 使い捨てのリポジトリを 1 つ作り、フィクスチャを差し替えながら使う。判定対象が git の
# 追跡状態そのものなので git 管理下が要るが、毎回 bootstrap からやり直す必要は無い。
#
# ネットワークには出ない。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-check-shell-portability"

GIT_AS="git -c user.name=T -c user.email=t@example.com"
REL="scripts/check-shell-portability.sh"

BASE="$(new_workdir)/base"
run_bootstrap "$BASE" >/dev/null 2>&1

it "check-shell-portability.sh が常に生成され、実行可能である"
if [[ -f "$BASE/$REL" ]]; then
  assert_mode "$BASE/$REL" "755"
else
  fail "生成されていない: $BASE/$REL"
fi

new_repo() {
  local out
  out="$(new_workdir)/p"
  cp -R "$BASE" "$out"
  (
    cd "$out" || exit 1
    git init -q
    git symbolic-ref HEAD refs/heads/main
    git add -A
    $GIT_AS commit -q -m c1
  ) >/dev/null 2>&1
  printf '%s' "$out"
}

REPO="$(new_repo)"
mkdir -p "$REPO/pf"

CHECK_OUT=""
CHECK_RC=0
run_check() {
  local repo="${1:-$REPO}"
  CHECK_OUT="$(cd "$repo" && bash "$REL" 2>&1)"
  CHECK_RC=$?
}

# フィクスチャを 1 件だけ追跡させ、検査を回し、後始末する。
# 標準入力から本文を受ける（綴りを引数として渡すと、この行に綴りが現れてしまう）。
# 本文は $FIXBODY へ書いてから渡す。**パイプで渡してはいけない。** パイプの右側は
# サブシェルで走るため、CHECK_OUT / CHECK_RC が親へ返らず、陰性の検査が直前の結果を
# 見て素通りする（偽の緑。実際に一度そうなった）。
FIXBODY="$(new_workdir)/fixture-body"

probe() {
  local name="$1" ext="${2:-sh}"
  local path="pf/$name.$ext"
  cp "$FIXBODY" "$REPO/$path"
  ( cd "$REPO" && git add -f "$path" ) >/dev/null 2>&1
  run_check
  ( cd "$REPO" && git rm -q -f --cached "$path" ) >/dev/null 2>&1
  rm -f "$REPO/$path"
}

assert_detected() {
  local what="$1" kind="$2"
  if [[ "$CHECK_RC" -eq 0 ]]; then
    fail "$what: 落ちるべきところで通過した: $CHECK_OUT"
  elif ! printf '%s' "$CHECK_OUT" | grep -F 'SHELL_PORTABILITY_FAIL' >/dev/null; then
    fail "$what: SHELL_PORTABILITY_FAIL が出ていない: $CHECK_OUT"
  elif ! printf '%s' "$CHECK_OUT" | grep -F "[$kind]" >/dev/null; then
    fail "$what: 種別 $kind として報告されていない: $CHECK_OUT"
  else
    pass
  fi
}

assert_clean() {
  local what="$1"
  if [[ "$CHECK_RC" -ne 0 ]]; then
    fail "$what: 通るべきところで落ちた: $CHECK_OUT"
  elif ! printf '%s' "$CHECK_OUT" | grep -F 'SHELL_PORTABILITY_PASS' >/dev/null; then
    fail "$what: SHELL_PORTABILITY_PASS が出ていない: $CHECK_OUT"
  else
    pass
  fi
}

# ── 陰性の基準線 ─────────────────────────────────────────────────────────────

it "生成物そのままで SHELL_PORTABILITY_PASS（陰性の基準線）"
# これが通らないと、以降の陽性はすべて「常に落ちる検査」でも成立してしまう。
# 生成物には検査自身も含まれるので、**自分自身を走査して緑になること**もここで見る。
run_check
assert_clean "生成物そのまま"

# ── SED_BRACKET_TAB ─────────────────────────────────────────────────────────

it "ブラケット式の中の \`\\t\` を検出する（陽性）"
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' "sed -n 's/^[ \t]*x//p' f"                     # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe bracket-tab
assert_detected "ブラケット内のタブ" SED_BRACKET_TAB

it "文字クラスを挟んだブラケット式の中の \`\\t\` も検出する（陽性）"
# 素朴に ] を数えると閉じを取り違え、[[:space:]\t] の \t を外側と誤認して見落とす。
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' "sed -n 's/^[[:space:]\t]*x//p' f"             # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe bracket-tab-class
assert_detected "文字クラス入りのブラケット" SED_BRACKET_TAB

it "ブラケット式の外の \`\\t\` は検出しない（陰性・実測で否定された形）"
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' "sed 's/\t/X/' f"                              # bsd-ok: フィクスチャ
  printf '%s\n' "sed 's/x/a\nb/' f"                            # bsd-ok: フィクスチャ
  printf '%s\n' "awk '/^x{2,3}\$/ { print }' f"                # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe outside-tab
assert_clean "実測で否定された 3 形"

it "否定つきブラケット式の中の \`\\t\` も検出する（陽性）"
# `[^]` の ^ と、その直後の ] はリテラルで閉じではない。閉じと数えると見落とす。
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' "sed 's/[^]\t]/X/' f"                          # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe bracket-tab-negated
assert_detected "否定つきブラケット" SED_BRACKET_TAB

it "コメント行に書かれた綴りは検出しない（陰性）"
# 説明として書いた記述まで拾うと、「なぜ直したか」を書くほど赤が増える。
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s%s\n' '# ' "sed 's/[ \t]/X/' は BSD で壊れる"      # bsd-ok: フィクスチャ
  printf '%s%s\n' '#   ' 'grep -lZa も macOS には無い'          # bsd-ok: フィクスチャ
  printf '%s%s\n' '# ' 'd="$(mktemp -d)" と書いてはいけない'    # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe comment-only
assert_clean "コメント行の記述"

it "引用の外のコメントにアポストロフィがあっても以降がずれない（陽性）"
# コメント中の ' を引用の開きと数えると、以降の引用状態がずれ続け、次の行以降の
# 検出が丸ごと止まる（常に緑になる壊れ方）。
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' "# don't do this"                               # bsd-ok: フィクスチャ
  printf '%s\n' "sed 's/[ \t]/X/' f"                            # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe apostrophe
assert_detected "コメント中のアポストロフィの後" SED_BRACKET_TAB

it "パイプで連なる別コマンドの引数を sed のプログラムとみなさない（陰性）"
# 持ち主を行全体で決めると、grep の引数が sed のプログラムとして誤検知される。
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' "awk '/^a\$/ { print }' f | grep '[ \t]'"      # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe owner-pipeline
assert_clean "パイプ越しの持ち主の切り分け"

# ── GREP_DASH_Z_FLAG ────────────────────────────────────────────────────────

it "検索コマンドの -Z（GNU 拡張）を検出する（陽性）"
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'xargs -0 grep -l -Z -a -f "$P" -- < "$T"'     # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe grep-z
assert_detected "短縮オプション単独の Z" GREP_DASH_Z_FLAG

it "短縮オプションの塊に埋まった -Z も検出する（陽性）"
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'grep -lZa -f pattern.txt -- "$path"'          # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe grep-z-combined
assert_detected "塊に埋まった Z" GREP_DASH_Z_FLAG

it "小文字の -z・長いオプション名・無関係な -Z は検出しない（陰性）"
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'grep -z -f pattern.txt -- "$path"'            # bsd-ok: フィクスチャ
  printf '%s\n' 'grep --null -f pattern.txt -- "$path"'        # bsd-ok: フィクスチャ
  printf '%s\n' 'some-other-tool -Z "$path"'                   # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe grep-z-controls
assert_clean "Z の対照群 3 形"

# ── 規則表 ──────────────────────────────────────────────────────────────────
#
# 表の 11 規則それぞれについて、当たるべき綴りで落ちることを見る。1 件でも当たらなく
# なれば、その規則は「書いてあるだけ」になる。

rule_case() {
  local name="$1" body="$2"
  it "規則表: $name を検出する（陽性）"
  {
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' "$body"
  } > "$FIXBODY"
  probe "rule-$name"
  assert_detected "$name" RULE
}

rule_case mktemp     'd="$(mktemp -d)"'                                     # bsd-ok: フィクスチャ
rule_case date-ns    'stamp="$(date +%s%N)"'                                # bsd-ok: フィクスチャ
rule_case sed-hex    'sed "s/x/\x1b/" f'                                    # bsd-ok: フィクスチャ
rule_case grep-perl  'grep -P "\d+" f'                                      # bsd-ok: フィクスチャ
rule_case readlink-f 'readlink -f "$path"'                                  # bsd-ok: フィクスチャ
rule_case base64-w   'base64 -w 0 f'                                        # bsd-ok: フィクスチャ
rule_case find-printf 'find . -printf "%p\n"'                               # bsd-ok: フィクスチャ
rule_case xargs-r    'printf "" | xargs -r echo'                            # bsd-ok: フィクスチャ
rule_case head-neg   'head -n -1 f'                                         # bsd-ok: フィクスチャ
rule_case tac        'tac f > g'                                            # bsd-ok: フィクスチャ
rule_case ignorecase 'awk "BEGIN { IGNORECASE = 1 }" f'                     # bsd-ok: フィクスチャ

# sed -i は形の幅が広く、**最も頻出する「引用符で囲んだスクリプト」を当初見逃して
# いた**（第二意見の指摘。実測で確認した）。形ごとに個別に固定する。
sed_inplace_case() {
  local label="$1" body="$2"
  it "規則表: sed -i（$label）を検出する（陽性）"
  {
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' "$body"
  } > "$FIXBODY"
  probe "rule-sed-i-$label"
  assert_detected "sed -i $label" RULE                        # bsd-ok: 検査名に綴りが入るだけ
}

sed_inplace_case quoted    "sed -i 's/a/b/' f"                       # bsd-ok: フィクスチャ
sed_inplace_case dquoted   'sed -i "s/$v/b/" f'                      # bsd-ok: フィクスチャ
sed_inplace_case bsd-empty "sed -i '' 's/a/b/' f"                    # bsd-ok: フィクスチャ
sed_inplace_case suffix    'sed -i.bak s/a/b/ f'                     # bsd-ok: フィクスチャ
sed_inplace_case bare      'sed -i s/a/b/ f'                         # bsd-ok: フィクスチャ
sed_inplace_case other-opt 'sed -n -i -e s/a/b/ f'                   # bsd-ok: フィクスチャ

it "規則表: sed -i を伴わない sed は検出しない（陰性）"        # bsd-ok: 検査名に綴りが入るだけ
# -i を含む別のオプションや、-i を持たない呼び出しまで拾うと、正しい記述を
# 直そうとして戻す方向の修正を招く。
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' "sed -n 's/^- //p' f"                               # bsd-ok: フィクスチャ
  printf '%s\n' 'sed -E "s/a/b/" f'                                 # bsd-ok: フィクスチャ
  printf '%s\n' 'grep -i pattern f'                                 # bsd-ok: フィクスチャ
  printf '%s\n' 'parsed -i x'                                       # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe rule-sed-i-controls
assert_clean "sed -i の対照群"                                 # bsd-ok: 検査名に綴りが入るだけ

it "規則表: \\x の規則が、バックスラッシュの無い x を誤検出しない（陰性）"
# 規則は動的正規表現として評価される。エスケープの解釈が 1 段ずれると、
# `sed 's/x1/y/'` のような無関係な記述まで赤くなる（第二意見が疑った経路）。
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' "sed 's/x1/y/' f"                                   # bsd-ok: フィクスチャ
  printf '%s\n' "sed 's/exit/x/' f"                                 # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe rule-hex-controls
assert_clean "バックスラッシュの無い x"

it "規則表: 正しい綴りは検出しない（陰性）"
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'd="$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")"'   # bsd-ok: フィクスチャ
  printf '%s\n' 'run_with_mktemp;'                              # bsd-ok: フィクスチャ
  printf '%s\n' 'has_mktemp=true'                               # bsd-ok: フィクスチャ
  printf '%s\n' 'kids="$(pgrep -P $$ || true)"'                 # bsd-ok: フィクスチャ
  printf '%s\n' 'grep -E "[0-9]+" f'                            # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe rule-controls
assert_clean "規則表の対照群"

# ── PIPEFAIL_SIGPIPE ────────────────────────────────────────────────────────

it "判定に使っている早期終了パイプを検出する（陽性）"
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'if find . -name "*.md" | grep -q .; then :; fi'   # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe pipefail-cond
assert_detected "条件としての早期終了パイプ" PIPEFAIL_SIGPIPE

it "コマンド置換でも、終了コードを判定に使う形は検出する（陽性）"
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'if ! v="$(find . -type f | head -n 1)"; then :; fi'  # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe pipefail-subst-cond
assert_detected "条件の中のコマンド置換" PIPEFAIL_SIGPIPE

it "終了コードを読まない代入・文字列埋め込みは検出しない（陰性）"
# 判定が反転しようがない形。外さないと実害の無い代入が大量に赤くなり、検査が
# 読まれなくなる（この除外が無いと 1 リポジトリで 50 行が該当した）。
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'v="$(grep -n x f | head -n 1 | cut -d: -f1)"'                    # bsd-ok: フィクスチャ
  printf '%s\n' 'if grep -c x f > /dev/null; then echo "$(grep -n x f | head -1)"; fi'  # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe pipefail-unread
assert_clean "終了コードを読まない形"

it "プロセス置換の閉じ括弧がコマンド置換を閉じたことにならない（陰性）"
# 素の `(` を深さに数えないと、`<( … )` の閉じ括弧が外側の `$(` を閉じたことになり、
# 置換の中のパイプが「外にある」と誤判定される。
#
# **複数行の文字列の 2 行目で `$(` が開く形で書く。** 1 行に収めた
# `v="$(diff <(…) <(…) | head -5)"` では再現しない——その形は先に二重引用が開くため、
# 括弧を数えなくてもパイプが引用の中に入って拾われないからである。実際に踏んだのは
# `fail "…:` で始まる複数行の報告文で、2 行目が素の文脈から始まる形だった。
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'fail "食い違う:'                                  # bsd-ok: フィクスチャ
  printf '%s\n' '$(diff <(printf a) <(printf b) | head -5)"'      # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe pipefail-process-substitution
assert_clean "プロセス置換を含むコマンド置換"

it "行をまたぐコマンド置換の続きの行も、置換の中として扱う（陰性）"
# 1 行ずつ独立に読むと、前の行で開いた置換が見えず「置換の外」と誤判定される。
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'v="$(grep -n x f \'                                              # bsd-ok: フィクスチャ
  printf '%s\n' '  | head -n 1 | cut -d: -f1)"'                                   # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe pipefail-continuation
assert_clean "行継続をまたぐコマンド置換"

it "生産側が printf / echo の形は検出しない（陰性。行頭以外も）"
# 行頭だけを見る実装は elif ! printf … / [[ … ]] && ! printf … を取りこぼす
# （実測: 1 リポジトリで 143 行の偽陽性が出た）。
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'if printf "%s" "$k" | grep -qi secret; then :'                   # bsd-ok: フィクスチャ
  printf '%s\n' 'elif ! printf "%s" "$o" | grep -q PASS; then :'                  # bsd-ok: フィクスチャ
  printf '%s\n' 'elif [ -n "$n" ] && ! printf "%s" "$o" | grep -qF "$n"; then :'  # bsd-ok: フィクスチャ
  printf '%s\n' 'fi'
} > "$FIXBODY"
probe pipefail-safe-producer
assert_clean "printf / echo の生産側"

it "|| true でガードした形と、直した形は検出しない（陰性）"
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'first="$(find . -type d | head -n 1 || true)"'                   # bsd-ok: フィクスチャ
  printf '%s\n' 'if [ -z "$(find . -name "*.md" -print -quit)" ]; then :; fi'     # bsd-ok: フィクスチャ
  printf '%s\n' 'if git ls-remote origin | grep refs/tags/v1 >/dev/null; then :; fi'  # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe pipefail-fixed
assert_clean "ガード済みと修正後の形"

it "pipefail を宣言していないファイルでは検出しない（陰性）"
# この欠陥は pipefail が有効なときにしか起きない。宣言していないファイルまで赤に
# すると、直しようのない指摘になる。
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'if find . -name "*.md" | grep -q .; then :; fi'   # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe pipefail-absent
assert_clean "pipefail 無しのファイル"

# ── 逃げ道の印 ──────────────────────────────────────────────────────────────

it "理由付きの \`# bsd-ok:\` を付けた行は報告しない（陽性の裏）"
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s%s\n' 'readlink -f "$p" ' '# bsd-ok: 代替を別経路で用意済み'   # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe escape-marked
assert_clean "理由付きの逃げ道"

it "印の件数が報告に出る（付けたことが数として残る）"
if ! printf '%s' "$CHECK_OUT" | grep -E '逃げ道の印 [1-9][0-9]* 件' >/dev/null; then
  fail "逃げ道の印の件数が報告されていない: $CHECK_OUT"
else
  pass
fi

it "理由の無い \`# bsd-ok\` は逃げ道として認めない（陰性）"
# 印だけを付けて黙らせる形を残すと、逃げ道が「無効化のスイッチ」になる。
{
  printf '%s\n' 'set -euo pipefail'
  printf '%s%s\n' 'readlink -f "$p" ' '# bsd-ok:'                 # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe escape-empty
assert_detected "理由の無い印" RULE

# ── 文書（*.md）の扱い ──────────────────────────────────────────────────────

it "文書のフェンス内のコードは検出する（陽性）"
# README の導入手順は利用者のホストでそのまま実行される。
{
  printf '%s\n' '# 手順'
  printf '%s\n' '```bash'
  printf '%s\n' 'set -euo pipefail'
  printf '%s\n' 'd="$(mktemp -d)"'                               # bsd-ok: フィクスチャ
  printf '%s\n' '```'
} > "$FIXBODY"
probe doc-fenced md
assert_detected "フェンス内のコード" RULE

it "文書の地の文は検出しない（陰性）"
# 全文へ当てると、検査が文章の書き方に依存する。
{
  printf '%s\n' '素の `mktemp` は macOS で落ちる。'                # bsd-ok: フィクスチャ
  printf '%s\n' '`readlink -f` も BSD には無い。'                  # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe doc-prose md
assert_clean "地の文"

it "入れ子のフェンスで内外の判定がずれない（陰性）"
# 反転で判定すると内側の開始で外へ出たことになり、以降の内外がずれ続ける。
{
  printf '%s\n' '````markdown'
  printf '%s\n' '```bash'
  printf '%s\n' 'echo ok'
  printf '%s\n' '```'
  printf '%s\n' '````'
  printf '%s\n' '素の `mktemp` は macOS で落ちる。'                # bsd-ok: フィクスチャ
} > "$FIXBODY"
probe doc-nested md
assert_clean "入れ子フェンスの外の地の文"

# ── 検査が成立しないことを合格にしない ──────────────────────────────────────

it "git の作業ツリー外では落ちる（検査が成立しない）"
OUTSIDE="$(new_workdir)/outside"
mkdir -p "$OUTSIDE/scripts"
cp "$BASE/$REL" "$OUTSIDE/$REL"
OUT="$(cd "$OUTSIDE" && bash "$REL" 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]]; then
  fail "git 管理外で通過した: $OUT"
elif ! printf '%s' "$OUT" | grep -F 'SHELL_PORTABILITY_FAIL' >/dev/null; then
  fail "SHELL_PORTABILITY_FAIL が出ていない: $OUT"
else
  pass
fi

it "追跡している .sh / .md が 1 件も無ければ落ちる（対象ゼロを緑にしない）"
EMPTY="$(new_workdir)/empty"
mkdir -p "$EMPTY/scripts"
cp "$BASE/$REL" "$EMPTY/$REL"
( cd "$EMPTY" && git init -q && git symbolic-ref HEAD refs/heads/main ) >/dev/null 2>&1
OUT="$(cd "$EMPTY" && bash "$REL" 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]]; then
  fail "対象ゼロで通過した: $OUT"
elif ! printf '%s' "$OUT" | grep -F '1 件もありません' >/dev/null; then
  fail "対象ゼロを理由として報告していない: $OUT"
else
  pass
fi

# ── 自己診断（検査が壊れたことを検査が自分で言う）──────────────────────────

it "検出規則を無効化すると自己診断が落ちる（常に緑になる壊れ方を止める）"
# 規則表を空にすると「何も当たらない検査」になる。それは常に緑を返すので、
# 自己診断が無ければ赤にならない限り誰も気づけない。
BROKEN="$(new_repo)"
awk '
  /^cat > "\$RULES" <<.RULES_EOF.$/ { print; skip = 1; next }
  skip && /^RULES_EOF$/             { print; skip = 0; next }
  skip                              { next }
  { print }
' "$BASE/$REL" > "$BROKEN/$REL.tmp"
mv "$BROKEN/$REL.tmp" "$BROKEN/$REL"
OUT="$(cd "$BROKEN" && bash "$REL" 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]]; then
  fail "規則表を空にしても通過した（自己診断が成立していない）: $OUT"
elif ! printf '%s' "$OUT" | grep -F '自己診断に失敗しました' >/dev/null; then
  fail "自己診断の失敗として報告していない: $OUT"
else
  pass
fi

it "逃げ道の印の判定を壊すと自己診断が落ちる"
# 理由の有無を見なくすると、空の印が逃げ道として通ってしまう。
BROKEN2="$(new_repo)"
sed 's|^function has_bsd_ok(s) { return s ~ .*$|function has_bsd_ok(s) { return 0 }|' \
  "$BASE/$REL" > "$BROKEN2/$REL.tmp"
mv "$BROKEN2/$REL.tmp" "$BROKEN2/$REL"
OUT="$(cd "$BROKEN2" && bash "$REL" 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]]; then
  fail "逃げ道の判定を壊しても通過した: $OUT"
else
  pass
fi

exit_with_result
