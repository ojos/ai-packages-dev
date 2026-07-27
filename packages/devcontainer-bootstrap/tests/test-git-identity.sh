#!/usr/bin/env bash
# 生成される git identity ガード（setup-git-identity.sh / verify-commit-identity.sh /
# .github/workflows/identity-guard.yml）を検証する。
#
# 背景:
#   local 設定を持たないリポジトリが黙って global へフォールバックしてコミットを
#   通す経路が塞がれていなかった。この穴により別アカウントの identity のコミットが
#   main に入る事故が起きた。ここではその 3 層（適用・検証・CI）が生成され、期待
#   どおり振る舞うことを一時 git リポジトリで確認する。
#
#   git config を汚さないよう、HOME / GIT_CONFIG_GLOBAL / GIT_CONFIG_SYSTEM を
#   サンドボックスへ向けてからテストする。ネットワークにも実トークンにも依存しない。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-git-identity"

# ── git 設定をサンドボックスへ隔離する ────────────────────────────────────────
SB="$(new_workdir)/idsb"
mkdir -p "$SB/home"
export HOME="$SB/home"
export GIT_CONFIG_GLOBAL="$SB/home/.gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
# credential.helper を先に仕込む。setup がこれを壊さないことを後で確認するため。
git config --global credential.helper store

# ── 生成 ──────────────────────────────────────────────────────────────────────
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
SETUP="$out/scripts/setup-git-identity.sh"
VERIFY="$out/scripts/verify-commit-identity.sh"
WF="$out/.github/workflows/identity-guard.yml"

# ── ヘルパー ──────────────────────────────────────────────────────────────────
# scripts/ の 1 階層上が git リポジトリになる構成で作る（スクリプトは親へ cd する）。
mk_repo() {
  local dir="$1"; shift
  mkdir -p "$dir/scripts"
  local f
  for f in "$@"; do cp "$out/scripts/$f" "$dir/scripts/"; done
  ( cd "$dir" && git init -q )
}

# identity の供給元はプロジェクト .env。ローダー（load-project-env.sh）を同梱し、
# .env を置いた状態を作る。env で直接渡す経路はもう無い。
mk_repo_with_env() {
  local dir="$1" name="$2" email="$3"; shift 3
  mk_repo "$dir" load-project-env.sh "$@"
  printf 'GIT_IDENTITY_NAME=%s\nGIT_IDENTITY_EMAIL=%s\n' "$name" "$email" > "$dir/.env"
}

run_setup() {
  local dir="$1"; shift
  ( cd "$dir" && bash scripts/setup-git-identity.sh "$@" )
}

# author/committer email を明示してコミットする（useConfigOnly 下でも env が identity を満たす）。
commit_as() {
  local dir="$1" ae="$2" ce="$3" msg="$4"
  ( cd "$dir" &&
    env GIT_AUTHOR_NAME=A GIT_AUTHOR_EMAIL="$ae" GIT_COMMITTER_NAME=C GIT_COMMITTER_EMAIL="$ce" \
        git commit --allow-empty -q -m "$msg" )
}

# ── 生成物の存在 ──────────────────────────────────────────────────────────────
it "setup-git-identity.sh が生成される"
assert_file_exists "$SETUP"

it "verify-commit-identity.sh が生成される"
assert_file_exists "$VERIFY"

it "identity-guard.yml が生成される"
assert_file_exists "$WF"

it "setup-git-identity.sh の構文が正しい"
if bash -n "$SETUP" 2>/dev/null; then pass; else fail "syntax error"; fi

it "verify-commit-identity.sh の構文が正しい"
if bash -n "$VERIFY" 2>/dev/null; then pass; else fail "syntax error"; fi

# ── on-attach 連携 ────────────────────────────────────────────────────────────
it "on-attach.sh が setup-git-identity.sh を呼ぶ"
if grep -q 'setup-git-identity.sh' "$out/scripts/on-attach.sh"; then pass; else fail "呼び出しがない"; fi

it "on-attach.sh は setup 失敗を捕捉して打ち切らない（if ! bash）"
if grep -q 'if ! bash "$HERE/setup-git-identity.sh"' "$out/scripts/on-attach.sh"; then pass; else fail "捕捉構文がない"; fi

