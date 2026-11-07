#!/usr/bin/env bash
# ルーティンの依頼文（docs/routines/*.md）が、無人実行の 5 点を宣言していることの検査（#713）。
#
# 無人で動くものは、動く前に次の 5 点が揃っている必要がある（Anthropic の「Let Claude run
# without you」）: 完了の定義・自分で検証する手段・触れる範囲・上限・最終的に承認する人。
# 各依頼文は「## 無人実行の 5 点」の節に、この 5 つを行に持つ表を置く。
#
# 共通規範 12 章「機構化の判断基準」に従い、照合できる点だけを機械で確かめる。
#
#   自分で検証する手段: `bash scripts/….sh` の形のコマンドを 1 つ以上書き、そのスクリプトが実在する
#   触れる範囲        : 依頼文の節（## 依頼文…）に出てくるすべての #N が、範囲の欄に列挙されている。
#                       依頼文が「禁止:」の箇条書きを持つ
#   上限              : 数を含む
#   完了の定義・最終的に承認する人: 欄が空でないことだけを見る（中身を機械で確かめられないので、
#                       それ以上は機構化せず、レビューで確かめる）
#
# 検査は「ファイルを受け取る関数」にしてあり、末尾で壊したフィクスチャへも同じ関数を当てる。
# 検査が実際に落ちることを確かめないと、常に緑の検査が緑のまま残る。
#
# bash 3.2 互換を維持する（連想配列・mapfile を使わない）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-routine-preconditions"

ROUTINES_REL="docs/routines"
LABELS="完了の定義
自分で検証する手段
触れる範囲
上限
最終的に承認する人"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/test-routine-preconditions.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

# 5 点の表から、項目 $2 の宣言（2 列目）を出す。表の行は「| 項目 | 宣言 |」。
# 宣言の中の縦棒（コードの中の | など）で切らないよう、1 列目の後ろから行末の | の手前までを宣言とする。
declared() {
  awk -v want="$2" '
    /^## / { insec = ($0 ~ /^## 無人実行の 5 点/); next }
    insec && /^\|/ {
      rest = substr($0, 2)
      p = index(rest, "|")
      if (p == 0) next
      k = substr(rest, 1, p - 1); v = substr(rest, p + 1)
      sub(/\|[ \t]*$/, "", v)
      gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (k == want) { print v; exit }
    }
  ' "$1"
}

# 標準入力から issue / PR の参照を 1 行 1 件で出す。別のリポジトリの参照（owner/repo#N）は、
# そのままの形で出す（素の #N と同じものとして数えない。共通規範 6 章「別のリポジトリの参照」）。
issue_refs() {
  grep -oE '([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#[0-9]+' | sort -u
}

# 依頼文の節（「## 依頼文」で始まる見出しから、次の ## まで）を出す。
prompt_section() {
  awk '/^## / { insec = ($0 ~ /^## 依頼文/); next } insec' "$1"
}

