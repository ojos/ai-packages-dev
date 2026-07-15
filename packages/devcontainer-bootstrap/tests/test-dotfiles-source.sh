#!/usr/bin/env bash
# 規範ソースの解決を検証する。
#
# v0.2.0 では URL 経路で規範が 1 件も配置されず、しかも成功扱いになった。
# 一時ディレクトリ削除の EXIT トラップを、コマンド置換内で実行される関数に
# 登録したため、パスを返した直後に展開先が消えていた。ローカルディレクトリでしか
# 検証しなかったため公開まで気づかなかった。
# このファイルの中心は、その経路を実際に通すことにある。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

EXPECTED_RULES="$(count_rules "$DOTFILES_SRC/ai/common")"

echo "test-dotfiles-source (期待する規範数: $EXPECTED_RULES)"

# ── URL 経路（v0.2.0 のリグレッション）────────────────────────────────────────

it "URL 指定で規範が配置される"
out="$(new_workdir)/p"
archive="$(make_dotfiles_tarball)"
if url="$(serve_file "$archive")"; then
  run_bootstrap "$out" --with-dotfiles --dotfiles-from "$url" >/dev/null 2>&1
  stop_http_server
  assert_eq "$(count_rules "$out/dotfiles/ai/common")" "$EXPECTED_RULES" "配置された規範数"
else
  fail "ローカル HTTP サーバを起動できず、URL 経路を検証できなかった"
fi

it "URL 指定で入口ファイルの参照先が実在する"
assert_file_exists "$out/dotfiles/ai/common/shared-ai-rules.md"

it "URL 指定で一時ディレクトリが残らない"
before="$(ls -d /tmp/tmp.* 2>/dev/null | wc -l | tr -d ' ')"
out2="$(new_workdir)/p"
archive2="$(make_dotfiles_tarball)"
if url2="$(serve_file "$archive2")"; then
  run_bootstrap "$out2" --with-dotfiles --dotfiles-from "$url2" >/dev/null 2>&1
  stop_http_server
  after="$(ls -d /tmp/tmp.* 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$after" "$before" "実行前後の /tmp/tmp.* の数"
else
  fail "ローカル HTTP サーバを起動できなかった"
fi

# ── ローカルディレクトリ経路 ──────────────────────────────────────────────────

it "ディレクトリ指定で規範が配置される"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-dotfiles --dotfiles-from "$DOTFILES_SRC" >/dev/null 2>&1
assert_eq "$(count_rules "$out/dotfiles/ai/common")" "$EXPECTED_RULES" "配置された規範数"

# ── 隣接チェックアウト経路（既定）─────────────────────────────────────────────

it "指定なしで隣接チェックアウトから配置される"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-dotfiles >/dev/null 2>&1
assert_eq "$(count_rules "$out/dotfiles/ai/common")" "$EXPECTED_RULES" "配置された規範数"

# ── 異常系 ────────────────────────────────────────────────────────────────────

it "ソース不在なら失敗する"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-dotfiles --dotfiles-from /nonexistent >/dev/null 2>&1
assert_eq "$?" "1" "終了コード"

it "ソース不在なら副作用を残さない"
assert_file_absent "$out"

it "規範が 0 件のソースは失敗する（沈黙した成功の防止）"
empty="$(new_workdir)/empty"
mkdir -p "$empty/ai/common"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --with-dotfiles --dotfiles-from "$empty" 2>&1)"
code=$?
if [[ $code -ne 0 ]]; then
  assert_contains "$output" "no rule files found" "エラー出力"
else
  fail "規範 0 件でも成功してしまった"
fi

# ── オプトイン ────────────────────────────────────────────────────────────────

it "既定では規範を配置しない"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
assert_file_absent "$out/dotfiles"

it "--without-dotfiles で規範を配置しない"
out="$(new_workdir)/p"
run_bootstrap "$out" --without-dotfiles >/dev/null 2>&1
assert_file_absent "$out/dotfiles"

exit_with_result
