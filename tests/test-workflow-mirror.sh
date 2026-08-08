#!/usr/bin/env bash
# 規範パッケージが配布する workflow 雛形と、この開発リポジトリが持つ写しが食い違って
# いないことを検査する。
#
#   正本: .ai-playbook/templates/*.yml（規範パッケージが配る実体そのもの）
#   写し: このリポジトリの .github/workflows/*（README の導入手順が示す置き先）
#
# 新設の理由: この 2 本は逐語の複製なのに一致を検査する仕組みが無く、雛形だけ直しても
# 写しだけ直しても全テストが緑になった。#227 が scripts/* に対して塞いだのと同じ形の
# 穴が .yml 側に残っていた（#250）。
#
# しかもこの 2 本は「リモート最終ゲートが要求されたか」を判定する機構そのものである。
# 写しがずれても緑になるということは、このリポジトリ自身のゲートが雛形と違う挙動を
# していても気づけないということにあたる。
#
# tests/test-template-mirror.sh へ相乗りせず別ファイルにした理由:
#
#   1. 正本の形が違う。あちらの正本は bootstrap.sh の get_template_content() 内
#      ヒアドキュメントで、抽出は case ラベルと cat <<'TMPL' のアンカーに依存する。
#      こちらの正本は独立したファイルで、抽出という工程がそもそも無い。同じファイルへ
#      2 種類の抽出を持たせると、以降のすべての照合が「どちらの経路で来たか」で分岐
#      する。
#   2. 網羅性の母集合が違う。あちらは bootstrap.sh が生成する一覧（template_rel_paths()）、
#      こちらは規範パッケージの雛形ディレクトリの実体。分類漏れを落とす対象が別なので、
#      1 ファイルへ混ぜると「新しい雛形をどちらの一覧へ足すのか」が読み取りにくくなる。
#   3. 落ちたときに直す先が違う。あちらは bootstrap.sh、こちらは規範パッケージの雛形と
#      .github/workflows/。テスト名で切り分けられるほうが次に踏んだ人を遠回りさせない。
#
# 対象を .yml に限る理由: 規範パッケージの雛形のうち、採用側が編集しないまま完成品と
# して使うのはこの 2 本だけである。他の雛形（entry.md / project-ai-rules.md /
# claude-skill-intake.md / gemini-review.sh）は導入先が自分の事情で書き換える前提で、
# 逐語一致は原理的に成立しない。実例として scripts/gemini-review.sh の写しは CLI の
# 導入手段を案内する 1 行だけ雛形と異なる（雛形側は特定の導入手段を持たないため）。
#
# 末尾改行の差も許容しない。両側が独立したファイルなので、コマンド置換を経由せず
# バイト比較できる（test-template-mirror.sh が末尾改行差を許容しているのは
# ヒアドキュメント抽出の制約で、こちらには当てはまらない）。
#
# 写しの置き先は決め打ちせず、.ai-playbook/README.md の導入手順（cp 行）から取る。
# 決め打ちにすると、規範側が置き先を変えたときに古い場所を見続けて緑のままになる。
# これは本テストが塞いでいる穴とまったく同じ形なので、同じ穴を自分で作らない。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-workflow-mirror"

TEMPLATES_DIR="$REPO_ROOT/.ai-playbook/templates"
README="$REPO_ROOT/.ai-playbook/README.md"

# 一致を必須にする雛形。写しとバイト一致すべきで、ずれたら追随漏れ。
MIRRORED_YMLS='copilot-review.yml
review-gate.yml'

# 検査対象外にする雛形。
#
# 除外が成立する条件は 1 つだけ:「このリポジトリがその workflow を採用していない」
# （＝ README の導入手順が示す置き先に写しが無い）。採用しているなら逐語の複製に
# なるはずで、バイト一致を免れる理由が無い。下の検査がこの条件を機械で守るので、
# 「採用しているが一致させたくない」ものをここへ入れても通らない。
#
# 現時点で該当は無い。追加するときは上記の条件を満たすことを確かめ、理由をここへ
# 併記する。除外は「検査していない」ではなく「検査対象外と判断した」ことを示す。
EXCLUDED_YMLS=''

