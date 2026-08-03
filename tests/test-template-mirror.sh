#!/usr/bin/env bash
# 配布テンプレートの正本と、この開発リポジトリが持つ写しが食い違っていないことを
# 検査する。
#
#   正本: packages/devcontainer-bootstrap/bootstrap.sh の get_template_content() 内
#         ヒアドキュメント（bootstrap が生成物へ書き出す実体）
#   写し: この開発リポジトリ直下の scripts/*.sh（自分自身が bootstrap の生成物を
#         取り込んで使っている分）
#
# 新設の理由: 同じ内容が 2 か所にあるのに、一致を検査する仕組みが無かった。片方だけ
# 直しても両方のテストが緑になるため、配布物と手元が黙って食い違う。実際に #223 の
# 判定ロジック拡張は、正本と写しの 2 か所を同時に直す必要がある変更だった。
#
# 対象を scripts/verify-commit-identity.sh に限る理由: 他のテンプレート
# （setup-git-identity.sh / acceptance.sh 等）は、この開発リポジトリ側の写しが既に
# 独自に進んでいる。それらを一致必須にするのは「写しを正本へ揃え直す」別の作業で、
# ここで巻き込むと本来検査したい 1 件まで落ちたままになる。検査対象を増やすときは、
# 先に写しを揃えてから DIRECTORY 下の定義へ足す。
#
# 末尾改行の差は許容する。ヒアドキュメントは必ず改行で終わり、写しは末尾改行を
# 持たない場合がある。この差はシェルの挙動に影響せず、ここで落としても直す先が
# 「改行を足す」以外に無い。コマンド置換が末尾改行を落とすことをそのまま利用する。
#
# 抽出のアンカーは case ラベル `    'scripts/...')` と `      cat <<'TMPL'` の組。
# 行番号を決め打ちしない（bootstrap.sh は頻繁に行がずれる）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-template-mirror"

BOOTSTRAP="$REPO_ROOT/packages/devcontainer-bootstrap/bootstrap.sh"

# 一致を必須にする写し。増やすときは、先に写しを正本へ揃えてから足す。
MIRRORED_RELS='scripts/verify-commit-identity.sh'

# get_template_content() の case ラベルから、指定パスのヒアドキュメント本文を取り出す。
# シングルクォートは awk へ変数で渡す（awk のプログラム自体をシングルクォートで
# 囲んでいるため、リテラルで書くと読めなくなる）。
extract_template() {
  local rel="$1"
  awk -v rel="$rel" -v q="'" '
    $0 == "    " q rel q ")" { seen = 1; next }
    seen && $0 == "      cat <<" q "TMPL" q { inside = 1; seen = 0; next }
    inside && $0 == "TMPL" { exit }
    inside { print }
  ' "$BOOTSTRAP"
}

# template_rel_paths() が列挙する相対パス。ここから外れた写しを検査し続けても、
# 「生成されないファイルと一致している」ことしか言えない。
TEMPLATE_RELS="$(awk -v q="'" '
  /^template_rel_paths\(\)/ { inside = 1; next }
  inside && /^}/ { inside = 0 }
  inside && $0 ~ ("^ +" q ".+" q " *\\\\?$") {
    gsub(/^ +/, ""); gsub(/ *\\$/, ""); gsub(q, ""); print
  }
' "$BOOTSTRAP")"

it "bootstrap.sh から生成対象の相対パス一覧を抽出できる"
# 抽出そのものが空になると、以降の照合は「空と空を比べて緑」になる。アンカーの
# 書式が変わったときに黙って無効化されないよう、先に抽出結果を検査する。
if [[ -n "$TEMPLATE_RELS" ]]; then
  pass
else
  fail "template_rel_paths() から相対パスを抽出できなかった"
fi

for rel in $MIRRORED_RELS; do
  copy="$REPO_ROOT/$rel"

  it "$rel が template_rel_paths() に列挙されている"
  if printf '%s\n' "$TEMPLATE_RELS" | grep -qx -- "$rel"; then
    pass
  else
    fail "$rel が生成対象から外れている（改名なら本テストの対象も直す）"
  fi

  it "$rel の写しがこのリポジトリに存在する"
  if [[ -f "$copy" ]]; then
    pass
  else
    fail "写しが見つからない: $copy"
  fi

  tmpl_body="$(extract_template "$rel")"

  it "$rel のヒアドキュメント本文を抽出できる"
  # 空抽出の素通しを防ぐ。あわせて生成物として成立する形（shebang で始まり
  # main の呼び出しで終わる）であることまで見る。case ラベルは見つかったが
  # 別のヒアドキュメントを拾っていた、という取り違えを検出するため。
  if [[ -z "$tmpl_body" ]]; then
    fail "ヒアドキュメント本文が空（case ラベルまたは cat <<'TMPL' の書式が変わった可能性）"
  elif [[ "$tmpl_body" != '#!/usr/bin/env bash'* ]]; then
    fail "抽出結果が shebang で始まらない（別のヒアドキュメントを拾っている）"
  else
    pass
  fi

  it "$rel のヒアドキュメントと写しが一致する"
  # コマンド置換が両側の末尾改行を落とすため、末尾改行の差だけは通る。
  if [[ ! -f "$copy" || -z "$tmpl_body" ]]; then
    fail "前段の抽出に失敗しているため照合できない"
  elif [[ "$tmpl_body" == "$(cat "$copy")" ]]; then
    pass
  else
    detail="$(diff <(printf '%s\n' "$tmpl_body") <(printf '%s\n' "$(cat "$copy")") \
      | head -n 12 | tr '\n' '/')"
    fail "bootstrap.sh のヒアドキュメントと $rel が食い違う（両方を同時に直す）: $detail"
  fi
done

exit_with_result
