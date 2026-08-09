#!/usr/bin/env bash
# 雛形の所有関係を検証する。
#
# 以前は DCB が入口ファイルと second-opinion-review.sh の内容を埋め込んでいた。その結果、
# 規範（review-workflow.md）と実装（second-opinion-review.sh のプロンプト）が別パッケージへ
# 複製され、正本が 2 つになっていた。また DCB が規範パッケージの内部構造
# （role-contracts/ 等）をハードコードしていたため、規範側の再編で静かに壊れる
# 状態だった。
#
# ここでは「DCB は雛形を持たず、規範パッケージからコピーするだけ」という不変条件を
# 守る。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-templates"

TPL="$PLAYBOOK_SRC/templates"

# ── 規範パッケージ側に雛形が揃っているか ─────────────────────────────────────

it "規範パッケージが入口ファイルの雛形を持つ"
assert_file_exists "$TPL/entry.md"

it "規範パッケージがプロジェクト共通ルールの雛形を持つ"
assert_file_exists "$TPL/project-ai-rules.md"

it "規範パッケージが第二意見レビューの雛形を持つ"
assert_file_exists "$TPL/second-opinion-review.sh"

# ── DCB は内容を持たない ──────────────────────────────────────────────────────

it "DCB は入口ファイルの内容を持たない"
if grep -q '実行環境向け入口ファイル' "$BOOTSTRAP"; then
  fail "bootstrap.sh が入口ファイルの本文を埋め込んでいる"
else
  pass
fi

it "DCB はレビュー規範を複製していない"
# review-workflow.md が定めるゲート対象。DCB 側に現れたら複製。
if grep -q '致命バグ' "$BOOTSTRAP"; then
  fail "bootstrap.sh がレビュー規範を複製している"
else
  pass
fi

it "DCB は規範の内部ファイル名をハードコードしない"
# role-contracts/ 等の内部構造を知っていると、規範側の再編で静かに壊れる。
# コメント行を除いて検査する。
hits="$(grep -n 'role-contracts\|task-playbooks\|shared-ai-rules' "$BOOTSTRAP" \
  | grep -v '^\s*[0-9]*:\s*#' | grep -vc '^\s*[0-9]*:#' || true)"
if [[ "${hits:-0}" -eq 0 ]]; then
  pass
else
  fail "内部ファイル名への言及が $hits 件残っている:
$(grep -n 'role-contracts\|task-playbooks\|shared-ai-rules' "$BOOTSTRAP" | grep -v ':#' | head -5)"
fi

# ── 生成物は雛形と完全一致する（コピーであって再生成でない）──────────────────

out="$(new_workdir)/p"
run_bootstrap "$out" --with-playbook >/dev/null 2>&1

it "CLAUDE.md は雛形と完全一致する"
if diff -q "$out/CLAUDE.md" "$TPL/entry.md" >/dev/null 2>&1; then pass; else fail "雛形と一致しない"; fi

it "copilot-instructions.md は雛形と完全一致する"
if diff -q "$out/.github/copilot-instructions.md" "$TPL/entry.md" >/dev/null 2>&1; then pass; else fail "雛形と一致しない"; fi

it "project-ai-rules.md は雛形と完全一致する"
if diff -q "$out/.github/project-ai-rules.md" "$TPL/project-ai-rules.md" >/dev/null 2>&1; then pass; else fail "雛形と一致しない"; fi

it "second-opinion-review.sh は雛形と完全一致する"
if diff -q "$out/scripts/second-opinion-review.sh" "$TPL/second-opinion-review.sh" >/dev/null 2>&1; then pass; else fail "雛形と一致しない"; fi

it "雛形が欠けている規範ソースは失敗する"
broken="$(new_workdir)/broken"
mkdir -p "$broken/.ai-playbook"
cp "$PLAYBOOK_SRC/shared-ai-rules.md" "$broken/.ai-playbook/"
out2="$(new_workdir)/p"
output="$(run_bootstrap "$out2" --with-playbook --playbook-from "$broken" 2>&1)"
if [[ $? -ne 0 ]]; then
  assert_contains "$output" "template not found" "エラー出力"
else
  fail "雛形が無くても成功してしまった"
fi

# ── 規範パッケージ単独で 3 層構造を配線できる ────────────────────────────────
# DCB を介さない利用者（対応言語外、devcontainer 非使用、既存プロジェクト）が
# README の手順だけで完結できることを確認する。

