#!/usr/bin/env bash
# .claude/ 配下の写しが、雛形（.ai-playbook/templates/）や配線条件から食い違って
# いないことを検査する。
#
# ## 背景
#
# scripts/ 配下の 7 本には tests/test-template-mirror.sh が正本（bootstrap.sh の
# ヒアドキュメント）とのバイト一致を照合しているが、.claude/ 配下には同等の照合が
# 無かった。その結果、気づかれないまま .claude/skills/intake/SKILL.md が雛形
# （.ai-playbook/templates/claude-skill-intake.md）から参照の書き方で 2 箇所ドリフト
# していた（#312）。片方だけ直しても両方が「正しい」まま残るのは、scripts/ 側で
# #223 が踏んだのと同じ壊れ方である。
#
# ## 対象と対応づけ
#
#   .claude/skills/<name>/SKILL.md ↔ .ai-playbook/templates/claude-skill-<name>.md
#   .claude/agents/<name>.md       ↔ .ai-playbook/templates/claude-agent-<name>.md
#
# <name> は両側のディレクトリを走査して機械的に求める（決め打ちの一覧を持たない）。
# 一覧を決め打ちにすると、並列で追加される名前（例: land スキル、#311）がどちらの
# 一覧にも書かれないまま検査対象から漏れる。実装が両側を走査して和集合を取る形に
# しているのはそのためで、新しい skill / agent が increment されても、この検査は
# コードを変更せずに追随する。
#
# ## 片側だけの存在
#
# 雛形はあるが写しが無い、写しはあるが雛形が無い、のどちらも「比べる相手がいない」
# という理由で同様に落とす。tests/test-template-mirror.sh は「写し無し」を意図的な
# 除外（EXCLUDED_NO_COPY_RELS）として許すが、それは正本側が置換プレースホルダを
# 持つ配布専用スクリプト（acceptance-remote.sh 等）に限った話である。.claude/ 配下の
# skill / agent にその前提は無く、このリポジトリの方針は「置くなら雛形と一致させる」
# である。
#
# ## 空集合の防止
#
# 抽出そのものが壊れて対象が 0 件になると、空集合同士の比較で黙って緑になる
# （tests/test-template-mirror.sh が TEMPLATE_RELS / CONDITIONAL_RELS の空を先に
# 検査しているのと同じ配慮）。skill 側・agent 側それぞれで、名前が最低 1 件は
# 取れることを先に確認する。
#
# ## 変異テスト
#
# 「1 文字変えたら落ちる」「片側だけ足したら落ちる」を、本物のファイルを壊さずに
# 確認する。実比較に使うのと同じ関数（bytes_equal / pair_present）を、一時
# ディレクトリに作った壊れたフィクスチャへ適用し、不一致・片側欠落が実際に検出
# されることを見る（tests/test-agy-install-mirror.sh と同じ組み方）。
#
# 末尾改行の差は許容する（tests/test-template-mirror.sh と同じ理由: コマンド置換が
# 両側の末尾改行を落とすため、シェルの挙動に影響しないこの差だけを通す）。
#
# ## .claude/settings.json（#312 の別の受け入れ条件）
#
# skill / agent の名前対応づけとは別の話として、.claude/settings.json が
# 追跡されていること、かつ許可リスト（permissions）を持たないことも合わせて
# ここで検査する。持ち込まれると、対話中に許可した操作が clone した全員へ配られる
# 形になる（.gitignore のコメントが説明する事故そのもの）。
#
# bash 3.2 互換を維持する（連想配列・mapfile を使わない）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-claude-mirror"

SKILLS_DIR="$REPO_ROOT/.claude/skills"
AGENTS_DIR="$REPO_ROOT/.claude/agents"
TEMPLATES_DIR="$REPO_ROOT/.ai-playbook/templates"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-claude-mirror.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# ── 実比較に使う関数（自己テストにも同じものを使う） ──────────────────────────
# 変異テストが検証したいのは「実際の判定に使う関数」であって、判定と別に書いた
# 再実装ではない。同じ関数を本番判定と自己テストの両方から呼ぶことで、この 2 つが
# 乖離する経路を作らない。