# ── 抽出 ──────────────────────────────────────────────────────────────────────

# templates/ 直下の .yml 実体。サブディレクトリは今のところ無いが、増えても直下の
# ファイルだけを対象とする（README が並べているのは配置単位のファイル）。
ACTUAL_YMLS="$(find "$TEMPLATES_DIR" -maxdepth 1 -type f -name '*.yml' -exec basename {} \; | sort)"

# 分類の全体。空行を落とす。どちらかの一覧が空のとき、素朴に連結すると空行が
# 混ざって集合の突き合わせが濁る。
CLASSIFIED_YMLS="$(printf '%s\n%s\n' "$MIRRORED_YMLS" "$EXCLUDED_YMLS" | grep .)"

# README の導入手順から、雛形 <name> の置き先（リポジトリ相対）を取り出す。
#
#   cp .ai-playbook/templates/<name> <dest>   → <dest>
#   cp .ai-playbook/templates/<name> <dir>/   → <dir>/<name>
#
# 置き先が 1 つに定まらないとき（0 個、または複数）は空を返す。複数を黙って 1 つ
# 選ぶと、どの写しを照合しているのかが読めなくなる。
#
# 区切りは 1 個のスペース決め打ちにしない。スペースが 2 個やタブになっただけで
# 「置き先が取れない」と落ちると、README が正しいのにテストが赤くなる。
# 置き先は空白かバッククォートまでで切り、以降（インラインコード記法の閉じ、
# 行末コメント、`&& chmod +x` のような後続コマンド）は捨てる。
#
# `cp` と正本パスの間に短形オプション（`-f` / `-p` 等）が挟まっても取れるように
# 任意個読み飛ばす。要求しないと `cp -f .ai-playbook/templates/<name> <dest>` の
# ような記述で正規表現が一致せず count=0（置き先を一意に取れない）で赤くなる。
# README が正しいのにテストが赤くなる経路を、この関数の目的（そういう経路を
# 避けること）に反して自分で作ってしまう。
#
# バッククォートは変数で渡す。二重引用符の中へ直接書くとコマンド置換に化ける。
readme_dest() {
  local name="$1" name_re hits count dest bt='`'
  # 雛形名の . を正規表現のリテラルへ落とす。`.` を任意 1 文字のまま使うと、
  # 別の雛形の行を拾いうる（例: a-b.yml が a-byml にも一致する）。
  name_re="$(printf '%s' "$name" | sed 's/[.]/\\./g')"
  hits="$(sed -nE "s|^.*cp[[:space:]]+(-[A-Za-z]+[[:space:]]+)*\\.ai-playbook/templates/${name_re}[[:space:]]+([^[:space:]${bt}]+).*\$|\\2|p" "$README" \
    | grep . \
    | sort -u)"
  count="$(printf '%s\n' "$hits" | grep -c .)"
  [[ "$count" -eq 1 ]] || return 0
  dest="$hits"
  case "$dest" in
    */) dest="$dest$name" ;;
    # 末尾スラッシュ無しのディレクトリ指定（例: `cp ... .github/workflows`）。
    # 上の */ 分岐だけではこの形を取りこぼし、$dest がディレクトリのまま
    # 返って呼び出し側の `[[ -f "$copy" ]]` が「写しが無い」で偽陽性に赤くなる。
    # 実リポジトリでディレクトリとして存在するかを見て初めて判定できるので、
    # ここでは正規表現ではなく -d で確かめる。存在しなければ dest はそのまま
    # 残り、後続の -f 検査が正しく赤くする（fail-closed を弱めない）。
    *) [[ -d "$REPO_ROOT/$dest" ]] && dest="$dest/$name" ;;
  esac
  printf '%s\n' "$dest"
}

# ── 照合 ──────────────────────────────────────────────────────────────────────

it "規範パッケージから workflow 雛形を抽出できる"
# 抽出そのものが空になると、以降の照合は「空と空を比べて緑」になる。雛形の置き場所や
# 拡張子が変わったときに黙って無効化されないよう、先に抽出結果を検査する。
if [[ -n "$ACTUAL_YMLS" ]]; then
  pass
