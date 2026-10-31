#!/usr/bin/env bash
# 共通規範（shared-ai-rules.md）から Claude Code 用の規則を生成する処理を検証する（#678）。
#
# 正本の見出しの印（<!-- claude-rules: name=<題> paths=<glob>,<glob> -->）に従い、印の無い
# 範囲を .claude/rules/ai-playbook.md（paths: なし）へ、印の範囲を
# .claude/rules/ai-playbook-<題>.md（paths: 付き、@ なし）へ生成する。--with-claude のとき
# だけ生成し、CLAUDE.md は共通規範の全文を取り込まない。
#
# 検査の柱:
#   1. 行の保存: 印の行を除いた正本の各行が、生成物のどれか 1 つにちょうど 1 回、正本と同じ
#      順序で現れる（規則へ分けても規範の中身が欠けず、重ならない）。
#   2. 条件付きの規則が paths: を持ち、@ の取り込みを含まない。
#   3. 壊れた印は、何も書かずに失敗する。
#   4. --with-claude の有無で CLAUDE.md が変わり、AGENTS.md・copilot-instructions.md は変わらない。
#   5. 生成物は既存の ORIGIN の仕組みに乗る（--upgrade で作り直し / .dcb-new）。
#
# ネットワークには出ない。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-claude-rules-generation"

TPL="$PLAYBOOK_SRC/templates"
MARK_RE='^<!-- claude-rules: name=[a-z0-9][a-z0-9-]* paths=[^ ]+ -->$'

# ── 道具 ──────────────────────────────────────────────────────────────────────

# render <正本> <出力ディレクトリ> — 生成の入口（--render-claude-rules）を呼ぶ。
render() { bash "$BOOTSTRAP" --render-claude-rules "$1" "$2"; }

# body_of <生成物> — 先頭の frontmatter と断りの行（「> 」で始まる行）と、その後の空行 1 つを
# 除いた、正本から写した本文を出す。断りは「> 生成物:」で始まる（この接頭辞だけで見分ける）。
body_of() {
  awk '
    state == 0 && /^---$/ { infm = !infm; next }
    infm { next }
    state == 0 && /^$/ { next }
    state == 0 && /^> 生成物:/ { state = 1; next }
    state == 0 { state = 2 }
    state == 1 && /^> / { next }
    state == 1 && /^$/ { state = 2; next }
    state == 1 { state = 2 }
    state == 2 { print }
  ' "$1"
}

# source_lines <正本> — 印の行を除いた正本の行を出す。
source_lines() { command grep -v -E "$MARK_RE" "$1"; }

# check_preserved <正本> <生成物ディレクトリ> — 行の保存を検査する。失敗した理由を標準出力へ出す。
#
# 空行の扱い: 空行は正本のどこにでもあり、「どの生成物のどの空行か」を 1 対 1 に対応づけられ
# ない。そこで、空行以外の行は厳密に（多重集合として一致 = ちょうど 1 回）見て、順序は
# 「各生成物の本文（空行を含む）が正本の部分列になっている」ことで見る。生成は各ファイルの
# 末尾の空行だけを落とすので、空行を含めた部分列の検査は生成の規則と矛盾しない。
check_preserved() {
  local src="$1" dir="$2" tmp f
  tmp="$(mktemp -d "$TEST_TMP_ROOT/pres.XXXXXX")"
  source_lines "$src" > "$tmp/src"
  : > "$tmp/all"
  for f in "$dir"/ai-playbook*.md; do
    [[ -f "$f" ]] || continue
    body_of "$f" > "$tmp/body"
    cat "$tmp/body" >> "$tmp/all"
    # 部分列: 本文の各行を、正本の前から順に探す。
    if ! awk 'NR == FNR { s[++n] = $0; next }
              { while (p < n && s[p + 1] != $0) p++; if (p >= n) { bad = 1; exit } p++ }
              END { exit bad }' "$tmp/src" "$tmp/body"; then
      printf '%s の本文が正本の部分列になっていない（順序の入れ替わり、または正本に無い行）' "$(basename "$f")"
      return 1
    fi
  done
  if ! diff <(command grep -v '^[[:space:]]*$' "$tmp/src" | sort) \
            <(command grep -v '^[[:space:]]*$' "$tmp/all" | sort) >"$tmp/diff"; then
    printf '空行以外の行が、ちょうど 1 回ずつ現れない: %s' "$(head -c 300 "$tmp/diff")"
    return 1
  fi
  if command grep -l 'claude-rules:' "$dir"/ai-playbook*.md >/dev/null 2>&1; then
    printf '印の行が生成物に残っている'
    return 1
  fi
}

# frontmatter <ファイル> — 先頭の --- から次の --- までの中身を出す（無ければ何も出さない）。
frontmatter() {
  awk 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit } { print }' "$1"
}

