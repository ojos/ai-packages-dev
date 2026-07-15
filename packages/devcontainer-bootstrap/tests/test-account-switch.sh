#!/usr/bin/env bash
# 生成される github-account-switch.sh を検証する。
#
# このスクリプトは gh の認証と git の署名者を切り替えるが、以前は
# credential.helper に触れていなかった。gh auth login --with-token は非対話の
# ため git を設定せず、結果として push の認証だけが別アカウントのまま残り、
# 切り替えたつもりで 403 になる。実際にリリース実行が止まった。
#
# ここではネットワークにも実トークンにも依存せず、生成物の構造と、
# credential.helper のリセット順序という壊れやすい部分を検証する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-account-switch"

out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
SW="$out/scripts/github-account-switch.sh"

it "github-account-switch.sh が生成される"
assert_file_exists "$SW"

it "構文が正しい"
if bash -n "$SW" 2>/dev/null; then pass; else fail "syntax error"; fi

it "push 認証を設定する処理を持つ"
if grep -q 'setup_git_credentials' "$SW"; then pass; else fail "setup_git_credentials がない"; fi

it "cmd_use から呼ばれる"
# 定義（関数宣言）と呼び出しの 2 箇所以上あること
n="$(grep -c 'setup_git_credentials' "$SW")"
if [[ "$n" -ge 2 ]]; then pass; else fail "定義のみで呼び出されていない（出現 $n 回）"; fi

it "gh を credential helper に向ける"
if grep -q 'gh auth git-credential' "$SW"; then pass; else fail "gh auth git-credential への配線がない"; fi

it "上位スコープのヘルパーをリセットしてから追加する"
# 空文字の --add が '!gh auth git-credential' より前にあること。
# 順序が逆だと上位スコープのヘルパーが先に応答して勝ってしまう。
reset_line="$(grep -n "credential.helper ''" "$SW" | head -1 | cut -d: -f1)"
gh_line="$(grep -n "credential.helper '!gh auth git-credential'" "$SW" | head -1 | cut -d: -f1)"
if [[ -n "$reset_line" && -n "$gh_line" && "$reset_line" -lt "$gh_line" ]]; then
  pass
else
  fail "リセット（$reset_line 行）が gh 配線（$gh_line 行）より後、または欠落"
fi

it "gh が無い環境では何もしない"
if grep -q 'command -v gh >/dev/null 2>&1 || return 0' "$SW"; then pass; else fail "gh 不在時のガードがない"; fi

# ── 実際に credential.helper が書かれるか ─────────────────────────────────────
# 実トークンを使わずに setup_git_credentials だけを取り出して検証する。

it "実行すると local スコープに 2 段のヘルパーが設定される"
repo="$(new_workdir)/r"
mkdir -p "$repo"
( cd "$repo" && git init --quiet )
# 関数だけを取り出して、テスト用リポジトリに対して適用する
fn="$(sed -n '/^setup_git_credentials()/,/^}/p' "$SW")"
( cd "$repo" && eval "$fn" && setup_git_credentials local )
helpers="$(cd "$repo" && git config --local --get-all credential.helper 2>/dev/null | tr '\n' '|')"
assert_eq "$helpers" "|!gh auth git-credential|" "local の credential.helper"

it "既存のヘルパーがあっても置き換わる"
repo="$(new_workdir)/r"
mkdir -p "$repo"
( cd "$repo" && git init --quiet && git config --local credential.helper 'store' )
( cd "$repo" && eval "$fn" && setup_git_credentials local )
helpers="$(cd "$repo" && git config --local --get-all credential.helper 2>/dev/null | tr '\n' '|')"
assert_eq "$helpers" "|!gh auth git-credential|" "置き換え後の credential.helper"

exit_with_result
