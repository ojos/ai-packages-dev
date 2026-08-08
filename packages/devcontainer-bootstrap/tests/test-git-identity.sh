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

# ── system スコープの credential.helper の可視化 ──────────────────────────────
# --check の 6) は global、7) は実効値しか見ないため、system に置かれたヘルパーは
# どちらの出力にも現れない。遮断は 7) が実測しているので、ここで固定するのは
# 「存在の事実が出力に現れること」と「それで判定が変わらないこと」の 2 点。
#
# system スコープを実際に書き換えない。/etc/gitconfig はランナー共有で、テストが
# 触ると他のジョブや利用者の環境まで巻き込む。git 自身の差し替え口である
# GIT_CONFIG_SYSTEM を一時ファイルへ向ける（このファイルは冒頭で既にサンドボックス
# 用に /dev/null へ向けてあり、同じ機構の延長で書ける）。検査部分を関数として
# 切り出して単体で呼ぶ案は採らない。ここで見たいことの半分は「--check が失敗しない」
# ことであり、それは --check を丸ごと通さないと確かめられない。
it "system に credential.helper が無ければ OK を出す"
# サンドボックスの GIT_CONFIG_SYSTEM は /dev/null。前段の --check 出力を再利用する。
assert_contains "$co" "OK  system スコープに credential.helper は無い" "--check 出力"

it "system に credential.helper があれば INFO として列挙する"
sysconf="$SB/fake-system-gitconfig"
printf '[credential]\n\thelper = !fake-system-helper\n' > "$sysconf"
so="$(cd "$r" && env GIT_CONFIG_SYSTEM="$sysconf" bash scripts/setup-git-identity.sh --check 2>&1)"; src=$?
assert_contains "$so" "INFO   !fake-system-helper" "--check 出力"

it "system に credential.helper があっても --check は失敗しない"
# 置く側が接続のたびに書き戻す構成では常時検出され続ける。ここを失敗にすると
# 常時赤になり、赤を無視する習慣を生む。判定へ影響させないことをここで固定する。
if [[ "$src" -eq 0 ]]; then
  assert_contains "$so" "IDENTITY_SETUP_OK" "--check 出力"
else
  fail "system helper の検出で --check が落ちた (rc=$src): $(printf '%s' "$so" | tail -1)"
fi

it "system の credential.helper が空文字でも「無い」と誤判定しない"
# `helper = ` に対して --get-all は空行 1 件を返す。これをコマンド置換で 1 つの
# 文字列として受けると末尾改行が落ち、「1 件ある」と「0 件」が区別できなくなる。
# キーがあるのに OK を出すのは、この検査が唯一報告すべきことを取り違えた状態。
printf '[credential]\n\thelper = \n' > "$sysconf"
eo="$(cd "$r" && env GIT_CONFIG_SYSTEM="$sysconf" bash scripts/setup-git-identity.sh --check 2>&1)"; erc=$?
if [[ "$erc" -eq 0 ]]; then
  assert_contains "$eo" "INFO   <空文字>" "--check 出力"
else
  fail "空文字の system helper で --check が落ちた (rc=$erc): $(printf '%s' "$eo" | tail -1)"
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

it "許可 email に glob メタ文字があってもファイル名で展開されない"
# クォートなしの配列代入は単語分割と同時にパス名展開も行う。許可リストが
# リポジトリ内のファイル名で変わると、検知層の判定が検査対象の中身に左右される。
#
# プローブに 'allowed@*.com' を使う。ドメイン一括許可として解釈されるのは
# '@example.com' / '*@example.com' の 2 形だけで、この形はどちらにも当たらないため
# 完全一致でしか判定されず、どんな author にも一致してはならない。逆に
# '*@example.com' はドメイン形として正しく通るようになったので、展開の有無を
# 区別するプローブには使えない（通っても展開のせいか許可のせいか判別できない）。
vr3="$(new_workdir)/vr3"; mk_repo "$vr3" verify-commit-identity.sh
commit_as "$vr3" "allowed@example.com" "allowed@example.com" c1
# author と同名のファイルをルートに置く。展開が起きるなら許可リストが
# 'allowed@example.com' になり、誤って通してしまう。
: > "$vr3/allowed@example.com"
vo="$(cd "$vr3" && env ALLOWED_AUTHOR_EMAILS='allowed@*.com' \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
rm -f "$vr3/allowed@example.com"
vo2="$(cd "$vr3" && env ALLOWED_AUTHOR_EMAILS='allowed@*.com' \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc2=$?
if [[ "$vrc" -eq 1 && "$vrc2" -eq 1 ]]; then
  assert_contains "$vo" "IDENTITY_FAIL" "glob 展開の抑止"
