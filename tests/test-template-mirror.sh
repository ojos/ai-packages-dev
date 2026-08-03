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
# 対象の決め方（#227 で 1 本から scripts/* 全件の仕分けへ広げた）:
#
#   一致必須（MIRRORED_RELS）  — 正本のヒアドキュメントがそのまま生成物になるもの。
#                                写しとバイト一致すべきで、ずれたら追随漏れ。
#   検査対象外（EXCLUDED_RELS）— 正本が置換プレースホルダ（__..._LINES__）を持ち、
#                                生成時に構成へ応じて展開されるもの。展開後の姿は
#                                生成条件ごとに変わるため、バイト一致は原理的に
#                                成立しない。写しが独自に進んでいるのも、この
#                                「プロジェクトが埋める部分」に限られる。
#
# 除外は「検査していない」ではなく「検査対象外と判断した」ことを示す。両者を読み
# 分けられるよう、除外理由を EXCLUDED_RELS の定義に併記したうえで、下記 2 つを
# 機械で担保する。
#
#   1. 網羅性: template_rel_paths() が列挙する scripts/* は、MIRRORED か EXCLUDED の
#      どちらかに必ず属する。テンプレートを増やしたとき、どちらにも書かないまま
#      黙って検査を素通りする経路を残さない。
#   2. 除外理由の維持: EXCLUDED の各テンプレートが実際にプレースホルダを持つ。
#      プレースホルダが外れた（＝そのまま配布される形になった）のに除外のまま残ると、
#      理由が空洞化した除外が積み上がる。
#
# scripts/ 以外のテンプレート（.env.example / .devcontainer/* / identity-guard.yml）を
# 対象にしない理由: いずれも生成時の置換またはプロジェクト側の編集を前提とする。
# 本テストが扱うのは「同じシェルスクリプトが 2 か所にあることによる追随漏れ」で、
# それらは構造が異なる。scripts/gemini-review.sh も対象外で、正本は
# .ai-playbook/templates/gemini-review.sh 側にありヒアドキュメント方式ではない。
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

# 一致を必須にする写し。プレースホルダを持たず、正本がそのまま生成物になるもの。
MIRRORED_RELS='scripts/load-project-env.sh
scripts/loop-gate.sh
scripts/on-attach.sh
scripts/setup-git-identity.sh
scripts/verify-commit-identity.sh
scripts/verify.sh'

# 検査対象外にする写し。すべて「正本が置換プレースホルダを持つ」ことが理由で、
# 一致させたくないのではなく一致し得ない。個別の内訳:
#
#   acceptance.sh       __ACCEPTANCE_CHECK_LINES__。正本は冒頭で「プロジェクトが
#                       所有・編集する」と宣言する雛形で、写しはこのリポジトリ自身の
#                       CI を完全ミラーする実体（neutrality 等のモノレポ固有検査を
#                       持つのが正しい姿）。揃えると配布物へモノレポ固有の検査が
#                       流れ込み、パッケージ中立性を壊す。CI との一致は
#                       tests/test-ci-mirror.sh が別に担保している。
#   fix-mount-owner.sh  __MOUNT_OWNER_LINES__。永続 volume の選択（--with-*）で
#                       行数が変わる。
#   install-ai-tools.sh __AI_INSTALL_LINES__。導入する AI CLI の選択で行が変わる。
#                       写しの冒頭コメントが「引数を取らない」と説明しているのも、
#                       展開後の姿に対する説明であり乖離ではない。
#   post-rebuild-check.sh
#                       __VOLUME_CHECK_LINES__ / __RUNTIME_CHECK_LINES__ /
#                       __WITH_CHECK_LINES__。加えて写しは shellcheck の実在検査を
#                       持つ（このリポジトリの受け入れ検証が要求するため）。これは
#                       モノレポ固有で、配布物へ持ち込む対象ではない。
EXCLUDED_RELS='scripts/acceptance.sh
scripts/fix-mount-owner.sh
scripts/install-ai-tools.sh
scripts/post-rebuild-check.sh'

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

it "生成対象の scripts/* がすべて一致必須か検査対象外のどちらかに分類されている"
# 分類漏れを機械で落とす。テンプレートを足したときに、どちらの一覧にも書かないまま
# 「検査されていないのか、対象外と判断したのか」が読めない状態になるのを防ぐ。
assert_same_set \
  "$(printf '%s\n' "$TEMPLATE_RELS" | grep '^scripts/')" \
  "$(printf '%s\n%s\n' "$MIRRORED_RELS" "$EXCLUDED_RELS")" \
  "bootstrap.sh の生成対象" \
  "本テストの分類"

for rel in $EXCLUDED_RELS; do
  # 抽出の成否を先に切り分ける。抽出が空でも次のプレースホルダ検査は素通しせず
  # 落ちるが、「プレースホルダが消えている」という**原因と違うメッセージ**になる。
  # 実際の原因は case ラベルやヒアドキュメント書式の変更で、直す先が別の場所に
  # あるため、次に踏んだ人を遠回りさせる。MIRRORED 側と同じく段を分ける。
  it "$rel のヒアドキュメント本文を抽出できる"
  body="$(extract_template "$rel")"
  if [[ -n "$body" ]]; then
    pass
  else
    fail "$rel のヒアドキュメントを抽出できない（case ラベルか cat <<'TMPL' の書式が変わった可能性）"
    continue
  fi

  it "$rel が置換プレースホルダを持つ（検査対象外である理由が保たれている）"
  # 除外理由は「生成時に展開されるので一致し得ない」の 1 点。プレースホルダが
  # 外れたらその理由は成立せず、一致必須へ移すべき状態になっている。
  if printf '%s\n' "$body" | grep -q '^__[A-Z_]*LINES__$'; then
    pass
  else
    fail "$rel からプレースホルダが消えている（MIRRORED_RELS へ移すか、除外理由を書き直す）"
  fi
done

for rel in $MIRRORED_RELS; do
  copy="$REPO_ROOT/$rel"

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
