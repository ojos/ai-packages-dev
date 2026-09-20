#!/usr/bin/env bash
# 文書間の節名参照（`<パス>「<節名>」`）を機械照合し、指し先の節が実在しなくなったら
# 赤にする回帰テスト。
#
# 節名は文書間で書き写される。#256 で `.github/project-ai-rules.md` の
# `## @intake コマンド` を `## intake フロー` へ改名した際、`CLAUDE.md` と
# `.github/ISSUE_TEMPLATE/implementation.md` の 2 箇所が同時に追随を要した。
# 追随を忘れると、参照は「存在しない節」を指したまま残る。リンク切れと違い相対
# リンク検査には掛からず、目視でしか気づけない（issue #260）。
#
# 対象は追跡対象の *.md から docs/records/ と docs/archive/（履歴として当時の
# 表記を保存する層）を除いたもの。参照の書き方は 3 形が実在する。
#
#   1. バッククォート囲み: `path.md`「節名」 / `path.md` の「節名」
#   2. markdown リンク:     [label](path.md) の「節名」
#   3. 素のパス:            path.md「節名」
#
# ファイル名だけの短縮形（例: `REASON_CODES.md`）はパスとして解決できないため、
# 参照元ディレクトリからの相対解決 → リポジトリ内の basename（パス末尾）検索、の
# 順に解決する。basename が複数一致した場合は曖昧として赤にする。
#
# LC_ALL=C.UTF-8 を明示する。C ロケールでは `[^」]` のような否定ブラケットが
# マルチバイト文字をバイト単位で分解し、`「intake フロー」` のようにバイト境界が
# 重なる参照を取りこぼす（#252 と同じ類型）。
#
# 依存はコアユーティリティ（awk / sed / grep / comm）のみ。bash 3.2 互換を維持する
# （連想配列・mapfile を使わない）。

set -uo pipefail
export LC_ALL=C.UTF-8
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-doc-section-refs"

# 参照の抽出パターン。起点は `[A-Za-z0-9_./-]+\.md`?(の)?「[^」]+」だが、
# バッククォート囲み・markdown リンク・素のパスの 3 形を拾えるよう、先頭の
# バッククォートと markdown リンクの `](...)` も許容する。
# markdown リンクは `#アンカー` 付きの形も許す。許さないと
# `[label](path.md#section)「節名」` がパターンに一致せず、**抽出対象から丸ごと
# 落ちる**（検査されないのに緑になる。第二意見の指摘）。アンカーは解決の前に
# 落とす（指すファイルは同じで、節名の照合はこのテストが別に行う）。
REF_PATTERN='(`?[A-Za-z0-9_./-]+\.md`?|\[[^]]*\]\([A-Za-z0-9_./-]+\.md(#[^)]*)?\)) *の?「[^」]+」'

# ── 抽出 ──────────────────────────────────────────────────────────────────────