else
  fail "$TEMPLATES_DIR から *.yml の雛形を抽出できなかった"
fi

it "workflow 雛形がすべて一致必須か検査対象外のどちらかに分類されている"
# 分類漏れを機械で落とす。雛形を足したときに、どちらの一覧にも書かないまま
# 「検査されていないのか、対象外と判断したのか」が読めない状態になるのを防ぐ。
assert_same_set \
  "$ACTUAL_YMLS" \
  "$CLASSIFIED_YMLS" \
  "templates/ の実体" \
  "本テストの分類"

for name in $MIRRORED_YMLS; do
  src="$TEMPLATES_DIR/$name"

  it "$name の正本が workflow 定義の形をしている"
  # 空ファイルや別物を掴んだまま照合へ進むと、「空と空を比べて緑」や「別物同士が
  # 一致している」で通ってしまう。照合の前に正本そのものを見る。
  if [[ ! -f "$src" ]]; then
    fail "正本が見つからない: $src"
  elif [[ ! -s "$src" ]]; then
    fail "正本が空: $src"
  # 形の確認は jobs: だけで行う。name: は GitHub Actions では任意であり、
  # 持たない workflow 定義も仕様上正当なので、要求すると正本から name: を
  # 消しただけで偽陽性の赤になる。jobs: は必須キーなので、これが在ることを
  # もって「空ファイルでも別物でもない」は言える。
  elif ! grep -q '^jobs:' "$src"; then
    fail "正本に jobs: が無い（workflow 定義ではない可能性）: $src"
  else
    pass
  fi

  it "$name の置き先を README の導入手順から一意に取れる"
  dest_rel="$(readme_dest "$name")"
  if [[ -n "$dest_rel" ]]; then
    pass
  else
    fail "README の導入手順から 'cp .ai-playbook/templates/$name <置き先>' を一意に取れない（手順が消えたか、置き先が複数ある）"
    continue
  fi

  copy="$REPO_ROOT/$dest_rel"

  it "$name の写しが $dest_rel にある"
  if [[ -f "$copy" ]]; then
    pass
  else
    fail "README の導入手順が示す置き先に写しが無い: $copy"
    continue
  fi

  it "$name の正本と $dest_rel がバイト一致する"
  if [[ ! -s "$src" ]]; then
    fail "前段で正本の検査に失敗しているため照合できない"
  elif cmp -s "$src" "$copy"; then
    pass
  else
    detail="$(diff "$src" "$copy" | head -n 12 | tr '\n' '/')"
    fail "雛形と写しが食い違う（両方を同時に直す）: $detail"
  fi
done

for name in $EXCLUDED_YMLS; do
  it "$name が検査対象外である理由が保たれている（このリポジトリが採用していない）"
  # 除外理由は「採用していないので照合する写しが存在しない」の 1 点。写しが現れたら
  # その理由は成立せず、一致必須へ移すべき状態になっている。
  #
  # 置き先の候補は 2 つ見る。README の導入手順が示す先（取れた場合）と、workflow の
  # 慣行上の置き先 .github/workflows/<name>。ここで README の欠落を落とさないのは、
  # 採用していない雛形の導入手順が README に無いことは十分ありえるからで、そこで
  # 落とすと「非採用と分類した時点で必ず赤くなる」経路を作ってしまう。README が
  # 全雛形に触れているかは tests/test-template-catalog.sh が別に見ている。
  found=""
  dest_rel="$(readme_dest "$name")"
  if [[ -n "$dest_rel" && -e "$REPO_ROOT/$dest_rel" ]]; then
    found="$dest_rel"
  elif [[ -e "$REPO_ROOT/.github/workflows/$name" ]]; then
    found=".github/workflows/$name"
  fi
  if [[ -n "$found" ]]; then
    fail "$found に写しがあるのに検査対象外になっている（MIRRORED_YMLS へ移す）"
  else
    pass
  fi
done

exit_with_result
