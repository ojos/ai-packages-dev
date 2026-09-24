#!/usr/bin/env bash
# リリース資産への artifact attestation の配線を機械照合する回帰テスト。
#
# ## なぜ要るか
#
# attestation は **リリースを実行しないと確かめられない**（release.yml は
# workflow_dispatch のみで、実行には公開リポジトリへの副作用が伴う）。配線が壊れても
# 次のリリースまで誰も気づかない。壊れ方は静かで、「発行されないまま成功する」形に
# なりうる（attest ステップが if で飛ぶ、権限宣言が消える、digest の受け渡し名が
# 食い違う）。ここでは**宣言と受け渡しの一致**までを見る。
#
# ## この検査が見ないこと
#
# **実際に発行できることは見ない。** それは手動リリース 1 回の実測でしか分からない。
# #340 では使い捨てのワークフローで発行と検証を実測し、票へ記録した。
#
# 依存はコアユーティリティ（awk / sed / grep）のみ。bash 3.2 互換を維持する。

set -uo pipefail
export LC_ALL=C
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-release-attestation"

WF="$REPO_ROOT/.github/workflows/release.yml"
SCRIPT="$REPO_ROOT/scripts/release-packages.sh"

# permissions_block <ファイル>
#   permissions: の配下だけを取り出す。**ファイル全体へ当ててはいけない。**
#   コメントや run: の中に `attestations: write` のような綴りがあると、宣言が消えても
#   当たり続けて偽陰性になる。ブロックの終わりは、宣言より浅いか同じ字下げの非空行。
permissions_block() {
  awk '
    /^[[:space:]]*permissions:[[:space:]]*$/ {
      inblock = 1
      indent = match($0, /[^ ]/)
      next
    }
    inblock {
      if ($0 ~ /^[[:space:]]*$/) next
      cur = match($0, /[^ ]/)
      if (cur <= indent) { inblock = 0; next }
      print
    }
  ' "$1"
}

# declares <ファイル> <権限名> <値>
#   permissions の配下でその権限が宣言されているか。
#
# **行頭から行末までを固定する**（`^[[:space:]]*<名前>:[[:space:]]*<値>[[:space:]]*$`）。
# これだけでコメント行は当たらない（`#` が行頭に来るため）。**コメントを落とす処理は
# 足さない。** それを正当化できる負例を作れず、変異をかけても緑のまま残るためである
# （実測で確かめた。効かない機構は置かない）。
#
# **permissions の配下へ絞るのは別の理由である。** run: のヒアドキュメントなどが
# 行頭から `attestations: write` と書く形は、アンカーだけでは区別できない。
declares() {
  { permissions_block "$1" | grep -nE "^[[:space:]]*$2:[[:space:]]*$3[[:space:]]*$" || true; }
}

it "release.yml が id-token: write を宣言している"
if [[ -n "$(declares "$WF" 'id-token' 'write')" ]]; then
  pass
else
  fail "id-token: write が permissions に無い（OIDC でこの実行を名乗れず attestation を発行できない）"
fi

it "release.yml が attestations: write を宣言している"
if [[ -n "$(declares "$WF" 'attestations' 'write')" ]]; then
  pass
else
  fail "attestations: write が permissions に無い（発行結果を書き込めない）"
fi

it "同じ判定が、宣言されていない権限を宣言済みとみなさない（意図的な負例）"
# 「常に当たる」実装でも上の 2 件は通ってしまうため、通らない側も通す。
if [[ -z "$(declares "$WF" 'packages' 'write')" ]]; then
  pass
else
  fail "宣言していない権限を宣言済みと判定した"
fi

it "同じ判定が、permissions の外の宣言を宣言とみなさない（意図的な負例）"
# **この負例でしか、ブロックへ絞る処理の有無を区別できない。** アンカーだけの実装は
# run: のヒアドキュメントが行頭から書いた宣言を拾う。コメント行はアンカーだけで
# 落ちるので、負例にしても区別にならない（実測）。
FAKE="$(mktemp "${TMPDIR:-/tmp}/wf.XXXXXX")"
{
  printf '%s\n' 'permissions:'
  printf '%s\n' '  contents: read'
  printf '%s\n' 'jobs:'
  printf '%s\n' '  x:'
  printf '%s\n' '    steps:'
  printf '%s\n' '      - run: |'
  printf '%s\n' "          cat <<'Y'"
  printf '%s\n' 'attestations: write'
  printf '%s\n' 'Y'
} > "$FAKE"
FAKE_HITS="$(declares "$FAKE" 'attestations' 'write')"
rm -f "$FAKE"
if [[ -z "$FAKE_HITS" ]]; then
  pass