it "DCB を使わずに雛形のコピーだけで 3 層が揃う"
solo="$(new_workdir)/solo"
mkdir -p "$solo/.github"
cp -R "$PLAYBOOK_SRC" "$solo/.ai-playbook"
cp "$solo/.ai-playbook/templates/project-ai-rules.md" "$solo/.github/project-ai-rules.md"
cp "$solo/.ai-playbook/templates/entry.md" "$solo/CLAUDE.md"
missing=""
for f in .ai-playbook/shared-ai-rules.md .github/project-ai-rules.md CLAUDE.md; do
  [[ -f "$solo/$f" ]] || missing="$missing $f"
done
if [[ -z "$missing" ]]; then pass; else fail "3 層が揃わない:$missing"; fi

it "単独導入でも入口ファイルの参照先が実在する"
missing=""
for f in .ai-playbook/shared-ai-rules.md .ai-playbook/role-contracts/planner.md \
         .ai-playbook/task-playbooks/pr-review.md .ai-playbook/review-workflow.md; do
  [[ -f "$solo/$f" ]] || missing="$missing $f"
done
if [[ -z "$missing" ]]; then pass; else fail "参照先が不在:$missing"; fi

# ── 雛形が書く --with-* フラグ名が実装に存在する ──────────────────────────────
#
# 雛形の本文は bootstrap.sh のフラグ名を書き写している。書き写した一覧は必ず古く
# なる（shared-ai-rules.md 12 章「一覧の複製は機械照合で担保する」）。実例として、
# --with-copilot からリモートレビュー機構を --with-copilot-review へ分離したあと、
# 雛形は旧名のまま残り、両パッケージのテストは緑のままだった。旧名は今も受理される
# ため、利用者は「指定したのにワークフローが置かれない」ことに気づけない。
#
# **検知するもの**: 雛形の *.md 本文に現れる --with-<名前> が、bootstrap.sh の引数
# パースが受理しないフラグ名であること。改名・廃止・打ち間違いが該当する。
#
# **検知しないもの**（塞げていないので、塞げているかのように読まないこと）:
#   - フラグと配置物の対応。「--with-X で Y が置かれる」の Y が誤っていても通る。
#     ここまで照合するには雛形の自然文を解析することになり、書き方の変更で壊れる
#     脆い検査になるため、意図して範囲外にしている。上記の分離のような改名の
#     取りこぼしは、名前の存在だけを見ても捕まる。
#   - 記載の欠落。雛形が触れるべきフラグに触れていなくても通る（書かれていない
#     ものは抽出されない）。
#   - *.md 以外の雛形（*.yml / *.sh）の本文。
#
# 実装側の抽出は lib.sh の impl_flags() を使う（test-readme-flags.sh と共用）。
# 抽出のアンカーを 2 か所に持つと、片方だけが bootstrap.sh の変更に追随して、
# もう片方が黙って空を返す。

it "bootstrap.sh の引数パースから --with-* の受理集合を抽出できる"
# 抽出が空になると、以降の照合は「空集合に含まれるかを誰にも問わない」形で緑に
# なる。アンカーの書式が変わったときに黙って無効化されないよう、先に検査する。
accepted_with="$(impl_flags | grep '^--with-' || true)"
if [[ -n "$accepted_with" ]]; then
  pass
else
  fail "引数パースから --with-* を抽出できなかった（while ループか case ラベルの書式が変わった可能性）"
fi

it "雛形の本文から --with-* の言及を抽出できる"
# こちらも空抽出で素通ししない。雛形からフラグの案内を意図して消した場合は、この
# 検査が何も守らなくなるので、消した側が判断して書き換えること。
# `--with-*` のようなワイルドカード表記は拾わない（名前を 1 文字以上要求する）。
mentioned_with="$(grep -oh -- '--with-[a-z0-9][a-z0-9-]*' "$TPL"/*.md 2>/dev/null | sort -u)"
if [[ -n "$mentioned_with" ]]; then
  pass
else
  fail "雛形の *.md に --with-* の言及が 1 つも無い（案内を消したなら本検査の要否を見直す）"
fi

it "雛形が書く --with-* フラグ名がすべて bootstrap.sh に実在する"
if [[ -z "$accepted_with" || -z "$mentioned_with" ]]; then
  fail "前段の抽出に失敗しているため照合できない"
else
  unknown=""
  for flag in $mentioned_with; do
    if ! printf '%s\n' "$accepted_with" | grep -qx -- "$flag"; then
      # どの雛形に書かれているかまで出す。雛形は複数あり、名前だけでは直す先が
      # 分からない。
      where="$(grep -l -- "$flag" "$TPL"/*.md 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
      unknown="$unknown $flag($where)"
    fi
  done
  if [[ -z "$unknown" ]]; then
    pass
  else
    fail "bootstrap.sh が受理しないフラグ名を雛形が書いている:$unknown
     受理集合: $(printf '%s' "$accepted_with" | tr '\n' ' ')"
  fi
fi

exit_with_result