# 1 つの依頼文を検査する。$1 = ファイル、$2 = リポジトリの根（scripts/ の実在を見る）。問題があれば内容を出して 1 を返す。
check_routine() {
  local f="$1" root="$2" rc=0 label v cmds s ids scope_ids id
  # 5 点の欄がすべて空でない。
  while IFS= read -r label; do
    v="$(declared "$f" "$label")"
    if [[ -z "$v" ]]; then
      echo "$f: 無人実行の 5 点の「$label」が無いか空"
      rc=1
    fi
  done <<< "$LABELS"
  [[ "$rc" -eq 0 ]] || return 1

  # 自分で検証する手段: bash scripts/….sh が 1 つ以上あり、実在する。
  # bash scripts/… の参照は、scripts/ の下のサブディレクトリも含めてすべて拾い、1 つも捨てない。
  # 拾ったものは、それぞれ .sh で終わり、.. を含まず、実在する必要がある
  # （scripts/check.sh.missing を捨てたり、scripts/check.sh だけを抜き出したりして、実在の確かめをすり抜けない）。
  cmds="$(declared "$f" "自分で検証する手段" | grep -oE 'bash scripts/[A-Za-z0-9_./-]+' | sed 's/^bash //')"
  if [[ -z "$cmds" ]]; then
    echo "$f: 「自分で検証する手段」に bash scripts/….sh の形のコマンドが無い"
    rc=1
  fi
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    if [[ "$s" != *.sh || "$s" == *..* ]]; then
      echo "$f: 「自分で検証する手段」のスクリプトが .sh で終わらないか、.. を含む: $s"
      rc=1
    elif [[ ! -f "$root/$s" ]]; then
      echo "$f: 「自分で検証する手段」のスクリプトが実在しない: $s"
      rc=1
    fi
  done <<< "$cmds"

  # 上限: 1 回あたりの上限を、単位の付いた数で書く。欄を「、」「。」で句に分け、同じ句に
  # 「1 回の実行で」か「1 回あたり」と、単位の付いた数（件・手番・時間など）があり、「無制限」が無いことを求める。
  # 実行の頻度（週 1 回）だけ、別の句の数（参照する issue は 1 件）、issue の番号では通さない。
  # 句の区切りは gsub の文字列で行い、マルチバイトの文字を角括弧に入れない（C ロケールの awk・grep は
  # [^。] をバイトごとに読み、「で」のように同じバイトを含む文字で一致が切れるため）。
  if ! declared "$f" "上限" | awk '
      {
        line = $0
        gsub(/、/, "\n", line); gsub(/。/, "\n", line)
        n = split(line, cl, "\n")
        for (i = 1; i <= n; i++) {
          c = cl[i]
          if ((index(c, "1 回の実行で") || index(c, "1 回あたり")) && !index(c, "無制限") \
              && c ~ /[0-9]+ ?(件|手番|分|秒|時間|ドル|USD)/) ok = 1
        }
      }
      END { exit !ok }'; then
    echo "$f: 「上限」に 1 回あたりの上限が無い（例: 1 回の実行で書き込みは 1 件、1 回あたり 40 手番）"
    rc=1
  fi

  # 触れる範囲: 依頼文の節のすべての #N が、範囲の欄にある。依頼文は「禁止:」の箇条書きを持つ。
  if [[ -z "$(prompt_section "$f")" ]]; then
    echo "$f: 「## 依頼文」の節が無い"
    return 1
  fi
  ids="$(prompt_section "$f" | issue_refs)"
  scope_ids="$(declared "$f" "触れる範囲" | issue_refs)"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if ! printf '%s\n' "$scope_ids" | grep -xF "$id" >/dev/null; then
      echo "$f: 依頼文の $id が「触れる範囲」に無い"
      rc=1
    fi
  done <<< "$ids"
  # 「禁止:」（全角のコロンも可）の行の直後に続く箇条書きだけを数える（空行は挟んでよい。ほかの行で終わる）。
  # 各箇条は否定（「〜ない」）で書く。「〜してよい」のような許可を禁止の欄に置いた依頼文を通さないため。
  # 否定かどうかは文字の並びで見るだけで、禁止の中身が十分かはレビューで確かめる（共通規範 12 章）。
  if ! prompt_section "$f" | awk '
      $0 == "禁止:" || $0 == "禁止：" { p = 1; next }
      p && /^- / { n++; if (index($0, "ない") == 0) bad = 1; next }
      p && /^[ \t]*$/ { next }
      p { p = 0 }
      END { exit !(n > 0 && !bad) }'; then
    echo "$f: 依頼文に「禁止:」の箇条書きが無いか、否定（〜ない）で書かれていない箇条がある"
    rc=1
  fi
  return "$rc"
}