else
  fail "permissions の外の綴りを宣言とみなした: $FAKE_HITS"
fi

it "attestation を発行するステップがある"
if [[ -n "$( { grep -nF 'actions/attest-build-provenance' "$WF" || true; } )" ]]; then
  pass
else
  fail "attest-build-provenance を使うステップが無い"
fi

it "対象はパスではなく digest で渡している"
# 資産は一時クローンの中にあり、ステップからパスで指せない。subject-path へ
# 切り替わっていたら、その前提が崩れている。
if [[ -n "$( { grep -nF 'subject-digest:' "$WF" || true; } )" ]] \
  && [[ -z "$( { grep -nE '^[[:space:]]*subject-path:' "$WF" || true; } )" ]]; then
  pass
else
  fail "subject-digest で渡していない（または subject-path が混ざっている）"
fi

it "対象が無い実行では発行しない（if で守っている）"
# DCB を公開しない実行（playbook だけのリリース）では digest が作られない。
# 守りが外れると、対象の無い発行で失敗するか、空の対象で発行しうる。
if [[ -n "$( { grep -nE "^[[:space:]]*if:[[:space:]]*steps\..*outputs\.digest[[:space:]]*!=" "$WF" || true; } )" ]]; then
  pass
else
  fail "attest ステップに digest の有無による if が無い"
fi

# ── 受け渡しの一致 ────────────────────────────────────────────────────────────

it "workflow が読む digest のファイル名を、スクリプトが書く名前と一致させている"
# **ここが食い違うと、発行が静かに飛ぶ。** workflow は
# `<ATTEST_SUBJECTS_DIR>/<名前>.sha256` を読み、スクリプトは `$pkg_name.sha256` を
# 書く。pkg_name は generate_standard_assets の呼び出し側が渡す。
WF_NAME="$( { grep -oE '/[a-z0-9-]+\.sha256' "$WF" || true; } | head -n 1 | sed 's#^/##; s#\.sha256$##' )"
SCRIPT_WRITES="$( { grep -nF '$pkg_name.sha256' "$SCRIPT" || true; } )"
SCRIPT_CALLS="$( { grep -noE 'generate_standard_assets "[^"]*" "[a-z0-9-]+"' "$SCRIPT" || true; } | sed 's/.*"\([a-z0-9-]*\)"$/\1/' )"
if [[ -z "$WF_NAME" ]]; then
  fail "workflow から読み取るファイル名を抽出できない"
elif [[ -z "$SCRIPT_WRITES" ]]; then
  fail "スクリプトが \$pkg_name.sha256 を書いていない"
elif [[ -z "$SCRIPT_CALLS" ]]; then
  fail "generate_standard_assets の呼び出しから package 名を抽出できない"
elif [[ -n "$(printf '%s\n' "$SCRIPT_CALLS" | grep -xF "$WF_NAME" || true)" ]]; then
  pass
else
  fail "workflow が読む名前「$WF_NAME」が、スクリプトの呼び出し（$(printf '%s' "$SCRIPT_CALLS" | tr '\n' ' ')）に無い"
fi

it "スクリプトは環境変数が無ければ digest を書かない"
# 手元の dry-run やテストは Actions の外で走る。この仕組みを前提にしない。
if [[ -n "$( { grep -nF 'ATTEST_SUBJECTS_DIR:-' "$SCRIPT" || true; } )" ]]; then
  pass
else
  fail "ATTEST_SUBJECTS_DIR の未設定を許す書き方になっていない"
fi

it "dry-run は資産生成より前に終わる（発行が起きない）"
# --execute が無ければ exit 0 する位置が、generate_standard_assets の呼び出しより
# 前にあることを見る。順序が逆になると dry-run でも発行を試みる。
EXIT_LINE="$( { grep -nE '^if \[\[ "\$EXECUTE" != "true" \]\]; then' "$SCRIPT" || true; } | head -n 1 | cut -d: -f1)"
GEN_LINE="$( { grep -nE '^[[:space:]]*generate_standard_assets ' "$SCRIPT" || true; } | head -n 1 | cut -d: -f1)"
if [[ -z "$EXIT_LINE" ]] || [[ -z "$GEN_LINE" ]]; then
  fail "行番号を取得できない（EXECUTE の分岐=$EXIT_LINE / 資産生成=$GEN_LINE）"
elif [[ "$EXIT_LINE" -lt "$GEN_LINE" ]]; then
  pass
else
  fail "dry-run の exit が資産生成より後にある（$EXIT_LINE >= $GEN_LINE）"
fi

exit_with_result
