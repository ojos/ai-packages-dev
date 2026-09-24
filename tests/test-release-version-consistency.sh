#!/usr/bin/env bash
# リリース時の版情報の食い違いを、main へ入る前に機械で止める回帰テスト。
#
# ## なぜ要るか
#
# 版情報は 3 か所に散っている。機械照合があるのは 1 つだけだった。
#
#   - 版マーカー 5 箇所        … validate_dcb_docs と test-dcb-version-anchors.sh が見る
#   - RELEASE_HISTORY の 2 表  … RUNBOOK の文章にだけあった
#   - README の実行例の版      … どこにも無かった
#
# v0.12.0 の準備で **3 か所すべてで漏れを出した。** 後ろ 2 つは機械では止まらず、
# レビューが拾った。とくに実行例の古びは重い: README が --playbook-version v0.1.4 を
# 例示していたが、その版には新しい雛形が無く、**利用者が例をそのまま叩くと生成が
# 止まる**（実測で確認した）。
#
# ## 実行例は現行版と完全一致を要求する
#
# 「雛形を持つ最小版以上」ではない。最小版を宣言する場所が機械可読な形で存在せず、
# **その宣言自体が古びる経路**が残るためである。代償は playbook をリリースするたびに
# README の 1 行を更新する必要が生じること。**忘れれば赤になる。それがこの検査の
# 目的である。**
#
# ## この検査が見ないこと
#
# **リリースノートの内容の正しさは見ない。** 版番号の整合だけを見る。
#
# 依存はコアユーティリティ（awk / sed / grep）のみ。bash 3.2 互換を維持する。

set -uo pipefail
export LC_ALL=C
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-release-version-consistency"

HISTORY="$REPO_ROOT/docs/release/RELEASE_HISTORY.md"
README="$REPO_ROOT/packages/devcontainer-bootstrap/README.md"
BOOTSTRAP="$REPO_ROOT/packages/devcontainer-bootstrap/bootstrap.sh"

# ── 抽出（判定の本体。本番も負例もここを通す）────────────────────────────────