# ルート $1 の docs/routines/*.md をすべて検査する。1 つも無ければ通す（対象が無い）。
check_all() {
  local root="$1" rc=0 f
  for f in "$root/$ROUTINES_REL"/*.md; do
    [[ -f "$f" ]] || continue
    check_routine "$f" "$root" || rc=1
  done
  return "$rc"
}

it "docs/routines/ の依頼文がすべて無人実行の 5 点を宣言し、照合できる点が合っている"
if out="$(check_all "$REPO_ROOT" 2>&1)"; then pass; else fail "$out"; fi

it "docs/routines/ に依頼文が 1 つ以上ある（検査が空振りしていない）"
if ls "$REPO_ROOT/$ROUTINES_REL"/*.md >/dev/null 2>&1; then pass; else fail "依頼文が無い"; fi

# --- 壊したフィクスチャ ---

# 正しい依頼文を持つ小さなルートを作って出す。
make_fixture() {
  local d="$FIX/$1"
  mkdir -p "$d/scripts" "$d/$ROUTINES_REL"
  : > "$d/scripts/check.sh"
  cat > "$d/$ROUTINES_REL/r.md" <<'EOF'
# ルーティン

## 依頼文

1. `bash scripts/check.sh` を回し、#11 へコメントを 1 件付ける。

禁止:

- issue を作らない。

## 無人実行の 5 点

| 項目 | 宣言 |
|---|---|
| 完了の定義 | #11 にコメントが 1 件付いている |
| 自分で検証する手段 | `bash scripts/check.sh` の終了コード |
| 触れる範囲 | 書き込み: #11 へのコメントだけ |
| 上限 | 1 回の実行で書き込みは 1 件 |
| 最終的に承認する人 | 利用者 |
EOF
  printf '%s' "$d"
}

# ルート $1 の依頼文で、$2 を含む行を $3 に置き換える（$3 が空なら行を消す）。
mutate() {
  local f="$1/$ROUTINES_REL/r.md"
  awk -v from="$2" -v to="$3" 'index($0, from) { if (to != "") print to; next } { print }' "$f" > "$f.new" && cat "$f.new" > "$f" && rm -f "$f.new"
}

expect_fail() {
  if check_all "$1" >/dev/null 2>&1; then fail "壊したフィクスチャで検査が落ちなかった"; else pass; fi
}

it "フィクスチャ（正しい形）は通る（壊す前の基準）"
D="$(make_fixture base)"
if out="$(check_all "$D" 2>&1)"; then pass; else fail "$out"; fi

it "5 点の欄が欠けると落ちる（最終的に承認する人）"
D="$(make_fixture miss-approver)"
mutate "$D" "| 最終的に承認する人 |" ""
expect_fail "$D"

it "欄が空だと落ちる（完了の定義）"
D="$(make_fixture empty-done)"
mutate "$D" "| 完了の定義 |" "| 完了の定義 |  |"
expect_fail "$D"

it "検証のコマンドが実在しないスクリプトを指すと落ちる"
D="$(make_fixture ghost-script)"
mutate "$D" "| 自分で検証する手段 |" "| 自分で検証する手段 | \`bash scripts/ghost.sh\` の終了コード |"
expect_fail "$D"

it "検証のコマンドが無いと落ちる"
D="$(make_fixture no-command)"
mutate "$D" "| 自分で検証する手段 |" "| 自分で検証する手段 | 目で見て確かめる |"
expect_fail "$D"

it "依頼文に範囲の外の #N があると落ちる"
D="$(make_fixture out-of-scope)"
mutate "$D" "1. \`bash scripts/check.sh\`" "1. \`bash scripts/check.sh\` を回し、#11 と #99 へコメントを付ける。"
expect_fail "$D"

it "上限が数で書かれていないと落ちる"
D="$(make_fixture no-number)"
mutate "$D" "| 上限 |" "| 上限 | 少しだけ |"
expect_fail "$D"

it "上限に単位の付いた数が無いと落ちる（issue の番号は数に数えない）"
D="$(make_fixture number-is-ref)"
mutate "$D" "| 上限 |" "| 上限 | #11 の範囲で適宜 |"
expect_fail "$D"

it "宣言の中の縦棒（コードの中の |）で列を切らない"
D="$(make_fixture pipe-in-code)"
mutate "$D" "| 自分で検証する手段 |" "| 自分で検証する手段 | \`jq '.a | .b'\` のあと \`bash scripts/ghost.sh\` の終了コード |"
expect_fail "$D"

it "別のリポジトリの参照（owner/repo#N）は、範囲にある素の #N と同じものとして数えない"
D="$(make_fixture cross-repo)"
mutate "$D" "1. \`bash scripts/check.sh\`" "1. \`bash scripts/check.sh\` を回し、other/repo#11 へコメントを 1 件付ける。"
expect_fail "$D"

it "「禁止:」の直後でない箇条書きは、禁止事項に数えない"
D="$(make_fixture far-bullets)"
mutate "$D" "- issue を作らない。" "説明の文。"
awk '{ print } /^説明の文。/ { print ""; print "- 関係の無い箇条書き" }' "$D/$ROUTINES_REL/r.md" > "$D/x" && cat "$D/x" > "$D/$ROUTINES_REL/r.md"
expect_fail "$D"

it "禁止の箇条に許可（〜してよい）があると落ちる"
D="$(make_fixture permit)"
mutate "$D" "- issue を作らない。" "- issue を作ってよい。"
expect_fail "$D"

it "検証のコマンドの .sh の後ろが続く（scripts/check.sh.missing）と、実在する scripts/check.sh と取り違えずに落ちる"
D="$(make_fixture suffix)"
mutate "$D" "| 自分で検証する手段 |" "| 自分で検証する手段 | \`bash scripts/check.sh.missing\` の終了コード |"
expect_fail "$D"

it "scripts/ の下のサブディレクトリの検証スクリプトを拾い、実在すれば通る"
D="$(make_fixture nested)"
mkdir -p "$D/scripts/checks" && : > "$D/scripts/checks/routine.sh"
mutate "$D" "| 自分で検証する手段 |" "| 自分で検証する手段 | \`bash scripts/checks/routine.sh\` の終了コード |"
if out="$(check_all "$D" 2>&1)"; then pass; else fail "$out"; fi

it "検証のコマンドに、実在するものと実在しない .sh.missing を並べると落ちる（捨てずに確かめる）"
D="$(make_fixture mixed)"
mutate "$D" "| 自分で検証する手段 |" "| 自分で検証する手段 | \`bash scripts/check.sh\` と \`bash scripts/check.sh.missing\` の終了コード |"
expect_fail "$D"

it "上限の句が「無制限」で、別の句の数を上限と取り違えずに落ちる"
D="$(make_fixture other-clause)"
mutate "$D" "| 上限 |" "| 上限 | 1 回あたりの書き込みは無制限、参照する issue は 1 件 |"
expect_fail "$D"

it "C ロケールでも、正しい形の上限を通す（マルチバイトの文字の扱いがロケールで変わらない）"
D="$(make_fixture c-locale)"
if out="$(LC_ALL=C check_all "$D" 2>&1)"; then pass; else fail "$out"; fi

it "上限が実行の頻度だけで、1 回あたりの上限が無いと落ちる"
D="$(make_fixture freq-only)"
mutate "$D" "| 上限 |" "| 上限 | 週 1 回実行。1 回あたりの書き込みは無制限 |"
expect_fail "$D"

it "依頼文に「禁止:」の箇条書きが無いと落ちる"
D="$(make_fixture no-prohibition)"
mutate "$D" "- issue を作らない。" ""
expect_fail "$D"

it "「## 依頼文」の節が無いと落ちる"
D="$(make_fixture no-prompt)"
mutate "$D" "## 依頼文" "## 説明"
expect_fail "$D"

exit_with_result