# has_import <ファイル> — @ の取り込み（行頭でも行の途中でも）を含むとき 0。メールアドレスと、
# バッククォートの中の @ は取り込みではない（tests/test-claude-rules.sh の check_no_import と同じ判定）。
has_import() {
  sed 's/`[^`]*`//g' "$1" | command grep -E '(^|[^A-Za-z0-9_.+-])@[A-Za-z0-9_./~-]+' >/dev/null
}

# ── フィクスチャ ──────────────────────────────────────────────────────────────

FIX="$(new_workdir)/shared-ai-rules.md"
cat > "$FIX" <<'MD'
# 共通規範

冒頭の常時の説明。連絡先は ido@example.com、書き方は `@パス` です。

## 1. 常時の章

常時の本文。

<!-- claude-rules: name=alpha paths=src/**,docs/*.md -->
## 2. 条件付きの章

条件付きの本文 A。

### 2.1 下位の見出し

下位の本文（印の範囲に含まれる）。

```
# コードの囲みの中の行は見出しではない
```

## 3. また常時の章

常時の本文 2。

### 3.1 常時の下位

常時の本文 3。

<!-- claude-rules: name=beta paths=lib/** -->
#### 3.1.1 深い見出しの条件付き

beta の本文。

<!-- claude-rules: name=alpha paths=src/**,docs/*.md -->
### 3.2 同じ題の 2 つ目

alpha の本文 B（同じ題はまとめる）。

## 4. 最後の常時の章

最後の本文。
MD

# ── 1. 生成の形 ───────────────────────────────────────────────────────────────

it "フィクスチャから、常時の規則と題ごとの条件付きの規則が生成される"
out="$(new_workdir)/rules"
names="$(render "$FIX" "$out")"
rc=$?
expected="$(printf 'ai-playbook.md\nai-playbook-alpha.md\nai-playbook-beta.md')"
if [[ "$rc" == "0" && "$names" == "$expected" && -f "$out/ai-playbook.md" && -f "$out/ai-playbook-alpha.md" && -f "$out/ai-playbook-beta.md" ]]; then
  pass
else
  fail "rc=$rc 出力=$names"
fi

it "常時の規則は paths: を持たない（frontmatter が無い）"
if [[ -z "$(frontmatter "$out/ai-playbook.md")" ]] && ! command grep -q '^paths:' "$out/ai-playbook.md"; then pass; else fail "常時の規則に paths: がある"; fi

it "条件付きの規則は paths: の配列を持つ（題ごとの glob を、印の順に）"
fm="$(frontmatter "$out/ai-playbook-alpha.md")"
want="$(printf 'paths:\n  - "src/**"\n  - "docs/*.md"')"
assert_eq "$fm" "$want" "alpha の frontmatter"

it "条件付きの規則に @ の取り込みを含まない（メールアドレスとバッククォート内の @ は取り込みではない）"
bad=""
for f in "$out"/ai-playbook-*.md; do has_import "$f" && bad="$bad $(basename "$f")"; done
if [[ -z "$bad" ]]; then pass; else fail "@ を含む:$bad"; fi

it "同じ題の印は 1 つの規則へ、正本の順序でまとまる"
a="$(body_of "$out/ai-playbook-alpha.md")"
if [[ "$a" == *"条件付きの本文 A"* && "$a" == *"alpha の本文 B"* && "${a%%条件付きの本文 A*}" != *"alpha の本文 B"* ]]; then pass; else fail "alpha の本文が揃っていない"; fi

it "印の範囲は、次の同じかより上の見出しの手前まで（下位の見出しを含み、コードの囲みの中の # は見出しにしない）"
if [[ "$a" == *"下位の本文（印の範囲に含まれる）"* && "$a" == *"コードの囲みの中の行は見出しではない"* ]] \
   && ! [[ "$(body_of "$out/ai-playbook.md")" == *"下位の本文"* ]]; then
  pass
else
  fail "範囲が正しくない"
fi

it "常時の範囲に、冒頭の H1 と印の無い章が入る"
al="$(body_of "$out/ai-playbook.md")"
if [[ "$al" == "# 共通規範"* && "$al" == *"## 3. また常時の章"* && "$al" == *"常時の本文 3"* && "$al" == *"最後の本文"* ]]; then pass; else fail "常時の範囲が欠けている"; fi

it "下位の見出しに印を付けると、そこで範囲が始まり、上の階層の見出しで常時へ戻る"
b="$(body_of "$out/ai-playbook-beta.md")"
if [[ "$b" == "#### 3.1.1"* && "$b" == *"beta の本文"* && "$al" != *"beta の本文"* ]]; then pass; else fail "beta の範囲が正しくない"; fi

it "条件付きの規則の先頭に、生成物である旨と、親の見出しを示す行がある"
head_a="$(sed -n '/^> /p' "$out/ai-playbook-alpha.md")"
head_b="$(sed -n '/^> /p' "$out/ai-playbook-beta.md")"
if [[ "$head_a" == *"生成物"* && "$head_a" == *"編集は正本"* && "$head_a" == *".ai-playbook/"* \
   && "$head_b" == *"親の見出し: 「3.1 常時の下位」の一部"* && "$head_a" != *"親の見出し: 「2."* ]]; then
  pass
else
  fail "断りの行が想定と違う: $head_a / $head_b"
fi

it "親の見出しは、印の見出しより上の階層で最も近い見出しになる（alpha は 2 つ目の印の親だけを示す）"
if [[ "$head_a" == *"親の見出し: 「3. また常時の章」の一部"* && "$head_a" != *"「2."* ]]; then pass; else fail "alpha の親の見出し: $head_a"; fi

# ── 2. 行の保存 ───────────────────────────────────────────────────────────────

it "フィクスチャ: 印の行を除いた正本の行が、生成物にちょうど 1 回、順序どおり現れる"
msg="$(check_preserved "$FIX" "$out")"; rc=$?
if [[ "$rc" == "0" ]]; then pass; else fail "$msg"; fi

it "実際の shared-ai-rules.md: 印の行を除いた正本の行が、生成物にちょうど 1 回、順序どおり現れる"
real_out="$(new_workdir)/real"
REAL_NAMES="$(render "$PLAYBOOK_SRC/shared-ai-rules.md" "$real_out")"
msg="$(check_preserved "$PLAYBOOK_SRC/shared-ai-rules.md" "$real_out")"; rc=$?
if [[ "$rc" == "0" ]]; then pass; else fail "$msg"; fi

it "実際の shared-ai-rules.md: 条件付きの規則はすべて paths: を持ち、@ の取り込みを含まない"
bad=""
for f in "$real_out"/ai-playbook-*.md; do
  [[ -n "$(frontmatter "$f")" ]] || bad="$bad paths無し:$(basename "$f")"
  has_import "$f" && bad="$bad @:$(basename "$f")"
done
if [[ -n "$(ls "$real_out"/ai-playbook-*.md 2>/dev/null)" && -z "$bad" ]]; then pass; else fail "$bad"; fi

it "実際の shared-ai-rules.md: 常時の規則が、実行時に要る手順を含む（13 章の委譲の判定と統合する側の実務を含み、16 章の台帳の項目は含まない）"
ra="$(cat "$real_out/ai-playbook.md")"
if [[ "$ra" == *"## 13. 実装委譲パターン"* && "$ra" == *"### 委譲の判定"* && "$ra" != *"### 台帳の項目"* && "$ra" == *"### 統合する側の実務"* ]]; then pass; else fail "常時の範囲が想定と違う"; fi

it "生成物の末尾が空行で終わらない（git diff --check に掛からない）"
bad=""
for f in "$real_out"/ai-playbook*.md "$out"/ai-playbook*.md; do
  [[ -n "$(tail -n 1 "$f" | tr -d '[:space:]')" ]] || bad="$bad $(basename "$f")"
done
if [[ -z "$bad" ]]; then pass; else fail "末尾が空行:$bad"; fi

# ── 3. 壊れた印 ───────────────────────────────────────────────────────────────

# expect_render_fail <説明> <正本の中身> <エラーに含まれる文字列>
expect_render_fail() {
  local what="$1" content="$2" needle="$3" src d err rc
  src="$(new_workdir)/src.md"
  d="$(new_workdir)/o"
  printf '%s\n' "$content" > "$src"
  it "$what"
  err="$(render "$src" "$d" 2>&1 >/dev/null)"; rc=$?
  if [[ "$rc" != "0" && "$err" == *"$needle"* && ! -e "$d" ]]; then
    pass
  else
    fail "rc=$rc 出力先=$([[ -e "$d" ]] && echo あり || echo なし) err=$err"
  fi
}

expect_render_fail "同じ題で paths が食い違うと、何も書かずに失敗する" \
"# t

<!-- claude-rules: name=a paths=x/** -->
## A

<!-- claude-rules: name=a paths=y/** -->
## B" "食い違"

expect_render_fail "印の直後が見出しでないと失敗する" \
"# t

<!-- claude-rules: name=a paths=x/** -->

## A" "見出しではありません"

expect_render_fail "書式の崩れた印（paths が無い）は失敗する" \
"# t

<!-- claude-rules: name=a -->
## A" "書式が不正"

expect_render_fail "題に大文字を使った印は失敗する" \
"# t

<!-- claude-rules: name=Abc paths=x/** -->
## A" "書式が不正"

expect_render_fail "ファイルの終わりに見出しの無い印があると失敗する" \
"# t

<!-- claude-rules: name=a paths=x/** -->" "直後に見出しがありません"

expect_render_fail "印のある節の中に別の印（入れ子）があると失敗する" \
"# t

<!-- claude-rules: name=a paths=x/** -->
## A

本文

<!-- claude-rules: name=b paths=y/** -->
### A.1

内側" "入れ子"

expect_render_fail "入れ子の印は、同じ題でも失敗する" \
"# t

<!-- claude-rules: name=a paths=x/** -->
## A

<!-- claude-rules: name=a paths=x/** -->
### A.1" "入れ子"

# 兄弟の印（外側の節が終わってから）は誤りではない。
it "同じ階層の見出しに続く印は入れ子ではない（兄弟）"
src="$(new_workdir)/sib.md"
printf '# t\n\n<!-- claude-rules: name=a paths=x/** -->\n## A\n\n本文\n\n<!-- claude-rules: name=b paths=y/** -->\n## B\n\n本文 B\n' > "$src"
if render "$src" "$(new_workdir)/o" >/dev/null 2>&1; then pass; else fail "兄弟の印が失敗した"; fi

expect_render_fail "paths に空の要素（a,,b）があると失敗する" \
"# t

<!-- claude-rules: name=a paths=x/**,,y/** -->
## A" "空の要素"

expect_render_fail "paths の末尾のカンマは失敗する" \
"# t

<!-- claude-rules: name=a paths=x/**, -->
## A" "空の要素"

expect_render_fail "paths に波括弧があると失敗する" \
"# t

<!-- claude-rules: name=a paths=src/{a,b}/** -->
## A" "使えない文字"

expect_render_fail "paths に二重引用符があると失敗する" \
"# t

<!-- claude-rules: name=a paths=x\"y -->
## A" "使えない文字"

expect_render_fail "paths にバックスラッシュがあると失敗する" \
"# t

<!-- claude-rules: name=a paths=x\\y -->
## A" "使えない文字"

expect_render_fail "印のつもりの行（<!-- の直後に空白が無い）は失敗する" \
"# t

<!--claude-rules: name=a paths=x/** -->
## A" "書式が不正"

expect_render_fail "印のつもりの行（行頭の空白）は失敗する" \
"# t

 <!-- claude-rules: name=a paths=x/** -->
## A" "書式が不正"

expect_render_fail "印のつもりの行（claude-rule: と綴りが崩れている）は失敗する" \
"# t

<!-- claude-rule: name=a paths=x/** -->
## A" "書式が不正"

expect_render_fail "印のつもりの行（大文字）は失敗する" \
"# t

<!-- Claude-Rules: name=a paths=x/** -->
## A" "書式が不正"

# コードの囲みは、開始の記号と長さを覚え、同じ記号で同じ長さ以上の行だけで閉じる。
it "バッククォート 4 つの囲みの中の ~~~ や短い囲みでは閉じず、その後の印の使用例は印として扱われない"
src="$(new_workdir)/fence.md"
cat > "$src" <<'MD'
# t

<!-- claude-rules: name=a paths=x/** -->
## A

````
```
~~~
<!-- claude-rules: name=a paths=y/** -->
# 囲みの中の見出し風の行
~~~~
````

## B

常時
MD
od="$(new_workdir)/o"
names="$(render "$src" "$od" 2>&1)"; rc=$?
if [[ "$rc" == "0" && "$names" == *"ai-playbook-a.md"* ]] \
   && command grep -F '囲みの中の見出し風の行' "$od/ai-playbook-a.md" >/dev/null \
   && ! command grep -F '常時' "$od/ai-playbook-a.md" >/dev/null \
   && command grep -F '常時' "$od/ai-playbook.md" >/dev/null; then
  pass
else
  fail "rc=$rc 出力=$names"
fi

it "閉じの記号が短い・別の種類の行は囲みを閉じない（開いたままなら、その中の印のような行は本文）"
src="$(new_workdir)/fence2.md"
printf '# t\n\n<!-- claude-rules: name=a paths=x/** -->\n## A\n\n~~~~\n~~~\n```\n<!-- claude-rules: name=b paths=y/** -->\n~~~~\n\n## B\n\n常時\n' > "$src"
od="$(new_workdir)/o"
if render "$src" "$od" >/dev/null 2>&1 && command grep -F 'name=b' "$od/ai-playbook-a.md" >/dev/null && command grep -F '常時' "$od/ai-playbook.md" >/dev/null; then pass; else fail "囲みの判定が CommonMark と違う"; fi

expect_render_fail "条件付きの規則へ写す本文に @ の取り込みがあると失敗する" \
"# t

<!-- claude-rules: name=a paths=x/** -->
## A

詳しくは @docs/guide.md を参照。" "@ の取り込み"

it "条件付きの本文でも、バッククォートの中の @ とメールアドレスは取り込みと見なさない（常時の範囲は対象外）"
src="$(new_workdir)/at.md"
printf '# t\n\n常時の @docs/x.md は対象外。\n\n<!-- claude-rules: name=a paths=x/** -->\n## A\n\n`@パス` と ido@example.com。\n' > "$src"
if render "$src" "$(new_workdir)/o" >/dev/null 2>&1; then pass; else fail "失敗した"; fi

it "paths にタブが入った印は失敗する（空白類全体を拒む）"
src="$(new_workdir)/tab.md"
printf '# t\n\n<!-- claude-rules: name=a paths=x/**\ty/** -->\n## A\n' > "$src"
err="$(render "$src" "$(new_workdir)/o" 2>&1 >/dev/null)"; rc=$?
if [[ "$rc" != "0" && "$err" == *"書式が不正"* ]]; then pass; else fail "rc=$rc err=$err"; fi

it "字下げ 0〜3 個の空白の見出しは見出しとして扱い（印の直後・節の終わり）、4 個以上は見出しにしない"
src="$(new_workdir)/indent.md"
printf '# t\n\n<!-- claude-rules: name=a paths=x/** -->\n   ## A\n\n本文 A\n\n    ## 4 個の字下げは見出しではない\n\n  ## B\n\n常時 B\n' > "$src"
od="$(new_workdir)/o"
if render "$src" "$od" >/dev/null 2>&1 \
   && command grep -F '4 個の字下げ' "$od/ai-playbook-a.md" >/dev/null \
   && ! command grep -F '常時 B' "$od/ai-playbook-a.md" >/dev/null \
   && command grep -F '常時 B' "$od/ai-playbook.md" >/dev/null; then pass; else fail "字下げ付きの見出しの判定が CommonMark と違う"; fi

it "印の直後が 4 個の字下げの行なら、見出しではないので失敗する"
src="$(new_workdir)/indent4.md"
printf '# t\n\n<!-- claude-rules: name=a paths=x/** -->\n    ## A\n' > "$src"
err="$(render "$src" "$(new_workdir)/o" 2>&1 >/dev/null)"; rc=$?
if [[ "$rc" != "0" && "$err" == *"見出しではありません"* ]]; then pass; else fail "rc=$rc err=$err"; fi

it "字下げ 3 個のコードの囲みも開始・終了として扱う"
src="$(new_workdir)/fence3.md"
printf '# t\n\n<!-- claude-rules: name=a paths=x/** -->\n## A\n\n   ```\n## 囲みの中\n   ```\n\n## B\n\n常時\n' > "$src"
od="$(new_workdir)/o"
if render "$src" "$od" >/dev/null 2>&1 && command grep -F '囲みの中' "$od/ai-playbook-a.md" >/dev/null && command grep -F '常時' "$od/ai-playbook.md" >/dev/null; then pass; else fail "字下げ付きの囲みの判定"; fi

it "--render-claude-rules は、今回生成しなかった生成物を消して名前を出し、手書きのものは残す"
src="$(new_workdir)/stale.md"
printf '# t\n\n<!-- claude-rules: name=a paths=x/** -->\n## A\n\n本文\n' > "$src"
od="$(new_workdir)/o"
render "$src" "$od" >/dev/null 2>&1
printf '# t\n\n常時だけ\n' > "$src"
printf -- '---\npaths:\n  - "z/**"\n---\n\n手書き\n' > "$od/ai-playbook-handmade.md"
out_rm="$(render "$src" "$od" 2>&1)"
if [[ ! -e "$od/ai-playbook-a.md" && -f "$od/ai-playbook-handmade.md" && -f "$od/ai-playbook.md" \
   && "$out_rm" == *"removed: ai-playbook-a.md"* && "$out_rm" != *"removed: ai-playbook-handmade.md"* ]]; then pass; else fail "出力=$out_rm"; fi

it "正本が無いと失敗する"
err="$(render "$(new_workdir)/none.md" "$(new_workdir)/o" 2>&1 >/dev/null)"; rc=$?
if [[ "$rc" != "0" && "$err" == *"見つかりません"* ]]; then pass; else fail "rc=$rc err=$err"; fi

it "--render-claude-rules に引数が足りないと失敗する"
err="$(bash "$BOOTSTRAP" --render-claude-rules "$FIX" 2>&1 >/dev/null)"; rc=$?
if [[ "$rc" != "0" && "$err" == *"2 つ"* ]]; then pass; else fail "rc=$rc err=$err"; fi

it "印の無い正本は、常時の規則 1 つだけになる"
src="$(new_workdir)/plain.md"; printf '# t\n\n## A\n\n本文\n' > "$src"
od="$(new_workdir)/o"
names="$(render "$src" "$od")"
if [[ "$names" == "ai-playbook.md" && ! -e "$od/ai-playbook-alpha.md" ]] && check_preserved "$src" "$od" >/dev/null; then pass; else fail "出力=$names"; fi

# ── 4. --with-claude の組み立て ───────────────────────────────────────────────

with="$(new_workdir)/p"
run_bootstrap "$with" --with-claude --with-playbook >/dev/null 2>&1
rc_with=$?
without="$(new_workdir)/p"
run_bootstrap "$without" --with-playbook >/dev/null 2>&1

it "--with-claude で、正本の印が決める規則がすべて生成される"
missing=""
for n in $REAL_NAMES; do [[ -f "$with/.claude/rules/$n" ]] || missing="$missing $n"; done
if [[ "$rc_with" == "0" && -n "$REAL_NAMES" && -z "$missing" ]]; then pass; else fail "rc=$rc_with 欠けた規則:$missing"; fi

it "生成した規則は --render-claude-rules の出力と一致する"
if diff -r "$real_out" "$with/.claude/rules" >/dev/null 2>&1; then pass; else fail "$(diff -r "$real_out" "$with/.claude/rules" 2>&1 | head -3)"; fi

it "--with-claude の CLAUDE.md が shared-ai-rules.md を取り込まず、project-ai-rules.md は取り込む"
if ! command grep -F '@.ai-playbook/shared-ai-rules.md' "$with/CLAUDE.md" >/dev/null \
   && command grep -qx '@.github/project-ai-rules.md' "$with/CLAUDE.md"; then pass; else fail "CLAUDE.md の取り込みが想定と違う"; fi

it "--with-claude の CLAUDE.md は entry.md と claude-entry-imports-rules.md をつなげたものと完全一致する"
if diff -q "$with/CLAUDE.md" <(cat "$TPL/entry.md" "$TPL/claude-entry-imports-rules.md") >/dev/null 2>&1; then pass; else fail "一致しない"; fi

it "--with-claude なしは今と同じ（規則を作らず、CLAUDE.md は共通規範の全文を取り込む）"
if [[ ! -e "$without/.claude" ]] \
   && diff -q "$without/CLAUDE.md" <(cat "$TPL/entry.md" "$TPL/claude-entry-imports.md") >/dev/null 2>&1 \
   && command grep -qx '@.ai-playbook/shared-ai-rules.md' "$without/CLAUDE.md"; then
  pass
else
  fail "--with-claude なしが変わっている"
fi

it "AGENTS.md・copilot-instructions.md は、--with-claude の有無によらず entry.md と同じ"
bad=""
for d in "$with" "$without"; do
  for f in AGENTS.md .github/copilot-instructions.md; do
    diff -q "$d/$f" "$TPL/entry.md" >/dev/null 2>&1 || bad="$bad $(basename "$d")/$f"
  done
done
if [[ -z "$bad" ]]; then pass; else fail "変わっている:$bad"; fi

it "規範の本体（.ai-playbook/shared-ai-rules.md）は全文のまま配置される"
if diff -q "$with/.ai-playbook/shared-ai-rules.md" "$PLAYBOOK_SRC/shared-ai-rules.md" >/dev/null 2>&1; then pass; else fail "正本と違う"; fi

it "規範を配置しない --with-claude は、規則を作らない"
nopb="$(new_workdir)/p"
run_bootstrap "$nopb" --with-claude --without-playbook >/dev/null 2>&1
assert_file_absent "$nopb/.claude/rules"

it "規則の生成物が ORIGIN に記録される（--dry-run の計画にも出る）"
rec_missing=""
for n in $REAL_NAMES; do
  command grep -q "^hash:.claude/rules/$n=" "$with/.devcontainer/ORIGIN" || rec_missing="$rec_missing $n"
done
plan="$(run_bootstrap "$(new_workdir)/dry" --with-claude --with-playbook --dry-run 2>/dev/null)"
plan_missing=""
for n in $REAL_NAMES; do [[ "$plan" == *".claude/rules/$n"* ]] || plan_missing="$plan_missing $n"; done
if [[ -z "$rec_missing" && -z "$plan_missing" ]]; then pass; else fail "ORIGIN に無い:$rec_missing 計画に無い:$plan_missing"; fi

it "古い規範（claude-entry-imports-rules.md が無い）では、規則を作らず従来どおり全文を取り込む"
oldpb="$(new_workdir)/pb"
cp -R "$PLAYBOOK_SRC" "$oldpb"
rm -f "$oldpb/templates/claude-entry-imports-rules.md"
legacy="$(new_workdir)/p"
run_bootstrap "$legacy" --with-claude --playbook-from "$oldpb" >/dev/null 2>&1
rc=$?
if [[ "$rc" == "0" && ! -e "$legacy/.claude/rules" ]] \
   && diff -q "$legacy/CLAUDE.md" <(cat "$TPL/entry.md" "$TPL/claude-entry-imports.md") >/dev/null 2>&1; then
  pass
else
  fail "rc=$rc"
fi

it "正本の印が壊れていると、何も書かずに止まる"
badpb="$(new_workdir)/pb"
cp -R "$PLAYBOOK_SRC" "$badpb"
printf '\n<!-- claude-rules: name=x -->\n## 壊れた印\n' >> "$badpb/shared-ai-rules.md"
badout="$(new_workdir)/p"
err="$(run_bootstrap "$badout" --with-claude --playbook-from "$badpb" 2>&1 >/dev/null)"; rc=$?
written="$( [[ -d "$badout" ]] && find "$badout" -type f | wc -l | tr -d ' ' || echo 0)"
if [[ "$rc" == "1" && "$written" == "0" && "$err" == *"書式が不正"* ]]; then pass; else fail "rc=$rc 書いた数=$written err=$err"; fi

# ── 5. glob の実在 ────────────────────────────────────────────────────────────

# 条件付きの規則の paths: の glob が、生成したプロジェクトの追跡対象のファイルに 1 つ以上
# 一致すること。綴りの誤りで規則が黙って載らなくなるのを防ぐ。数え方は
# tests/test-claude-rules.sh と同じ（git ls-files の ":(glob)" 指定）。生成したプロジェクトを
# そのまま git リポジトリにして数える（このあとの検査は $with を使わない）。
( cd "$with" && git init -q && git add -A ) >/dev/null 2>&1

# glob_matches <ルート> <glob> — glob に一致する追跡対象のファイルの数。
glob_matches() {
  git -C "$1" ls-files -- ":(glob)$2" | wc -l | tr -d ' '
}

it "生成したプロジェクトで、条件付きの規則の各 glob が実在のファイルに 1 つ以上一致する"
nomatch=""
count=0
for f in "$with"/.claude/rules/ai-playbook-*.md; do
  while IFS= read -r g; do
    [[ -n "$g" ]] || continue
    g="${g#\"}"; g="${g%\"}"
    count=$((count + 1))
    [[ "$(glob_matches "$with" "$g")" -ge 1 ]] || nomatch="$nomatch $(basename "$f"):$g"
  done < <(frontmatter "$f" | sed -n 's/^  - //p')
done
if [[ "$count" -gt 0 && -z "$nomatch" ]]; then pass; else fail "検査した glob=$count 一致しない:$nomatch"; fi

it "（健全性）存在しないパスの glob は一致しないと判定される"
assert_eq "$(glob_matches "$with" 'no-such-dir/**')" "0" "存在しない glob の一致数"

# ── 6. 既存の仕組みに乗る（同名の既存ファイル・--upgrade）────────────────────

it "DCB が作っていない同名の既存ファイルは上書きしない"
keep="$(new_workdir)/p"
mkdir -p "$keep/.claude/rules"
printf '利用者が書いたもの\n' > "$keep/.claude/rules/ai-playbook.md"
run_bootstrap "$keep" --with-claude --with-playbook >/dev/null 2>&1
if [[ "$(cat "$keep/.claude/rules/ai-playbook.md")" == "利用者が書いたもの" ]]; then pass; else fail "上書きされた"; fi

it "DCB が作っていない同名の既存ファイルがあると、規則を 1 つも置かず、CLAUDE.md も全文を取り込む従来の形のままにし、警告する"
conf="$(new_workdir)/p"
mkdir -p "$conf/.claude/rules"
printf '利用者が書いたもの\n' > "$conf/.claude/rules/ai-playbook-session-coord.md"
conf_err="$(run_bootstrap "$conf" --with-claude --with-playbook 2>&1 >/dev/null)"
placed="$(find "$conf/.claude/rules" -type f | wc -l | tr -d ' ')"
if [[ "$placed" == "1" ]] \
   && [[ "$(cat "$conf/.claude/rules/ai-playbook-session-coord.md")" == "利用者が書いたもの" ]] \
   && diff -q "$conf/CLAUDE.md" <(cat "$TPL/entry.md" "$TPL/claude-entry-imports.md") >/dev/null 2>&1 \
   && [[ "$conf_err" == *"規則（.claude/rules/ai-playbook*.md）を置きません"* ]] \
   && ! command grep -q 'rules/ai-playbook' "$conf/.devcontainer/ORIGIN"; then
  pass
else
  fail "置いた規則=$placed err=$(printf '%s' "$conf_err" | head -c 300)"
fi

for pol in overwrite prompt; do
  it "衝突の扱いが $pol でも、手書きの同名の規則があれば規則を置かず、CLAUDE.md も従来の形のままにして警告する"
  cp2="$(new_workdir)/p"
  mkdir -p "$cp2/.claude/rules"
  printf '利用者が書いたもの\n' > "$cp2/.claude/rules/ai-playbook.md"
  cp2_err="$(printf 'y\ny\ny\ny\ny\ny\ny\ny\n' | run_bootstrap "$cp2" --with-claude --with-playbook --playbook-conflict-policy "$pol" 2>&1 >/dev/null)"
  placed="$(find "$cp2/.claude/rules" -type f | wc -l | tr -d ' ')"
  if [[ "$placed" == "1" && "$(cat "$cp2/.claude/rules/ai-playbook.md")" == "利用者が書いたもの" ]] \
     && diff -q "$cp2/CLAUDE.md" <(cat "$TPL/entry.md" "$TPL/claude-entry-imports.md") >/dev/null 2>&1 \
     && [[ "$cp2_err" == *"置きません"* ]]; then
    pass
  else
    fail "置いた規則=$placed err=$(printf '%s' "$cp2_err" | head -c 300)"
  fi
done

it "同じ中身の既存ファイル（再実行）は衝突としない"
rerun="$(new_workdir)/p"
run_bootstrap "$rerun" --with-claude --with-playbook >/dev/null 2>&1
rerun_err="$(run_bootstrap "$rerun" --with-claude --with-playbook 2>&1 >/dev/null)"
if [[ "$rerun_err" != *"置きません"* ]]; then pass; else fail "再実行で警告が出た: $rerun_err"; fi

it "規則を置くのに CLAUDE.md が全文を取り込んだまま（既存の CLAUDE.md を温存）なら、二重に載ると警告する"
dbl="$(new_workdir)/p"
mkdir -p "$dbl"
cat "$TPL/entry.md" "$TPL/claude-entry-imports.md" > "$dbl/CLAUDE.md"
dbl_err="$(run_bootstrap "$dbl" --with-claude --with-playbook 2>&1 >/dev/null)"
if [[ "$dbl_err" == *"二重に載ります"* && -f "$dbl/.claude/rules/ai-playbook.md" ]]; then pass; else fail "err=$(printf '%s' "$dbl_err" | head -c 300)"; fi

# --upgrade: 正本の常時の範囲と、条件付きの 1 つの規則を書き換えた規範で追従する。
# 手を入れていない生成物は作り直され、手を入れた生成物には .dcb-new が置かれる。
pb="$(new_workdir)/pb"
cp -R "$PLAYBOOK_SRC" "$pb"
up="$(new_workdir)/p"
bash "$BOOTSTRAP" --project-name upg --languages node --base-image "$TEST_BASE_IMAGE" --output-dir "$up" \
  --with-claude --playbook-from "$pb" >/dev/null 2>&1

# 正本を書き換える（H1 の直後の常時の説明と、16 章の台帳の項目の表の直前）。
python3 -I - "$pb/shared-ai-rules.md" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
a = "このファイルは、全プロジェクトで共通して適用される AI アシスタント向けの正本ルールです。"
b = "台帳の項目は、1 件の登録が持つ項目です。"
assert a in s
s = s.replace(a, a + "（常時の更新）")
# 台帳の項目の節（印の範囲）の見出しの次の本文の先頭に 1 行足す
h = "### 台帳の項目\n"
assert h in s
s = s.replace(h, h + "\n（条件付きの更新）\n", 1)
open(p, "w", encoding="utf-8").write(s)
PY

# 手を入れる: 台帳の項目を含む session-coord の規則だけ。
printf '利用者の追記\n' >> "$up/.claude/rules/ai-playbook-session-coord.md"
always_before="$(cat "$up/.claude/rules/ai-playbook.md")"
edited_before="$(cat "$up/.claude/rules/ai-playbook-session-coord.md")"

out_up="$(bash "$BOOTSTRAP" --upgrade --output-dir "$up" --playbook-from "$pb" 2>&1)"
rc_up=$?

it "--upgrade: 手を入れていない生成物は、新しい正本から作り直される"
if [[ "$(cat "$up/.claude/rules/ai-playbook.md")" != "$always_before" ]] \
   && command grep -F '（常時の更新）' "$up/.claude/rules/ai-playbook.md" >/dev/null; then
  pass
else
  fail "作り直されていない"
fi

it "--upgrade: 手を入れた生成物は上書きせず、新しい版を .dcb-new として置く"
if [[ "$(cat "$up/.claude/rules/ai-playbook-session-coord.md")" == "$edited_before" \
   && -f "$up/.claude/rules/ai-playbook-session-coord.md.dcb-new" ]] \
   && command grep -F '（条件付きの更新）' "$up/.claude/rules/ai-playbook-session-coord.md.dcb-new" >/dev/null \
   && [[ "$rc_up" == "2" ]]; then
  pass
else
  fail "rc=$rc_up $(printf '%s' "$out_up" | tail -3)"
fi

it "--upgrade: 手を入れていない別の条件付きの規則に .dcb-new は置かれない"
if [[ ! -e "$up/.claude/rules/ai-playbook-package-structure.md.dcb-new" ]]; then pass; else fail "不要な .dcb-new がある"; fi

exit_with_result