it "on-attach.sh は setup 失敗時も exit 0 を保つ"
oa="$(new_workdir)/oa"
mk_repo_with_env "$oa" "Test User" "allowed@example.com" on-attach.sh setup-git-identity.sh
# global 設定の書き込みを ENOTDIR で失敗させ、setup を確実に非ゼロ終了させる。
blocker="$oa/blocker"; : > "$blocker"
( cd "$oa" && env GIT_CONFIG_GLOBAL="$blocker/gitconfig" GIT_CONFIG_SYSTEM=/dev/null \
    bash scripts/on-attach.sh >/dev/null 2>&1 )
assert_eq "$?" "0" "on-attach の終了コード"

# ── 適用（global 無害化 + local 適用） ────────────────────────────────────────
r="$(new_workdir)/r"
mk_repo_with_env "$r" "Test User" "allowed@example.com" setup-git-identity.sh

# 事前に別アカウントの global identity を仕込む。apply がこれを確実に削除し、
# 残存を握りつぶさないことを後続の「削除される」検証で担保する。
git config --global user.name "Stale Global"
git config --global user.email "stale@wrong.example"

it "適用が成功する"
if run_setup "$r" >/dev/null 2>&1; then pass; else fail "apply が非ゼロ終了"; fi

it "global の user.useConfigOnly が true になる"
assert_eq "$(git config --global --get user.useConfigOnly 2>/dev/null || echo '')" "true" "useConfigOnly"

it "global の user.name / user.email が削除される"
gn="$(git config --global --get user.name 2>/dev/null || echo '')"
ge="$(git config --global --get user.email 2>/dev/null || echo '')"
if [[ -z "$gn" && -z "$ge" ]]; then pass; else fail "global に identity が残る: name=$gn email=$ge"; fi

it "当リポジトリの local に .env の identity が入る"
assert_eq "$(cd "$r" && git config --local --get user.email 2>/dev/null || echo '')" "allowed@example.com" "local user.email"

it "credential.helper を「空 → gh」に固定する"
# 上位スコープ（system / エディタ注入）のヘルパーが応答しないよう、空文字で一覧を
# リセットしてから gh を置く。順序が逆だと上位スコープが先に応答して勝つ。
helpers="$(git config --global --get-all credential.helper 2>/dev/null | tr '\n' '|')"
assert_eq "$helpers" "|!gh auth git-credential|" "global credential.helper"

# ── 冪等性 / --check ──────────────────────────────────────────────────────────
it "冪等: 再適用で global 設定ファイルが変化しない"
cp "$GIT_CONFIG_GLOBAL" "$SB/snap1"
run_setup "$r" >/dev/null 2>&1
cp "$GIT_CONFIG_GLOBAL" "$SB/snap2"
if cmp -s "$SB/snap1" "$SB/snap2"; then pass; else fail "再適用で global 設定が変化した"; fi

it "--check が IDENTITY_SETUP_OK を返し exit 0"
co="$(run_setup "$r" --check 2>&1)"; crc=$?
if [[ "$crc" -eq 0 ]]; then
  assert_contains "$co" "IDENTITY_SETUP_OK" "--check 出力"
else
  fail "--check が非ゼロ終了 (rc=$crc): $(printf '%s' "$co" | tail -1)"
fi

# ── local 未設定リポジトリでの commit 失敗（本題） ────────────────────────────
it "local 設定を持たない別リポジトリでは git commit が非ゼロで失敗する"
nr="$(new_workdir)/nr"; mkdir -p "$nr"; ( cd "$nr" && git init -q )
if ( cd "$nr" &&
     env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL -u EMAIL \
         git commit --allow-empty -q -m x >/dev/null 2>&1 ); then
  fail "commit が成功してしまった（黙って global へフォールバックしている）"
else
  pass
fi

# ── verify-commit-identity ────────────────────────────────────────────────────
it "許可 author のみの履歴は IDENTITY_PASS / exit 0"
vr="$(new_workdir)/vr"; mk_repo "$vr" verify-commit-identity.sh
commit_as "$vr" "allowed@example.com" "allowed@example.com" c1
vo="$(cd "$vr" && env ALLOWED_AUTHOR_EMAILS="allowed@example.com" bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 0 ]]; then assert_contains "$vo" "IDENTITY_PASS" "verify 出力"; else fail "exit $vrc: $(printf '%s' "$vo" | tail -1)"; fi