# extract_refs <base_dir> <改行区切りのファイル一覧（base_dir からの相対パス）>
#
# TSV（file<TAB>line<TAB>path<TAB>section）を標準出力へ書く。
extract_refs() {
  local base="$1" files="$2"
  local f line span pre section path
  printf '%s\n' "$files" | while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    while IFS=: read -r line span; do
      [[ -z "$line" ]] && continue
      # 「...」の直前までがパス部分、中身が節名。
      section="${span#*「}"
      section="${section%」}"
      pre="${span%「*}"
      # 抽出パターンは ` *の?「` を許しているため、パスと「」のあいだは
      # 「空白のみ」「の のみ」「空白 + の」「空白 + の + 空白」のどれも来る。
      # `% の` のように 1 形だけを決め打ちで剥がすと、剥がし残した文字がパスの
      # 一部として扱われ、実在する参照を「解決できない」＝偽の赤にする。
      # 空白 → の → 空白 の順に落として、並びと有無のどちらにも依存させない。
      pre="${pre%"${pre##*[! ]}"}"
      pre="${pre%の}"
      pre="${pre%"${pre##*[! ]}"}"
      if [[ "${pre:0:1}" == "[" ]]; then
        # markdown リンク: [label](path.md)
        # 最長一致（##）で最後の ( まで落とす。最短一致だと、ラベルに丸括弧を
        # 含む形（[説明（補足）](path.md)）でラベル側の ( で切れ、パスの代わりに
        # 「補足）](path.md」を掴む。
        path="${pre##*(}"
        path="${path%)}"
        # アンカーはファイルの位置ではなくファイル内の位置なので、パス解決の前に
        # 落とす。残すと path.md#anchor というファイルを探して解決できなくなる。
        path="${path%%#*}"
      else
        # バッククォート囲み・素のパス: 前後の `` ` `` は有無どちらもありうる。
        path="${pre#\`}"
        path="${path%\`}"
      fi
      printf '%s\t%s\t%s\t%s\n' "$f" "$line" "$path" "$section"
    done < <(grep -noE "$REF_PATTERN" "$base/$f")
  done
}

# ── 解決 ──────────────────────────────────────────────────────────────────────

# resolve_ref <base_dir> <参照元ファイル> <パス断片> <改行区切りの全 .md 一覧>
#
# 解決したパス（base_dir からの相対）を出力する。曖昧なら "AMBIGUOUS"、
# 解決できなければ何も出力しない。
resolve_ref() {
  local base="$1" src="$2" frag="$3" all_md="$4"
  local srcdir matches count
  srcdir="$(dirname "$src")"

  # 1. リポジトリルートからの相対パスとしてそのまま解決できるか。
  if [[ -f "$base/$frag" ]]; then
    printf '%s\n' "$frag"
    return
  fi

  # 2. 参照元ディレクトリからの相対パスとして解決できるか（`../` を含んでよい。
  #    ファイルシステムが `..` を解決するため正規化は不要）。
  if [[ -f "$base/$srcdir/$frag" ]]; then
    printf '%s\n' "$srcdir/$frag"
    return
  fi

  # 3. ファイル名だけの短縮形。リポジトリ内をパス末尾一致（basename を含む）で
  #    検索する。複数一致したら曖昧。
  # frag も -v ではなく環境変数で渡す。抽出パターンの文字クラス
  # （[A-Za-z0-9_./-]）はバックスラッシュを含まないため現状は化けようがないが、
  # 節名側（heading_exists）と渡し方を揃えておく。片方だけ -v のままだと、
  # 次に触る人が「こちらは -v でよい」と読む根拠が無い。
  matches="$(printf '%s\n' "$all_md" | FRAG_WANT="$frag" awk '
    BEGIN { frag = ENVIRON["FRAG_WANT"] }
    $0 == frag { print; next }
    {
      n = length($0) - length(frag) - 1
      if (n >= 0 && substr($0, n + 1) == "/" frag) print
    }
  ')"
  count="$(printf '%s\n' "$matches" | grep -c .)"
  if [[ "$count" -eq 1 ]]; then
    printf '%s\n' "$matches"
  elif [[ "$count" -gt 1 ]]; then
    printf 'AMBIGUOUS\n'
  fi
}

# ── 検証 ──────────────────────────────────────────────────────────────────────

# heading_exists <ファイル> <節名>
#
# 節名と一致する見出し行があるかを見る。ファイル全体の文字列検索にはしない。
# 見出しが改名・削除されても本文中に同じ語が残っていれば通ってしまい、
# 「節名の追随漏れを止める」というこのテストの目的そのものが成立しなくなる
# （偽の緑）。第二意見の指摘で判明した。
#
# 一致は「見出しテキストと完全一致」または「節名の直後に丸括弧の補足が続く形」で
# 見る。実文書には、丸括弧の補足を落として書き写す形が実在する（実測）。
#
#   参照 「Git identity」        → 見出し `## Git identity（コミット作者情報）`
#   参照 「受け入れ条件の二層」  → 見出し `## 受け入れ条件の二層（ローカル層 / 外部層）`
#
# 素の先頭一致は許さない。許すと「Git」が `## Git identity` を、「フロー」が
# `## フローチャート` を通してしまい、別の偽の緑が開く（第二意見の指摘）。
# 境界を丸括弧に限れば、上の 2 形だけを通しつつ、見出しの改名（先頭から変わる）は
# これまでどおり捕まる。後方一致・部分一致も許さない。
#
# 章番号は落としてから比べる。`## 12. 機構化の判断基準` / `### 4) 事後確認` の
# ように N. と N) の 2 形が実在し、参照側は番号を書かない。番号は節名の一部では
# なく位置の表示であり、追随の対象にしない。多階層（`## 12.3.4 節名`）も落とす。
#
# 節名は -v ではなく環境変数で awk へ渡す。-v の代入値はエスケープシーケンスとして
# 解釈されるため、節名にバックスラッシュが含まれると別の文字へ化けて比較が狂う
# （静かに MISMATCH になる）。ENVIRON 経由なら素通しで渡る。
heading_exists() {
  local file="$1" section="$2"
  SECTION_WANT="$section" awk '
    BEGIN { want = ENVIRON["SECTION_WANT"] }
    /^#+[ \t]+/ {
      line = $0
      sub(/^#+[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      bare = line
      sub(/^[0-9]+(\.[0-9]+)*[.)]?[ \t]+/, "", bare)
      if (line == want || bare == want) { found = 1; exit }
      # 丸括弧が続く形だけを通す。index(..., 1) で「先頭が <節名>（」を見る
      # （length() を使わないのは、awk 実装によって文字数とバイト数が食い違い、
      # マルチバイトの節名で境界を取り違えるため）。全角・半角の両方を許す。
      if (index(line, want "（") == 1 || index(bare, want "（") == 1) { found = 1; exit }
      if (index(line, want " (") == 1 || index(bare, want " (") == 1) { found = 1; exit }
      if (index(line, want "(") == 1 || index(bare, want "(") == 1) { found = 1; exit }
    }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

# 見出しではなく本文の一節を鉤括弧で引用している参照。票がスコープ外に置いた
# 「見出し以外への参照」で、見出し照合では拾えない。黙って通すと、見出しの改名で
# 本文に語だけが残った形（偽の緑）と区別が付かなくなるため、**ここに列挙した
# 組み合わせだけ**を本文一致で通し、それ以外は赤にする。
#
# 新しく本文一致が現れたら、参照を見出しへ直すか、理由を添えてここへ足すかを
# 選ぶことになる。件数が黙って増えない形にしておく。
#
# 形式: <参照元>\t<参照先>\t<引用文>
BODY_QUOTE_ALLOWLIST="packages/devcontainer-bootstrap/README.md	.ai-playbook/role-contracts/closer.md	既定の merge 方針は手動承認とする"

is_allowed_body_quote() {
  local src="$1" target="$2" section="$3"
  # -q を外し >/dev/null で EOF まで読ませる。BODY_QUOTE_ALLOWLIST は増える前提の
  # 許可リストで（上記コメント「件数が黙って増えない形にしておく」）、行数が
  # 増えたときに同じ SIGPIPE のリスクを持ち込まないため、他の箇所と書き方を揃える。
  printf '%s\n' "$BODY_QUOTE_ALLOWLIST" | grep -xF -- "$src	$target	$section" >/dev/null
}

# validate_ref <base_dir> <参照元ファイル> <行> <パス断片> <節名> <改行区切りの全 .md 一覧>
#
# TSV（status<TAB>src<TAB>line<TAB>target<TAB>section）を出力する。
# status は OK / MISMATCH / AMBIGUOUS / UNRESOLVED のいずれか。
validate_ref() {
  local base="$1" src="$2" line="$3" frag="$4" section="$5" all_md="$6"
  local target
  target="$(resolve_ref "$base" "$src" "$frag" "$all_md")"
  if [[ -z "$target" ]]; then
    printf 'UNRESOLVED\t%s\t%s\t%s\t%s\n' "$src" "$line" "$frag" "$section"
  elif [[ "$target" == "AMBIGUOUS" ]]; then
    printf 'AMBIGUOUS\t%s\t%s\t%s\t%s\n' "$src" "$line" "$frag" "$section"
  elif heading_exists "$base/$target" "$section"; then
    printf 'OK\t%s\t%s\t%s\t%s\n' "$src" "$line" "$target" "$section"
  elif is_allowed_body_quote "$src" "$target" "$section" && grep -qF -- "$section" "$base/$target"; then
    # 見出しではない引用として明示的に許可した組み合わせ。引用文そのものが消えたら
    # 赤にする（許可したのは「見出しでないこと」であって「消えてよいこと」ではない）。
    printf 'BODY\t%s\t%s\t%s\t%s\n' "$src" "$line" "$target" "$section"
  else
    printf 'MISMATCH\t%s\t%s\t%s\t%s\n' "$src" "$line" "$target" "$section"
  fi
}

# ── 現行ツリーでの検査 ──────────────────────────────────────────────────────

SRC_FILES="$(cd "$REPO_ROOT" && git ls-files '*.md' | grep -v '^docs/records/' | grep -v '^docs/archive/')"
ALL_MD="$(cd "$REPO_ROOT" && git ls-files '*.md')"

REFS="$(extract_refs "$REPO_ROOT" "$SRC_FILES")"
REF_COUNT="$(printf '%s\n' "$REFS" | grep -c .)"

# 抽出ロジックが壊れて 0 件になった場合、以降の検査は「検査対象ゼロ」で無条件に
# 通ってしまう偽の緑になる。まずここで 1 件以上を要求する。
it "現行ツリーから節名参照を 1 件以上抽出できる"
if [[ "$REF_COUNT" -gt 0 ]]; then
  pass
else
  fail "抽出できた参照が 0 件だった"
fi

it "3 形（バッククォート囲み・markdown リンク・素のパス）のいずれも抽出できている"
# 3 形を区別する専用パターンで、各形が現行ツリーに 1 件以上あることを個別に
# 確認する（extract_refs は 3 形を一本化して拾うため、装飾自体は結果に残らない）。
LINK_ONLY_PATTERN='\[[^]]*\]\([A-Za-z0-9_./-]+\.md\) *の?「[^」]+」'
BACKTICK_ONLY_PATTERN='`[A-Za-z0-9_./-]+\.md`? *の?「[^」]+」'
PLAIN_ONLY_PATTERN='(^|[^`[])[A-Za-z0-9_./-]+\.md *の?「[^」]+」'
count_form_matches() {
  local pattern="$1" f n total=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # 0 件は正常な結果であって失敗ではない（大半の .md は参照を持たない）。grep は
    # 0 件で終了コード 1 を返すため、|| true で受け流す。このテストは set -e を
    # 使っていないので現状は止まらないが、意図を式の上に出しておく。
    n="$(grep -coE "$pattern" "$REPO_ROOT/$f" || true)"
    total=$((total + n))
  done <<FILEEOF
$SRC_FILES
FILEEOF
  printf '%s' "$total"
}
HAS_BACKTICK="$(count_form_matches "$BACKTICK_ONLY_PATTERN")"
HAS_LINK="$(count_form_matches "$LINK_ONLY_PATTERN")"
HAS_PLAIN="$(count_form_matches "$PLAIN_ONLY_PATTERN")"
if [[ "$HAS_BACKTICK" -gt 0 && "$HAS_LINK" -gt 0 && "$HAS_PLAIN" -gt 0 ]]; then
  pass
else
  fail "backtick=$HAS_BACKTICK link=$HAS_LINK plain=$HAS_PLAIN のいずれかが 0 件"
fi

it "マルチバイト節名（intake フロー）を取りこぼさない"
# 行番号は決め打ちしない。CLAUDE.md へ 1 行足しただけで落ちるテストは、参照関係が
# 壊れていないのに赤を出す（tests/test-template-mirror.sh が抽出のアンカーに
# 行番号を使わないのと同じ理由）。見たいのは「この参照を抽出できたか」であって
# 「何行目にあるか」ではない。
# $REFS はリポジトリ全体から抽出した参照一覧で、リポジトリが育つほど伸びる。
# -q は最初の一致でパイプを閉じるため、producer（printf）が書き込み中に閉じられ
# SIGPIPE で死にうる。set -uo pipefail 下では判定が反転しかねないため、-q を外し
# >/dev/null で EOF まで読ませる。
if printf '%s\n' "$REFS" | grep -E "$(printf '^CLAUDE\\.md\t[0-9]+\t\\.github/project-ai-rules\\.md\tintake フロー$')" >/dev/null; then
  pass
else
  fail "CLAUDE.md の「intake フロー」参照を抽出できなかった"
fi

it "現行ツリーの全参照について指し先の節が実在する"
BROKEN=""
while IFS=$'\t' read -r src line frag section; do
  [[ -z "$src" ]] && continue
  result="$(validate_ref "$REPO_ROOT" "$src" "$line" "$frag" "$section" "$ALL_MD")"
  status="${result%%$'\t'*}"
  # BODY は許可リストへ明示した「見出しでない引用」。引用文が消えれば MISMATCH に
  # 落ちるので、通過させても検知は失われない。
  if [[ "$status" != "OK" && "$status" != "BODY" ]]; then
    BROKEN="${BROKEN}${result}
"
  fi
done <<REFSEOF
$REFS
REFSEOF
if [[ -z "$BROKEN" ]]; then
  pass
else
  fail "解決できない/不一致の参照がある: $BROKEN"
fi

# 票が棚卸しした短縮形（ファイル名だけでパスが解決できない）3 件。basename 解決で
# 個別に正しい実体へたどり着くことを名指しで確認する。
it "短縮形の参照が basename 解決で正しく解決される（3 件を個別確認）"
SHORT_FAILS=""
check_short() {
  local src="$1" line="$2" frag="$3" want="$4"
  local got
  got="$(resolve_ref "$REPO_ROOT" "$src" "$frag" "$ALL_MD")"
  if [[ "$got" != "$want" ]]; then
    SHORT_FAILS="${SHORT_FAILS}${src}:${line} ${frag} -> got='${got}' want='${want}'
"
  fi
}
check_short ".claude/skills/intake/SKILL.md" 20 "REASON_CODES.md" ".ai-playbook/intake/REASON_CODES.md"
check_short "docs/release/release-notes-ai-playbook.md" 137 "review-workflow.md" ".ai-playbook/review-workflow.md"
check_short "docs/release/release-notes-devcontainer-bootstrap.md" 36 "review-workflow.md" ".ai-playbook/review-workflow.md"
if [[ -z "$SHORT_FAILS" ]]; then
  pass
else
  fail "$SHORT_FAILS"
fi

# #322: 13 章「実装委譲パターン」は委譲する側（何を渡すか）までしか書いておらず、
# 統合する側（複数レーンを束ねる側）の実務が無かった。足した節が見出しごと
# 消えても検査が気づかない状態を避けるため、節の見出しと配下 6 項目の見出しを
# 個別に確認する。文面の正しさではなく、見出しの存在だけを見る（本文の妥当性は
# 機械判定できない）。
#
# grep -q は producer の書き込み中にパイプを閉じうる。set -uo pipefail 下では
# producer が SIGPIPE で死に、判定が反転しかねない（tests/test-pipefail-sigpipe.sh
# が検出する形と同じ）。producer はこのファイルの外にあり将来も伸びるため、
# 現時点でパイプバッファに収まっていることを理由に据え置かない。-q を外し、
# >/dev/null で EOF まで読ませる（同ファイルの書き方に合わせる）。
CHAPTER13_FILE="$REPO_ROOT/.ai-playbook/shared-ai-rules.md"
CHAPTER13_BODY="$(awk '/^## 13\./{flag=1} flag{print} /^## 14\./{exit}' "$CHAPTER13_FILE")"

it "shared-ai-rules.md 13 章に「統合する側の実務」の節がある"
if printf '%s\n' "$CHAPTER13_BODY" | grep -xF '### 統合する側の実務' >/dev/null; then
  pass
else
  fail "13 章に「### 統合する側の実務」の見出しが見つからない"
fi

# 「統合する側の実務」の**配下**だけを取り出す。13 章の本文全体を検索すると、6 項目の
# 見出しがどこにあっても（親節の外へ移されていても）一致してしまい、テスト名が
# 保証しているはずの親子関係を検査していないことになる（Copilot レビューの指摘）。
#
# 打ち切りは「####（4 個ちょうど）ではない見出し」ではなく、**レベル 1〜3 の見出しに
# 限定**する。「#### 以外の見出し行すべて」で切ると、レベル 5 以上の見出し
# （`##### `）だけでなく、コードブロック内の行頭コメント（`# 〜` のような、見出しと
# 区別が付かない行）でも打ち切ってしまい、正しい文書が赤になる（第二意見が実測で
# 確認）。区間指定 `{1,3}` は #296 の実測でこのリポジトリが対象とする 2 種類の awk
# （macOS の BWK awk / devcontainer の mawk）のどちらでも機能するため、移植性は
# 理由にならない（tests/test-md-table-integrity.sh の類例が既にそう書いている）。
# それでも列挙する（`/^#[ \t]/ || /^##[ \t]/ || /^###[ \t]/`）のは、区間指定より
# 「レベル 1〜3」という意図をそのまま読めるため。
#
# ただしレベル制限だけでは、コードブロック内の行頭コメントは直らない。
# `# コメント` はレベル 1 の見出しと文字面が区別できないため、レベル制限だけでは
# 依然として打ち切ってしまう。フェンス（``` で囲まれた範囲）の内外を追い、フェンス内
# では打ち切り判定そのものを行わない。フェンスの開閉判定は反転にしない。文書がフェンス
# の書き方を説明するために入れ子（外側を 4 個以上のバッククォートで囲む）を使うことが
# あり、反転だと内側の開始で外へ出たことになるため。開いたときの長さを覚え、それ以上の
# 長さの閉じだけを閉じとして扱う（CommonMark のフェンス規則。
# tests/test-md-table-integrity.sh の outside_fences() と同じ規則）。フェンス内の行は
# 空行へ置換して出力する。素通しすると、6 項目の見出しと同じ文字列をコード例として
# 書いただけで検査を誤って通す余地が残るため。
#
# 打ち切りは `exit` にしない。`exit` は awk の入力（このパイプの読み手）を EOF 前に
# 閉じ、producer（printf）が書き込み中なら SIGPIPE で死にうる（同じコミットで
# `grep -q` を外した理由と同じ問題を awk 側で作ってしまう）。フラグを落として
# 出力だけを止め、最後まで読む。
SECTION_BODY="$(printf '%s\n' "$CHAPTER13_BODY" | awk '
  function fence_len(s,   n) {
    sub(/^[[:space:]]*/, "", s)
    n = 0
    while (substr(s, n + 1, 1) == "`") n++
    return n
  }
  {
    fl = fence_len($0)
    if (fl >= 3) {
      if (!inside) { inside = 1; open_len = fl }
      else if (fl >= open_len && $0 ~ /^[[:space:]]*`+[[:space:]]*$/) { inside = 0 }
      if (found) print ""
      next
    }
    if (!found) {
      if ($0 == "### 統合する側の実務") found = 1
      next
    }
    if (!inside && ($0 ~ /^#[ \t]/ || $0 ~ /^##[ \t]/ || $0 ~ /^###[ \t]/)) {
      found = 0
      next
    }
    if (inside) print ""; else print
  }
')"

it "「統合する側の実務」節の配下に 6 項目の見出しが揃っている（節の外は数えない）"
REQUIRED_HEADINGS="#### 所有一覧の機械照合
#### 所有の定義
#### 波及先の洗い出し
#### 正本文書の扱い
#### 相乗りの防止
#### 報告を鵜呑みにしない"
MISSING_HEADINGS=""
while IFS= read -r h; do
  [[ -z "$h" ]] && continue
  if ! printf '%s\n' "$SECTION_BODY" | grep -xF "$h" >/dev/null; then
    MISSING_HEADINGS="${MISSING_HEADINGS}${h}
"
  fi
done <<HEADINGSEOF
$REQUIRED_HEADINGS
HEADINGSEOF
if [[ -z "$MISSING_HEADINGS" ]]; then
  pass
else
  fail "見出しが節の配下に無い（消えたか、親節の外にある）: $MISSING_HEADINGS"
fi

# ── フィクスチャでの負例検査（リポジトリの実ファイルは書き換えない） ────────

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-doc-section-refs.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# 曖昧化: 同じ basename を持つファイルが 2 つ存在する場合、短縮形は解決できず
# 曖昧として扱われることを確認する。
mkdir -p "$FIXTURE_DIR/ambiguous/src" "$FIXTURE_DIR/ambiguous/one" "$FIXTURE_DIR/ambiguous/two"
cat > "$FIXTURE_DIR/ambiguous/src/a.md" <<'EOF'
参照先は `shared.md`「対象節」を見よ。
EOF
cat > "$FIXTURE_DIR/ambiguous/one/shared.md" <<'EOF'
## 対象節

本文。
EOF
cat > "$FIXTURE_DIR/ambiguous/two/shared.md" <<'EOF'
## 対象節

本文。
EOF
AMBIG_ALL_MD="$(cd "$FIXTURE_DIR/ambiguous" && find . -name '*.md' | sed 's|^\./||')"
AMBIG_REFS="$(extract_refs "$FIXTURE_DIR/ambiguous" "src/a.md")"

it "basename が複数一致する参照は曖昧として赤になる（意図的な重複フィクスチャ）"
AMBIG_LINE="$(printf '%s\n' "$AMBIG_REFS" | head -n 1)"
if [[ -n "$AMBIG_LINE" ]]; then
  IFS=$'\t' read -r a_src a_line a_frag a_section <<< "$AMBIG_LINE"
  a_result="$(validate_ref "$FIXTURE_DIR/ambiguous" "$a_src" "$a_line" "$a_frag" "$a_section" "$AMBIG_ALL_MD")"
  a_status="${a_result%%$'\t'*}"
  assert_eq "$a_status" "AMBIGUOUS" "曖昧フィクスチャの判定"
else
  fail "フィクスチャから参照を抽出できなかった"
fi

# 不一致: 参照元は旧節名を書き写したまま、指し先の見出しだけ変わった状態を
# 意図的に作る（片方だけの改名を模す）。
mkdir -p "$FIXTURE_DIR/mismatch/src"
cat > "$FIXTURE_DIR/mismatch/src/a.md" <<'EOF'
参照先は `target.md`「旧節名」を見よ。
EOF
cat > "$FIXTURE_DIR/mismatch/target.md" <<'EOF'
## 新節名

本文。
EOF
MISMATCH_ALL_MD="$(cd "$FIXTURE_DIR/mismatch" && find . -name '*.md' | sed 's|^\./||')"
MISMATCH_REFS="$(extract_refs "$FIXTURE_DIR/mismatch" "src/a.md")"

it "節名を片方だけ変更すると赤になる（意図的な不一致フィクスチャ）"
MISMATCH_LINE="$(printf '%s\n' "$MISMATCH_REFS" | head -n 1)"
if [[ -n "$MISMATCH_LINE" ]]; then
  IFS=$'\t' read -r m_src m_line m_frag m_section <<< "$MISMATCH_LINE"
  m_result="$(validate_ref "$FIXTURE_DIR/mismatch" "$m_src" "$m_line" "$m_frag" "$m_section" "$MISMATCH_ALL_MD")"
  m_status="${m_result%%$'\t'*}"
  assert_eq "$m_status" "MISMATCH" "不一致フィクスチャの判定"
else
  fail "フィクスチャから参照を抽出できなかった"
fi

# 区切りの揺れ: パスと「」のあいだは、実文書に「の」付き・無し・空白ありの形が
# 混在する。どの形でもパス部分だけを取り出せないと、書き方の差だけで実在する
# 参照が「解決できない」＝偽の赤になる。4 形すべてを 1 つのフィクスチャに置く。
mkdir -p "$FIXTURE_DIR/separator/src"
cat > "$FIXTURE_DIR/separator/src/a.md" <<'EOF'
空白と の: `target.md` の「一致節」を見よ。
の のみ: `target.md`の「一致節」を見よ。
空白のみ: `target.md` 「一致節」を見よ。
区切り無し: `target.md`「一致節」を見よ。
EOF
cat > "$FIXTURE_DIR/separator/target.md" <<'EOF'
## 一致節

本文。
EOF
SEP_ALL_MD="$(cd "$FIXTURE_DIR/separator" && find . -name '*.md' | sed 's|^\./||')"
SEP_REFS="$(extract_refs "$FIXTURE_DIR/separator" "src/a.md")"

it "パスと「」のあいだの区切り（の / 空白 / 無し）に依存せず解決できる"
sep_total=0
sep_bad=0
while IFS=$'\t' read -r s_src s_line s_frag s_section; do
  [[ -z "$s_src" ]] && continue
  sep_total=$((sep_total + 1))
  s_result="$(validate_ref "$FIXTURE_DIR/separator" "$s_src" "$s_line" "$s_frag" "$s_section" "$SEP_ALL_MD")"
  s_status="${s_result%%$'\t'*}"
  if [[ "$s_status" != "OK" ]]; then
    echo "  $s_line 行目（frag='$s_frag'）が $s_status"
    sep_bad=1
  fi
done <<SEPEOF
$SEP_REFS
SEPEOF
if [[ "$sep_total" -eq 4 && "$sep_bad" -eq 0 ]]; then
  pass
else
  fail "4 形すべてを OK にできていない（抽出 $sep_total 件 / 失敗フラグ $sep_bad）"
fi

# 本文一致による偽の緑: 見出しが改名されても、本文に同じ語が残っていれば通って
# しまう形。ファイル全体の文字列検索で判定していると起きる。このテストが止める
# べき壊れ方そのものなので、両方向（本文だけ / 見出しあり）で固定する。
mkdir -p "$FIXTURE_DIR/bodyonly/src"
cat > "$FIXTURE_DIR/bodyonly/src/a.md" <<'EOF'
参照先は `target.md`「旧節名」を見よ。
EOF
cat > "$FIXTURE_DIR/bodyonly/target.md" <<'EOF'
## 新節名

この節はかつて 旧節名 と呼ばれていた。本文には語が残っている。
EOF
BODY_ALL_MD="$(cd "$FIXTURE_DIR/bodyonly" && find . -name '*.md' | sed 's|^\./||')"
BODY_REFS="$(extract_refs "$FIXTURE_DIR/bodyonly" "src/a.md")"

it "本文に節名が残っているだけでは通さない（見出し行で判定する）"
BODY_LINE="$(printf '%s\n' "$BODY_REFS" | head -n 1)"
if [[ -n "$BODY_LINE" ]]; then
  IFS=$'\t' read -r b_src b_line b_frag b_section <<< "$BODY_LINE"
  b_result="$(validate_ref "$FIXTURE_DIR/bodyonly" "$b_src" "$b_line" "$b_frag" "$b_section" "$BODY_ALL_MD")"
  assert_eq "${b_result%%$'\t'*}" "MISMATCH" "本文のみ一致の判定"
else
  fail "フィクスチャから参照を抽出できなかった"
fi

it "見出しの部分一致では通さない（`## ワークフロー` は「フロー」を満たさない）"
mkdir -p "$FIXTURE_DIR/partial/src"
cat > "$FIXTURE_DIR/partial/src/a.md" <<'EOF'
参照先は `target.md`「フロー」を見よ。
EOF
cat > "$FIXTURE_DIR/partial/target.md" <<'EOF'
## ワークフロー

本文。
EOF
PARTIAL_ALL_MD="$(cd "$FIXTURE_DIR/partial" && find . -name '*.md' | sed 's|^\./||')"
PARTIAL_REFS="$(extract_refs "$FIXTURE_DIR/partial" "src/a.md")"
PARTIAL_LINE="$(printf '%s\n' "$PARTIAL_REFS" | head -n 1)"
if [[ -n "$PARTIAL_LINE" ]]; then
  IFS=$'\t' read -r p_src p_line p_frag p_section <<< "$PARTIAL_LINE"
  p_result="$(validate_ref "$FIXTURE_DIR/partial" "$p_src" "$p_line" "$p_frag" "$p_section" "$PARTIAL_ALL_MD")"
  assert_eq "${p_result%%$'\t'*}" "MISMATCH" "見出しの部分一致の判定"
else
  fail "フィクスチャから参照を抽出できなかった"
fi

it "多階層の章番号付き見出しも番号を書かない参照で一致する"
mkdir -p "$FIXTURE_DIR/multinum/src"
cat > "$FIXTURE_DIR/multinum/src/a.md" <<'EOF'
参照先は `target.md`「機構化の判断基準」を見よ。
EOF
cat > "$FIXTURE_DIR/multinum/target.md" <<'EOF'
## 12.3.4 機構化の判断基準

本文。
EOF
MN_ALL_MD="$(cd "$FIXTURE_DIR/multinum" && find . -name '*.md' | sed 's|^\./||')"
MN_REFS="$(extract_refs "$FIXTURE_DIR/multinum" "src/a.md")"
MN_LINE="$(printf '%s\n' "$MN_REFS" | head -n 1)"
if [[ -n "$MN_LINE" ]]; then
  IFS=$'\t' read -r q_src q_line q_frag q_section <<< "$MN_LINE"
  q_result="$(validate_ref "$FIXTURE_DIR/multinum" "$q_src" "$q_line" "$q_frag" "$q_section" "$MN_ALL_MD")"
  assert_eq "${q_result%%$'\t'*}" "OK" "多階層章番号の判定"
else
  fail "フィクスチャから参照を抽出できなかった"
fi

it "章番号付きの見出しは番号を書かない参照でも一致する"
# `## 12. 機構化の判断基準` を「機構化の判断基準」と書き写す形が実在する。
# 番号は位置の表示であって節名の一部ではないため、追随の対象にしない。
mkdir -p "$FIXTURE_DIR/numbered/src"
cat > "$FIXTURE_DIR/numbered/src/a.md" <<'EOF'
参照先は `target.md`「機構化の判断基準」を見よ。
EOF
cat > "$FIXTURE_DIR/numbered/target.md" <<'EOF'
## 12. 機構化の判断基準

本文。
EOF
NUM_ALL_MD="$(cd "$FIXTURE_DIR/numbered" && find . -name '*.md' | sed 's|^\./||')"
NUM_REFS="$(extract_refs "$FIXTURE_DIR/numbered" "src/a.md")"
NUM_LINE="$(printf '%s\n' "$NUM_REFS" | head -n 1)"
if [[ -n "$NUM_LINE" ]]; then
  IFS=$'\t' read -r n_src n_line n_frag n_section <<< "$NUM_LINE"
  n_result="$(validate_ref "$FIXTURE_DIR/numbered" "$n_src" "$n_line" "$n_frag" "$n_section" "$NUM_ALL_MD")"
  assert_eq "${n_result%%$'\t'*}" "OK" "章番号付き見出しの判定"
else
  fail "フィクスチャから参照を抽出できなかった"
fi

it "節名が見出しの先頭に一致するだけでは通さない（境界は丸括弧に限る）"
# 「Git」が `## Git identity` を、「フロー」が `## フローチャート` を通すと、
# 別物の見出しを指したまま緑になる。
mkdir -p "$FIXTURE_DIR/prefix/src"
cat > "$FIXTURE_DIR/prefix/src/a.md" <<'EOF'
参照先は `target.md`「Git」を見よ。
EOF
cat > "$FIXTURE_DIR/prefix/target.md" <<'EOF'
## Git identity

本文。
EOF
PREFIX_ALL_MD="$(cd "$FIXTURE_DIR/prefix" && find . -name '*.md' | sed 's|^\./||')"
PREFIX_REFS="$(extract_refs "$FIXTURE_DIR/prefix" "src/a.md")"
PREFIX_LINE="$(printf '%s\n' "$PREFIX_REFS" | head -n 1)"
if [[ -n "$PREFIX_LINE" ]]; then
  IFS=$'\t' read -r x_src x_line x_frag x_section <<< "$PREFIX_LINE"
  x_result="$(validate_ref "$FIXTURE_DIR/prefix" "$x_src" "$x_line" "$x_frag" "$x_section" "$PREFIX_ALL_MD")"
  assert_eq "${x_result%%$'\t'*}" "MISMATCH" "境界の無い先頭一致の判定"
else
  fail "フィクスチャから参照を抽出できなかった"
fi

it "丸括弧の補足が続く見出しは通す（対照）"
mkdir -p "$FIXTURE_DIR/parenheading/src"
cat > "$FIXTURE_DIR/parenheading/src/a.md" <<'EOF'
参照先は `target.md`「Git identity」を見よ。
EOF
cat > "$FIXTURE_DIR/parenheading/target.md" <<'EOF'
## Git identity（コミット作者情報）

本文。
EOF
PH_ALL_MD="$(cd "$FIXTURE_DIR/parenheading" && find . -name '*.md' | sed 's|^\./||')"
PH_REFS="$(extract_refs "$FIXTURE_DIR/parenheading" "src/a.md")"
PH_LINE="$(printf '%s\n' "$PH_REFS" | head -n 1)"
if [[ -n "$PH_LINE" ]]; then
  IFS=$'\t' read -r h_src h_line h_frag h_section <<< "$PH_LINE"
  h_result="$(validate_ref "$FIXTURE_DIR/parenheading" "$h_src" "$h_line" "$h_frag" "$h_section" "$PH_ALL_MD")"
  assert_eq "${h_result%%$'\t'*}" "OK" "丸括弧付き見出しの判定"
else
  fail "フィクスチャから参照を抽出できなかった"
fi

it "アンカー付き markdown リンクも抽出し、アンカーを落として解決する"
# 抽出パターンがアンカーを許さないと、この形の参照は検査対象から丸ごと落ちる
# （検査していないのに緑になる）。
mkdir -p "$FIXTURE_DIR/anchor/src"
cat > "$FIXTURE_DIR/anchor/src/a.md" <<'EOF'
参照先は [説明](../target.md#anchor-name) の「一致節」を見よ。
EOF
cat > "$FIXTURE_DIR/anchor/target.md" <<'EOF'
## 一致節

本文。
EOF
ANCHOR_ALL_MD="$(cd "$FIXTURE_DIR/anchor" && find . -name '*.md' | sed 's|^\./||')"
ANCHOR_REFS="$(extract_refs "$FIXTURE_DIR/anchor" "src/a.md")"
ANCHOR_LINE="$(printf '%s\n' "$ANCHOR_REFS" | head -n 1)"
if [[ -n "$ANCHOR_LINE" ]]; then
  IFS=$'\t' read -r k_src k_line k_frag k_section <<< "$ANCHOR_LINE"
  k_result="$(validate_ref "$FIXTURE_DIR/anchor" "$k_src" "$k_line" "$k_frag" "$k_section" "$ANCHOR_ALL_MD")"
  assert_eq "${k_result%%$'\t'*}" "OK" "アンカー付きリンクの判定"
else
  fail "アンカー付きリンクを抽出できなかった"
fi

it "markdown リンクのラベルに丸括弧があってもパスを取り違えない"
# 最短一致でラベル側の ( を掴むと、パスの代わりに「補足）](path.md」を読む。
mkdir -p "$FIXTURE_DIR/parens/src"
cat > "$FIXTURE_DIR/parens/src/a.md" <<'EOF'
参照先は [説明（補足）](../target.md) の「一致節」を見よ。
EOF
cat > "$FIXTURE_DIR/parens/target.md" <<'EOF'
## 一致節

本文。
EOF
PAREN_ALL_MD="$(cd "$FIXTURE_DIR/parens" && find . -name '*.md' | sed 's|^\./||')"
PAREN_REFS="$(extract_refs "$FIXTURE_DIR/parens" "src/a.md")"
PAREN_LINE="$(printf '%s\n' "$PAREN_REFS" | head -n 1)"
if [[ -n "$PAREN_LINE" ]]; then
  IFS=$'\t' read -r r_src r_line r_frag r_section <<< "$PAREN_LINE"
  r_result="$(validate_ref "$FIXTURE_DIR/parens" "$r_src" "$r_line" "$r_frag" "$r_section" "$PAREN_ALL_MD")"
  assert_eq "${r_result%%$'\t'*}" "OK" "ラベルに丸括弧を含むリンクの判定"
else
  fail "フィクスチャから参照を抽出できなかった"
fi

# 対照群: フィクスチャの抽出・解決ロジック自体が全部赤を返す壊れた実装ではない
# ことを、節名が一致する正例で確認する。
mkdir -p "$FIXTURE_DIR/ok/src"
cat > "$FIXTURE_DIR/ok/src/a.md" <<'EOF'
参照先は `target.md`「一致節」を見よ。
EOF
cat > "$FIXTURE_DIR/ok/target.md" <<'EOF'
## 一致節

本文。
EOF
OK_ALL_MD="$(cd "$FIXTURE_DIR/ok" && find . -name '*.md' | sed 's|^\./||')"
OK_REFS="$(extract_refs "$FIXTURE_DIR/ok" "src/a.md")"

it "節名が一致するフィクスチャは緑になる（対照群）"
OK_LINE="$(printf '%s\n' "$OK_REFS" | head -n 1)"
if [[ -n "$OK_LINE" ]]; then
  IFS=$'\t' read -r o_src o_line o_frag o_section <<< "$OK_LINE"
  o_result="$(validate_ref "$FIXTURE_DIR/ok" "$o_src" "$o_line" "$o_frag" "$o_section" "$OK_ALL_MD")"
  o_status="${o_result%%$'\t'*}"
  assert_eq "$o_status" "OK" "一致フィクスチャの判定"
else
  fail "フィクスチャから参照を抽出できなかった"
fi

exit_with_result