# current_version <RELEASE_HISTORY> <パッケージ名>
#   現行バージョン表からそのパッケージの版を取り出す。
#   表の形: | <パッケージ> | `<リポジトリ>` | <版> | <配布形態> |
current_version() {
  awk -F'|' -v pkg="$2" '
    {
      name = $2
      gsub(/^[ \t]+|[ \t]+$/, "", name)
      if (name != pkg) next
      repo = $3
      # 現行バージョン表はリポジトリ列を持つ。版更新表（版・公開日・要点）と
      # 区別するため、この列がバッククォート付きのリポジトリ名であることを見る。
      if (repo !~ /`/) next
      v = $4
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      print v
      exit
    }
  ' "$1"
}

# history_has_row <RELEASE_HISTORY> <パッケージ名> <版>
#   版更新表にその版の行があるか。あれば行を返す。
history_has_row() {
  awk -F'|' -v pkg="$2" -v want="$3" '
    {
      name = $2; gsub(/^[ \t]+|[ \t]+$/, "", name)
      v    = $3; gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (name == pkg && v == want) { print; exit }
    }
  ' "$1"
}

# marker_version <bootstrap.sh>
#   DCB_VERSION の値を取り出す。
#
# **`grep | head -n 1` にしない。** head が 1 行目で終了してパイプを閉じると、まだ
# 書き込み中の grep が SIGPIPE で死に、pipefail 下ではパイプライン全体が 141 になる
# （この検査自身が PIPEFAIL_SIGPIPE として検出する形）。awk なら 1 プロセスで
# 先頭一致を取って exit できる。
#
# 区間量指定子（`{n,m}`）は使わない。mawk が下限 2 以上で誤解釈するため（AWK_INTERVAL）。
marker_version() {
  awk -F'"' '/^DCB_VERSION="v[0-9]+\.[0-9]+\.[0-9]+"/ { print $2; exit }' "$1"
}

# readme_playbook_versions <README>
#   --playbook-version の実行例に現れる版を、重複を潰して列挙する。
readme_playbook_versions() {
  { grep -oE '\-\-playbook-version v[0-9]+\.[0-9]+\.[0-9]+' "$1" || true; } \
    | awk '{print $2}' | sort -u
}

# ── 比較（判定の本体。実データも不一致フィクスチャもここを通す）──────────────
#
# **抽出だけを関数にしても足りない。** 比較を `it` の中へ直接書くと、比較を常に真へ
# 変える変異が緑のまま残る（実測で踏んだ。レビューの指摘）。値を受け取る関数にして、
# 実データと不一致フィクスチャの両方を同じ経路へ通す。

# same_version <実測値> <期待値>
#   一致すれば 0、違えば 1 を返し、違いを標準出力へ出す。
same_version() {
  if [[ "$1" == "$2" ]]; then
    return 0
  fi
  printf '%s != %s\n' "$1" "$2"
  return 1
}

# all_same_version <期待値> <値の並び（改行区切り）>
#   並びのすべてが期待値と一致すれば 0。違うものを標準出力へ列挙して 1 を返す。
all_same_version() {
  local want="$1" input="$2" bad="" v
  while IFS= read -r v; do
    [[ -z "$v" ]] && continue
    [[ "$v" == "$want" ]] || bad="$bad $v"
  done <<ALLEOF
$input
ALLEOF
  if [[ -z "$bad" ]]; then
    return 0
  fi
  printf '%s\n' "$bad"
  return 1
}

# ── 抽出が成立していること ────────────────────────────────────────────────────

DCB_CURRENT="$(current_version "$HISTORY" 'devcontainer-bootstrap')"
PB_CURRENT="$(current_version "$HISTORY" 'ai-playbook')"
DCB_MARKER="$(marker_version "$BOOTSTRAP")"
README_PB="$(readme_playbook_versions "$README")"

it "現行バージョン表から両パッケージの版を抽出できる"
# 抽出が壊れて空になると、以降の比較が「空 == 空」で通る（偽の緑）。
if [[ -n "$DCB_CURRENT" ]] && [[ -n "$PB_CURRENT" ]]; then
  pass
else
  fail "現行バージョン表を読めない（DCB=[$DCB_CURRENT] playbook=[$PB_CURRENT]）"
fi

it "bootstrap.sh から DCB_VERSION を抽出できる"
if [[ -n "$DCB_MARKER" ]]; then
  pass
else
  fail "DCB_VERSION を読めない"
fi

it "README から --playbook-version の実行例を抽出できる"
if [[ -n "$README_PB" ]]; then
  pass
else
  fail "README に --playbook-version の実行例が無い（例が消えたか、書式が変わった）"
fi

# ── 4 条件 ────────────────────────────────────────────────────────────────────

it "1. 現行バージョン表の DCB 版が bootstrap.sh の DCB_VERSION と一致する"
if DIFF="$(same_version "$DCB_CURRENT" "$DCB_MARKER")"; then
  pass
else
  fail "食い違い: RELEASE_HISTORY=[$DCB_CURRENT] bootstrap.sh=[$DCB_MARKER] ($DIFF)（リリース履歴の正本と実際の版がずれる）"
fi

it "2. 版更新表に現行 DCB 版の行がある"
if [[ -n "$(history_has_row "$HISTORY" 'devcontainer-bootstrap' "$DCB_CURRENT")" ]]; then
  pass
else
  fail "版更新表に devcontainer-bootstrap $DCB_CURRENT の行が無い"
fi

it "2b. 版更新表に現行 playbook 版の行がある"
if [[ -n "$(history_has_row "$HISTORY" 'ai-playbook' "$PB_CURRENT")" ]]; then
  pass
else
  fail "版更新表に ai-playbook $PB_CURRENT の行が無い"
fi

it "3. README の --playbook-version の実行例が現行 playbook 版と一致する"
# 「最小版以上」ではなく完全一致を求める。最小版を宣言する場所が機械可読な形で
# 無く、その宣言自体が古びる経路が残るため（利用者の判断）。
if MISMATCH="$(all_same_version "$PB_CURRENT" "$README_PB")"; then
  pass
else
  fail "README の実行例が現行 playbook 版 $PB_CURRENT と違う:$MISMATCH（利用者が例をそのまま叩くと、雛形が無くて生成が止まる）"
fi

it "4. README の --playbook-version の実行例が複数あっても全て同じ版である"
COUNT="$(printf '%s\n' "$README_PB" | grep -c . || true)"
if [[ "$COUNT" -eq 1 ]]; then
  pass
else
  fail "README に版の違う実行例が $COUNT 種類ある: $(printf '%s' "$README_PB" | tr '\n' ' ')"
fi

# ── 対照群（判定が効いていることの固定）──────────────────────────────────────

it "同じ抽出が、食い違った RELEASE_HISTORY から違う版を読む（意図的な負例）"
# 「常に一致」でも上の比較は通ってしまうため、違う値を返す側も通す。
# フィクスチャ側で awk を書き直すと、判定を無効化しても緑を返す。
FX="$(mktemp "${TMPDIR:-/tmp}/hist.XXXXXX")"
{
  printf '%s\n' '| パッケージ | リポジトリ | 現行バージョン | 配布形態 |'
  printf '%s\n' '|---|---|---|---|'
  printf '%s\n' '| devcontainer-bootstrap | `ojos/devcontainer-bootstrap` | v9.9.9 | GitHub Release |'
  printf '%s\n' '| ai-playbook | `ojos/ai-playbook` | v8.8.8 | git タグのみ |'
} > "$FX"
FX_DCB="$(current_version "$FX" 'devcontainer-bootstrap')"
FX_PB="$(current_version "$FX" 'ai-playbook')"
rm -f "$FX"
if [[ "$FX_DCB" == "v9.9.9" ]] && [[ "$FX_PB" == "v8.8.8" ]]; then
  pass
else
  fail "抽出が値を返していない（DCB=[$FX_DCB] playbook=[$FX_PB]）"
fi

it "同じ抽出が、現行バージョン表と版更新表を取り違えない（意図的な負例）"
# 両表は同じパッケージ名で始まる。**列の形で区別できていないと、先に現れた行を
# 現行版として読む。**
#
# **版更新表の行を先に置く。** 実データは現行バージョン表が先にあるため、同じ並びの
# フィクスチャでは区別を外す変異が緑のまま通る（実測で踏んだ）。順序を入れ替えて
# 初めて、区別している処理が効いていることを示せる。
FX2="$(mktemp "${TMPDIR:-/tmp}/hist.XXXXXX")"
{
  printf '%s\n' '| devcontainer-bootstrap | v0.0.1 | 2026-01-01 | 古い版の要点 |'
  printf '%s\n' '| devcontainer-bootstrap | `ojos/devcontainer-bootstrap` | v1.0.0 | GitHub Release |'
} > "$FX2"
FX2_V="$(current_version "$FX2" 'devcontainer-bootstrap')"
rm -f "$FX2"
if [[ "$FX2_V" == "v1.0.0" ]]; then
  pass
else
  fail "現行バージョン表ではなく版更新表を読んだ: [$FX2_V]"
fi

it "同じ抽出が、存在しない版の行を「ある」と言わない（意図的な負例）"
FX3="$(mktemp "${TMPDIR:-/tmp}/hist.XXXXXX")"
printf '%s\n' '| devcontainer-bootstrap | v0.0.1 | 2026-01-01 | 要点 |' > "$FX3"
FOUND="$(history_has_row "$FX3" 'devcontainer-bootstrap' 'v9.9.9')"
NOTFOUND_OK=$?
HIT="$(history_has_row "$FX3" 'devcontainer-bootstrap' 'v0.0.1')"
rm -f "$FX3"
if [[ -z "$FOUND" ]] && [[ -n "$HIT" ]]; then
  pass
else
  fail "版更新表の判定が区別できていない（無い版=[$FOUND] ある版=[$HIT]）"
fi

# ── 比較の対照群（比較そのものが効いていることの固定）────────────────────────
#
# **実データは一致している。** 一致側だけを通しても「常に真」の実装と区別できない。
# 不一致のフィクスチャを同じ関数へ通し、落ちることを見る。

it "同じ比較が、一致する値を通し、違う値を落とす（意図的な負例）"
if same_version 'v1.2.3' 'v1.2.3' >/dev/null \
  && ! same_version 'v1.2.3' 'v1.2.4' >/dev/null; then
  pass
else
  fail "版の比較が区別できていない（同じ値と違う値で結果が変わらない）"
fi

it "同じ比較が、並びの 1 つでも違えば落とす（意図的な負例）"
if all_same_version 'v1.2.3' "$(printf 'v1.2.3\nv1.2.3\n')" >/dev/null \
  && ! all_same_version 'v1.2.3' "$(printf 'v1.2.3\nv9.9.9\n')" >/dev/null; then
  pass
else
  fail "並びの比較が区別できていない"
fi

it "同じ版更新表の判定が、行の有無で結果を変える（意図的な負例）"
# history_has_row は上でも負例を通しているが、**条件 2 の判定経路そのもの**が
# 効いていることをここで固定する。常に真へ変える変異はここで赤になる。
FX4="$(mktemp "${TMPDIR:-/tmp}/hist.XXXXXX")"
printf '%s\n' '| devcontainer-bootstrap | v1.0.0 | 2026-01-01 | 要点 |' > "$FX4"
if [[ -n "$(history_has_row "$FX4" 'devcontainer-bootstrap' 'v1.0.0')" ]] \
  && [[ -z "$(history_has_row "$FX4" 'devcontainer-bootstrap' 'v2.0.0')" ]]; then
  pass
else
  fail "版更新表の判定が行の有無で変わらない"
fi
rm -f "$FX4"

exit_with_result