it "committer に noreply@github.com を含むコミットは通す"
commit_as "$vr" "allowed@example.com" "noreply@github.com" c2
vo="$(cd "$vr" && env ALLOWED_AUTHOR_EMAILS="allowed@example.com" bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 0 ]]; then pass; else fail "committer noreply が弾かれた (exit $vrc)"; fi

it "許可外 author email を含む範囲は IDENTITY_FAIL / exit 1"
commit_as "$vr" "evil@other.example" "evil@other.example" c3
vo="$(cd "$vr" && env ALLOWED_AUTHOR_EMAILS="allowed@example.com" bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 1 ]]; then assert_contains "$vo" "IDENTITY_FAIL" "verify 出力"; else fail "許可外を通した (exit $vrc)"; fi

it "許可 email を解決できない場合は fail-closed（exit 1）"
vr2="$(new_workdir)/vr2"; mk_repo "$vr2" load-project-env.sh verify-commit-identity.sh
commit_as "$vr2" "allowed@example.com" "allowed@example.com" c1
( cd "$vr2" && env -u ALLOWED_AUTHOR_EMAILS -u GIT_IDENTITY_EMAIL \
    bash scripts/verify-commit-identity.sh --full >/dev/null 2>&1 )
assert_eq "$?" "1" "空 allowlist の終了コード"

it "環境の GIT_IDENTITY_EMAIL より .env の値が優先される"
# .env が唯一の供給元。シェルへ手で export した古い値が勝つと、許可 email が
# 実際の運用と食い違い、通すべきコミットを落とす／落とすべきものを通す。
printf 'GIT_IDENTITY_NAME=Test User\nGIT_IDENTITY_EMAIL=allowed@example.com\n' > "$vr2/.env"
vo="$(cd "$vr2" && env -u ALLOWED_AUTHOR_EMAILS GIT_IDENTITY_EMAIL="stale@wrong.example" \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 0 ]]; then
  assert_contains "$vo" "IDENTITY_PASS" ".env 優先の解決"
else
  fail "環境の古い値が .env に勝っている (exit $vrc): $(printf '%s' "$vo" | tail -1)"
fi

it "ALLOWED_AUTHOR_EMAILS があれば .env より優先される"
# CI はリポジトリ変数から渡す。ここが逆転すると CI の許可リストが効かなくなる。
vo="$(cd "$vr2" && env ALLOWED_AUTHOR_EMAILS="only-ci@example.com" \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 1 ]]; then
  assert_contains "$vo" "IDENTITY_FAIL" "env 最優先の解決"
else
  fail ".env が ALLOWED_AUTHOR_EMAILS に勝っている (exit $vrc)"
fi

it "ALLOWED_AUTHOR_EMAILS 未設定なら .env の GIT_IDENTITY_EMAIL をフォールバックに使う"
printf 'GIT_IDENTITY_NAME=Test User\nGIT_IDENTITY_EMAIL=allowed@example.com\n' > "$vr2/.env"
vo="$(cd "$vr2" && env -u ALLOWED_AUTHOR_EMAILS -u GIT_IDENTITY_EMAIL \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 0 ]]; then assert_contains "$vo" "IDENTITY_PASS" "フォールバック解決"; else fail "フォールバックが効かない (exit $vrc): $(printf '%s' "$vo" | tail -1)"; fi

# ── CI ワークフロー ───────────────────────────────────────────────────────────
it "identity-guard.yml が pull_request と push(main) の 2 系統を張る"
if grep -q 'pull_request:' "$WF" && grep -q 'push:' "$WF" && grep -q 'branches: \[main\]' "$WF"; then
  pass
else
  fail "2 系統の trigger が揃っていない"
fi

it "許可 author email はリポジトリ変数から渡す（固有 email を焼き込まない）"
if grep -q 'ALLOWED_AUTHOR_EMAILS: ${{ vars.ALLOWED_AUTHOR_EMAILS }}' "$WF"; then pass; else fail "vars.ALLOWED_AUTHOR_EMAILS の配線がない"; fi

it "ワークフローは判定をシェルへ委譲する（verify-commit-identity.sh を呼ぶだけ）"
if grep -q 'bash scripts/verify-commit-identity.sh' "$WF"; then pass; else fail "スクリプト呼び出しがない"; fi

it "生成物に固有 email が焼き込まれていない"
if grep -Eq '@(ojos|bascule)' "$SETUP" "$VERIFY" "$WF"; then
  fail "固有ドメインの email が生成物に含まれる"
else
  pass
fi

exit_with_result
