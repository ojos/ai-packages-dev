#!/usr/bin/env bash
# `set -o pipefail` 下で、早期終了する消費側へパイプしている箇所を検出する。
#
# ## 何が起きるか
#
# `grep -q` や `head -n 1` は目的を果たした時点で終了し、パイプを閉じる。まだ書き
# 込み中の生産側は SIGPIPE で死に、終了コード 141 を返す。`pipefail` があると
# **パイプライン全体が非 0** になる。消費側が成功していても、である。
#
#   $ set -o pipefail
#   $ find <23 個の .md がある木> -type f -name '*.md' | grep -q .
#   rc=141  PIPESTATUS=141 0        ← grep はマッチしている（右が 0）
#
# 判定に使っていると結果が反転する。実際、macOS で `bootstrap.sh --playbook-version`
# が必ず失敗していた原因がこれだった（#285）。
#
# ## なぜテストで捕まえられなかったか
#
# **GNU find は EPIPE を握って終了コード 0 で終わる。** BSD find（macOS）は SIGPIPE
# で死ぬ。このリポジトリのテストはすべて Linux コンテナで走るため、実行して再現する
# 検査を書いても緑になる。だから静的検査にする（#218 で `mktemp` のテンプレート欠落を
# 静的に塞いだのと同じ形）。
#
# ## 何を検出するか
#
# 生産側が**複数行を出しうる**コマンドで、消費側が早期終了する形。生産側が単一の
# `printf` / `echo` の場合は、出力がパイプバッファに収まりきって生産側が先に終わる
# ため実害が無く、対象から外す（外さないと既存の健全な箇所が大量に赤くなり、検査が
# 読まれなくなる）。
#
# ## 直し方
#
#   find … | grep -q .      → find … -print -quit の出力が空かで判定（パイプを無くす）
#   find … | head -n 1      → find … -print -quit
#   cmd  … | grep -q X      → cmd … | grep X >/dev/null（-q を外せば EOF まで読む）
#
# `|| true` を足すだけの対処は勧めない。生産側が**本当に失敗した**場合まで握り潰し、
# 検査が成立していないことを合格にしてしまう。ただし既存の `|| true` は意図的な
# ガードなので、検出の対象からは外す。
#
# 依存はコアユーティリティのみ。bash 3.2 互換を維持する。

set -uo pipefail
export LC_ALL=C.UTF-8
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-pipefail-sigpipe"

# 生産側が単一行に収まると分かっている形。これらは実害が無いので除外する。
# 行頭からパイプまでが printf / echo だけで構成されている場合が該当する。
SAFE_PRODUCER='^[[:space:]]*(if[[:space:]]+!?[[:space:]]*)?(printf|echo)[[:space:]]'

# 早期終了する消費側。
#   grep の -q / -s は最初のマッチで終了する（-q を含む短縮形 -qi / -qx 等も拾う）
#   head は指定行数を読んだ時点で終了する
EARLY_EXIT_CONSUMER='\|[[:space:]]*(grep[[:space:]]+(-[a-zA-Z]*q[a-zA-Z]*)|head([[:space:]]|$))'