else
  fail "ファイルの有無で判定が変わった (あり: exit $vrc / なし: exit $vrc2)"
fi

# ── GitHub 由来コミット（noreply 経路） ───────────────────────────────────────
# GitHub 側で「メールアドレスを非公開にする」を有効にしていると、PR のマージや
# web UI での編集で作られるコミットの author は <login>@users.noreply.github.com に
# なる。committer は常に noreply@github.com。ローカルの identity 適用漏れとは
# 発生経路が別なので、許可リストへ個別 email を足して回る運用にしない。
it "committer が noreply@github.com なら noreply 形の author を通す"
vr4="$(new_workdir)/vr4"; mk_repo "$vr4" verify-commit-identity.sh
commit_as "$vr4" "1234567+octocat@users.noreply.github.com" "noreply@github.com" gh1
vo="$(cd "$vr4" && env ALLOWED_AUTHOR_EMAILS="allowed@example.com" \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 0 ]]; then
  assert_contains "$vo" "IDENTITY_PASS" "noreply 経路の許可"
else
  fail "GitHub 由来コミットが弾かれた (exit $vrc): $(printf '%s' "$vo" | tail -1)"
fi

it "author のローカル部に @ を含む noreply 形は拒否する"
# 末尾一致だけで見ると x@evil.com@users.noreply.github.com が通る。git は author
# email を検証しないため、この形は実際に作れる。ここが通ると許可の根拠（GitHub が
# 割り当てた email であること）が崩れる。
vr5="$(new_workdir)/vr5"; mk_repo "$vr5" verify-commit-identity.sh
commit_as "$vr5" "x@evil.com@users.noreply.github.com" "noreply@github.com" gh2
vo="$(cd "$vr5" && env ALLOWED_AUTHOR_EMAILS="allowed@example.com" \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 1 ]]; then
  assert_contains "$vo" "IDENTITY_FAIL" "@ 二重混入の拒否"
else
  fail "@ を 2 つ持つ author を通した (exit $vrc)"
fi

it "committer が noreply@github.com でなければ noreply 形の author も拒否する"
# 許可を committer に縛らないと、ローカルで author だけ noreply 形に詐称した
# コミットが通り、identity 適用漏れの検知層としての意味が消える。
vr6="$(new_workdir)/vr6"; mk_repo "$vr6" verify-commit-identity.sh
commit_as "$vr6" "octocat@users.noreply.github.com" "allowed@example.com" gh3
vo="$(cd "$vr6" && env ALLOWED_AUTHOR_EMAILS="allowed@example.com" \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 1 ]]; then
  assert_contains "$vo" "IDENTITY_FAIL" "committer 条件の必須化"
else
  fail "committer が GitHub でないのに noreply 形 author を通した (exit $vrc)"
fi

# ── ドメイン一括許可 ──────────────────────────────────────────────────────────
it "'@example.com' 形のドメイン許可が効く"
vr7="$(new_workdir)/vr7"; mk_repo "$vr7" verify-commit-identity.sh
commit_as "$vr7" "member@example.com" "member@example.com" d1
vo="$(cd "$vr7" && env ALLOWED_AUTHOR_EMAILS='@example.com' \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 0 ]]; then
  assert_contains "$vo" "IDENTITY_PASS" "'@domain' 形の許可"
else
  fail "'@example.com' がドメイン許可として効かない (exit $vrc): $(printf '%s' "$vo" | tail -1)"
fi

it "'*@example.com' 形のドメイン許可も同じく効く"
# 2 形を等価に扱う。書き手がどちらを選んでも結果が変わらないことを保証する。
vo="$(cd "$vr7" && env ALLOWED_AUTHOR_EMAILS='*@example.com' \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 0 ]]; then
  assert_contains "$vo" "IDENTITY_PASS" "'*@domain' 形の許可"
else
  fail "'*@example.com' がドメイン許可として効かない (exit $vrc): $(printf '%s' "$vo" | tail -1)"