# 2 ファイルの中身が末尾改行の差を除いて一致するかを判定する。
bytes_equal() {
  local a="$1" b="$2"
  [[ "$(cat "$a")" == "$(cat "$b")" ]]
}

# 両側のパスがファイルとして存在するかを判定する。
pair_present() {
  local copy="$1" tmpl="$2"
  [[ -f "$copy" && -f "$tmpl" ]]
}

# ── 名前の抽出 ────────────────────────────────────────────────────────────────

skill_copy_names() {
  local d
  for d in "$SKILLS_DIR"/*/; do
    [[ -f "${d}SKILL.md" ]] || continue
    basename "$d"
  done
}

skill_template_names() {
  local f base
  for f in "$TEMPLATES_DIR"/claude-skill-*.md; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f" .md)"
    printf '%s\n' "${base#claude-skill-}"
  done
}

agent_copy_names() {
  local f
  for f in "$AGENTS_DIR"/*.md; do
    [[ -f "$f" ]] || continue
    basename "$f" .md
  done
}

agent_template_names() {
  local f base
  for f in "$TEMPLATES_DIR"/claude-agent-*.md; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f" .md)"
    printf '%s\n' "${base#claude-agent-}"
  done
}

SKILL_NAMES="$(printf '%s\n%s\n' "$(skill_copy_names)" "$(skill_template_names)" | sort -u | sed '/^$/d')"
AGENT_NAMES="$(printf '%s\n%s\n' "$(agent_copy_names)" "$(agent_template_names)" | sort -u | sed '/^$/d')"

it "skill の対象名を抽出できる（0 件では先へ進まない）"
if [[ -n "$SKILL_NAMES" ]]; then
  pass
else
  fail ".claude/skills/*/SKILL.md と .ai-playbook/templates/claude-skill-*.md のどちらからも名前を抽出できなかった（構成か命名規則が変わった可能性）"
fi

it "agent の対象名を抽出できる（0 件では先へ進まない）"
if [[ -n "$AGENT_NAMES" ]]; then
  pass
else
  fail ".claude/agents/*.md と .ai-playbook/templates/claude-agent-*.md のどちらからも名前を抽出できなかった（構成か命名規則が変わった可能性）"
fi

# ── 実比較 ────────────────────────────────────────────────────────────────────

check_pair() {
  local label="$1" copy="$2" tmpl="$3"

  it "$label: 雛形と写しの両方が存在する"
  if pair_present "$copy" "$tmpl"; then
    pass
  elif [[ -f "$tmpl" ]]; then
    fail "写しが無い: $copy（雛形 $tmpl はある。追加するなら雛形と一致させる）"
    return
  elif [[ -f "$copy" ]]; then
    fail "雛形が無い: $tmpl（写し $copy はある）"
    return
  else
    fail "雛形・写しのどちらも見つからない（名前抽出の不整合）: $copy / $tmpl"
    return
  fi

  it "$label: 雛形と写しがバイト一致する"
  if bytes_equal "$tmpl" "$copy"; then
    pass
  else
    detail="$(diff <(cat "$tmpl") <(cat "$copy") | head -n 12 | tr '\n' '/')"
    fail "$tmpl と $copy が食い違う（正本は雛形側。写しを揃える）: $detail"
  fi
}

for name in $SKILL_NAMES; do
  check_pair "skill:$name" "$SKILLS_DIR/$name/SKILL.md" "$TEMPLATES_DIR/claude-skill-$name.md"
done

for name in $AGENT_NAMES; do
  check_pair "agent:$name" "$AGENTS_DIR/$name.md" "$TEMPLATES_DIR/claude-agent-$name.md"
done

# ── 照合が生きていることの確認（変異テスト） ──────────────────────────────────
# 本物のファイルは壊さず、一時ディレクトリに作ったフィクスチャに対して本番判定と
# 同じ関数（bytes_equal / pair_present）を適用する。

it "写しを 1 文字変えると不一致として検出される（意図的な乖離フィクスチャ）"
MUT_TMPL="$TMP_ROOT/mut-tmpl.md"
MUT_COPY="$TMP_ROOT/mut-copy.md"
printf '# fixture\nline one\nline two\n' >"$MUT_TMPL"
{ cat "$MUT_TMPL"; printf 'x\n'; } >"$MUT_COPY"
if bytes_equal "$MUT_TMPL" "$MUT_COPY"; then
  fail "1 文字変えても一致と判定された（照合が空振りしている）"
else
  pass
fi

it "完全一致するフィクスチャは一致として検出される（対照）"
# 上の不一致検出が「常に不一致を返す壊れた実装」ではないことを示す対照。
cp "$MUT_TMPL" "$TMP_ROOT/mut-copy-same.md"
if bytes_equal "$MUT_TMPL" "$TMP_ROOT/mut-copy-same.md"; then
  pass
else
  fail "完全一致のフィクスチャが不一致と判定された（照合が壊れている）"
fi

it "写しだけが存在し雛形が無い場合を検出できる（意図的な片側フィクスチャ）"
ONESIDE_COPY="$TMP_ROOT/oneside-copy.md"
: >"$ONESIDE_COPY"
if pair_present "$ONESIDE_COPY" "$TMP_ROOT/oneside-tmpl-does-not-exist.md"; then
  fail "雛形が無いのに両側存在すると判定された（照合が空振りしている）"
else
  pass
fi

it "雛形だけが存在し写しが無い場合を検出できる（意図的な片側フィクスチャ）"
ONESIDE_TMPL="$TMP_ROOT/oneside-tmpl.md"
: >"$ONESIDE_TMPL"
if pair_present "$TMP_ROOT/oneside-copy-does-not-exist.md" "$ONESIDE_TMPL"; then
  fail "写しが無いのに両側存在すると判定された（照合が空振りしている）"
else
  pass
fi

# ── .claude/settings.json ─────────────────────────────────────────────────────

SETTINGS="$REPO_ROOT/.claude/settings.json"

it ".claude/settings.json が追跡されている"
# git ls-files は追跡外のファイルには何も返さない。作業ツリーにファイルが存在する
# だけでは追跡されているとは言えない（.gitignore の除外を再包含し忘れたまま
# ファイルだけ置く、という壊れ方を拾うため）。
tracked_lines="$(git -C "$REPO_ROOT" ls-files .claude/settings.json | grep -c .)"
if [[ "$tracked_lines" == "1" ]]; then
  pass
else
  fail "git ls-files .claude/settings.json が $tracked_lines 行（1 行であるべき）"
fi

# permissions キーの有無を判定する関数。自己テストにも同じものを使う。
has_permissions_key() {
  local f="$1"
  grep -q '"permissions"' "$f"
}

it "追跡された .claude/settings.json が permissions を持たない"
# 許可リストが混入すると、対話中に許可した操作が clone した全員へ配られる形になる
# （.gitignore のコメントが説明する事故そのもの）。許可リストは settings.local.json
# （追跡しない）側に置く。
if [[ ! -f "$SETTINGS" ]]; then
  fail "$SETTINGS が存在しない"
elif has_permissions_key "$SETTINGS"; then
  fail "$SETTINGS に permissions キーが含まれている（許可リストの混入。settings.local.json 側へ移すこと）"
else
  pass
fi

it "permissions キーの検出ロジックが実際に検出できる（意図的な乖離フィクスチャ）"
PERM_FIXTURE="$TMP_ROOT/settings-with-permissions.json"
printf '{"hooks":{},"permissions":{"allow":[]}}\n' >"$PERM_FIXTURE"
if has_permissions_key "$PERM_FIXTURE"; then
  pass
else
  fail "permissions キーを含むフィクスチャを検出できなかった（照合が空振りしている）"
fi

exit_with_result