# 検査対象: pipefail を有効にしている追跡対象のシェルスクリプト。
# tests/ 自身は除く（この検査が検出対象の文字列をリテラルで持つため、自己矛盾する。
# scripts/check-neutrality.sh が tests/ を除外しているのと同じ理由）。
target_scripts() {
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in
      tests/*|*/tests/*) continue ;;
    esac
    grep -lE '^[[:space:]]*set[[:space:]].*(-o[[:space:]]+pipefail|-[a-z]*o[[:space:]]*pipefail)' "$REPO_ROOT/$f" >/dev/null 2>&1 && printf '%s\n' "$f"
  done < <(cd "$REPO_ROOT" && git ls-files '*.sh')
}

SCRIPTS="$(target_scripts)"
SCRIPT_COUNT="$(printf '%s\n' "$SCRIPTS" | grep -c . || true)"

it "pipefail を有効にしたスクリプトを 1 本以上抽出できる"
# 抽出が壊れて 0 件になると、以降の検査は対象ゼロで無条件に通る（偽の緑）。
if [[ "$SCRIPT_COUNT" -gt 0 ]]; then
  pass
else
  fail "対象スクリプトを抽出できなかった"
fi

# violations_in <ファイルの絶対パス>
#
# 「行番号:該当行」を列挙する。既存の `|| true` ガードと、生産側が単一 printf / echo の
# 形は除く。行継続（`\` で次行へ続く形）は追わない。現行ツリーに該当が無く、追うと
# 誤検知が増えるため。新しく現れたらそのとき判断する。
# コメント行は除く。この欠陥の解説そのものが `| grep -q .` という文字列を含むため
# （直した箇所には必ず「なぜ直したか」を書く）、除かないと修正するほど赤が増える。
violations_in() {
  local file="$1"
  grep -nE "$EARLY_EXIT_CONSUMER" "$file" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*#' \
    | grep -vE '\|\|[[:space:]]*true' \
    | while IFS= read -r hit; do
        # 行番号を落として本文だけを安全側の判定へ掛ける。
        body="${hit#*:}"
        printf '%s' "$body" | grep -qE "$SAFE_PRODUCER" && continue
        printf '%s\n' "$hit"
      done
}

it "現行ツリーにガードの無い早期終了パイプが無い"
HITS=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  v="$(violations_in "$REPO_ROOT/$f")"
  [[ -n "$v" ]] && HITS="${HITS}${f}
${v}
"
done <<SCRIPTSEOF
$SCRIPTS
SCRIPTSEOF
if [[ -z "$HITS" ]]; then
  pass
else
  fail "pipefail 下で早期終了する消費側へパイプしている（SIGPIPE で判定が反転しうる）:
$HITS"
fi

# ── フィクスチャでの負例検査 ────────────────────────────────────────────────

FIXTURE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test-pipefail-sigpipe.XXXXXX")"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

it "grep -q への無防備なパイプを検出する（意図的な負例）"
cat > "$FIXTURE_DIR/bad-grep.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if ! find /tmp -type f -name '*.md' | grep -q .; then
  echo none
fi
EOF
if [[ -n "$(violations_in "$FIXTURE_DIR/bad-grep.sh")" ]]; then
  pass
else
  fail "検出できなかった"
fi

it "head への無防備なパイプを検出する（意図的な負例）"
cat > "$FIXTURE_DIR/bad-head.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
first="$(find /tmp -maxdepth 1 -type d | head -n 1)"
EOF
if [[ -n "$(violations_in "$FIXTURE_DIR/bad-head.sh")" ]]; then
  pass
else
  fail "検出できなかった"
fi

it "|| true でガードした形は検出しない（既存の意図的な回避）"
cat > "$FIXTURE_DIR/guarded.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
first="$(find /tmp -maxdepth 1 -type d | head -n 1 || true)"
EOF
if [[ -z "$(violations_in "$FIXTURE_DIR/guarded.sh")" ]]; then
  pass
else
  fail "ガード済みを誤検出した"
fi

it "生産側が単一 printf / echo の形は検出しない（パイプバッファに収まる）"
cat > "$FIXTURE_DIR/safe-printf.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if printf '%s' "$key" | grep -qi 'secret'; then
  echo hit
fi
echo "$line" | grep -q foo
EOF
if [[ -z "$(violations_in "$FIXTURE_DIR/safe-printf.sh")" ]]; then
  pass
else
  fail "安全な形を誤検出した: $(violations_in "$FIXTURE_DIR/safe-printf.sh")"
fi

it "-print -quit へ直した形は検出しない（対照群）"
cat > "$FIXTURE_DIR/fixed.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -z "$(find /tmp -type f -name '*.md' -print -quit 2>/dev/null)" ]]; then
  echo none
fi
EOF
if [[ -z "$(violations_in "$FIXTURE_DIR/fixed.sh")" ]]; then
  pass
else
  fail "修正後の形を誤検出した"
fi

it "-q を外して >/dev/null にした形は検出しない（対照群）"
cat > "$FIXTURE_DIR/fixed2.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if git ls-remote --tags origin | grep "refs/tags/v1" >/dev/null; then
  echo found
fi
EOF
if [[ -z "$(violations_in "$FIXTURE_DIR/fixed2.sh")" ]]; then
  pass
else
  fail "修正後の形を誤検出した"
fi

# ── 実挙動の記録（Linux では再現しないことの明示） ──────────────────────────

it "この環境の find は EPIPE を握って 0 で終わる（macOS との差の記録）"
# GNU find は 0、BSD find は 141。ここが 141 を返す環境では、修正前のコードが
# 実際に壊れる。検査の意図を将来の読み手へ伝えるために測って残す。
set -o pipefail
find "$REPO_ROOT/.ai-playbook" -type f -name '*.md' | grep -q . 2>/dev/null
producer_rc="${PIPESTATUS[0]}"
set +o pipefail
echo "       （参考: この環境の find の終了コード = $producer_rc / GNU=0, BSD=141）"
# 値そのものは環境依存なので合否にしない。測れたことだけを確認する。
if [[ -n "$producer_rc" ]]; then
  pass
else
  fail "PIPESTATUS を取得できなかった"
fi

exit_with_result