fi

it "ドメイン許可は別ドメインへ波及しない"
# 末尾一致だけで見ると evil-example.com のような接尾辞の一致も通る。区切りの
# '@' ごと突き合わせているかを確認する。
vr8="$(new_workdir)/vr8"; mk_repo "$vr8" verify-commit-identity.sh
commit_as "$vr8" "member@evil-example.com" "member@evil-example.com" d2
vo="$(cd "$vr8" && env ALLOWED_AUTHOR_EMAILS='@example.com' \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 1 ]]; then
  assert_contains "$vo" "IDENTITY_FAIL" "別ドメインの拒否"
else
  fail "接尾辞が一致するだけの別ドメインを通した (exit $vrc)"
fi

it "'*' 単体は何も許可しない"
# 設定ミスの '*' 1 文字で全 email が通ると、検知層が黙って無効化される。
# ドメイン形に限定した理由そのものなので、ここを最優先で固定する。
vr9="$(new_workdir)/vr9"; mk_repo "$vr9" verify-commit-identity.sh
commit_as "$vr9" "evil@other.example" "evil@other.example" d3
vo="$(cd "$vr9" && env ALLOWED_AUTHOR_EMAILS='*' \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 1 ]]; then
  assert_contains "$vo" "IDENTITY_FAIL" "'*' 単体の無効化"
else
  fail "'*' 単体が全 email を通した (exit $vrc)"
fi

it "ドメイン許可は '@example.com' という email そのものを許可しない"
# ローカル部 1 文字以上を要求する。ドメイン形のエントリは「そのドメインに属する
# 誰か」を許可するものであって、ローカル部を持たない文字列を許可する指定ではない。
#
# 許可エントリ側は '*@example.com' を使う。'@example.com' を指定した場合は、
# ドメイン判定より手前の完全一致（明示列挙）が先に当たるため、ドメイン許可の
# 判定そのものを検査できない。
vr10="$(new_workdir)/vr10"; mk_repo "$vr10" verify-commit-identity.sh
commit_as "$vr10" "@example.com" "@example.com" d4
vo="$(cd "$vr10" && env ALLOWED_AUTHOR_EMAILS='*@example.com' \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 1 ]]; then
  assert_contains "$vo" "IDENTITY_FAIL" "ローカル部 0 文字の拒否"
else
  fail "'@example.com' という email を通した (exit $vrc)"
fi

it "ドメイン許可を足してもローカルの identity 適用漏れは検知し続ける"
# 許可範囲を広げる変更なので、元の検知対象が落ちていないことを固定する。
vr11="$(new_workdir)/vr11"; mk_repo "$vr11" verify-commit-identity.sh
commit_as "$vr11" "other-account@personal.example" "other-account@personal.example" d5
vo="$(cd "$vr11" && env ALLOWED_AUTHOR_EMAILS='@example.com' \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 1 ]]; then
  assert_contains "$vo" "IDENTITY_FAIL" "適用漏れの検知"
else
  fail "許可外ドメインの author を通した (exit $vrc)"
fi

it "通常の許可 email はドメイン指定として解釈されない"
# case のパターン '*@'* は、引用された '*@' がリテラルで、後ろの引用されていない
# '*' だけがワイルドカードである。この引用が外れると、'alice@example.com' のような
# 通常の許可エントリまでドメイン分岐へ入り、**完全一致のつもりが接尾辞一致になる**
# （'xalice@example.com' が通る）。
#
# 引用の有無は目で見て気づきにくく、「パターンを整理する」類の変更で静かに外れる。
# 変更が入った瞬間に落ちるよう、ここで固定する。
vr12="$(new_workdir)/vr12"; mk_repo "$vr12" verify-commit-identity.sh
commit_as "$vr12" "xalice@example.com" "xalice@example.com" d6
vo="$(cd "$vr12" && env ALLOWED_AUTHOR_EMAILS='alice@example.com' \
    bash scripts/verify-commit-identity.sh --full 2>&1)"; vrc=$?
if [[ "$vrc" -eq 1 ]]; then
  assert_contains "$vo" "IDENTITY_FAIL" "接尾辞一致の拒否"
else
  fail "完全一致の許可エントリが接尾辞一致として働いた (exit $vrc)"
fi

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
