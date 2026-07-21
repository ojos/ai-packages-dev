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

EXPECTED_RULES="$(count_rules "$PLAYBOOK_SRC")"

echo "test-playbook-source (期待する規範数: $EXPECTED_RULES)"

# ── URL 経路（v0.2.0 のリグレッション）────────────────────────────────────────

it "URL 指定で規範が配置される"
out="$(new_workdir)/p"
archive="$(make_playbook_tarball)"
if url="$(serve_file "$archive")"; then
  run_bootstrap "$out" --with-playbook --playbook-from "$url" >/dev/null 2>&1
  stop_http_server
  assert_eq "$(count_rules "$out/.ai-playbook")" "$EXPECTED_RULES" "配置された規範数"
else
  fail "ローカル HTTP サーバを起動できず、URL 経路を検証できなかった"
fi

it "URL 指定で入口ファイルの参照先が実在する"
assert_file_exists "$out/.ai-playbook/shared-ai-rules.md"

it "ラッパーの無いフラットな tarball でも規範が配置される"
# 展開直下に規範ファイルとサブディレクトリがフラットに並ぶ手製アーカイブ。
# ラッパー 1 個を決め打ちする検出だと直下のサブディレクトリを誤認する。
outf="$(new_workdir)/p"
archivef="$(make_flat_playbook_tarball)"
if urlf="$(serve_file "$archivef")"; then
  run_bootstrap "$outf" --with-playbook --playbook-from "$urlf" >/dev/null 2>&1
  stop_http_server
  assert_eq "$(count_rules "$outf/.ai-playbook")" "$EXPECTED_RULES" "配置された規範数"
else
  fail "ローカル HTTP サーバを起動できなかった"
fi

it "URL 指定で一時ディレクトリが残らない"
before="$(ls -d /tmp/tmp.* 2>/dev/null | wc -l | tr -d ' ')"
out2="$(new_workdir)/p"
archive2="$(make_playbook_tarball)"
if url2="$(serve_file "$archive2")"; then
  run_bootstrap "$out2" --with-playbook --playbook-from "$url2" >/dev/null 2>&1
  stop_http_server
  after="$(ls -d /tmp/tmp.* 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$after" "$before" "実行前後の /tmp/tmp.* の数"
else
  fail "ローカル HTTP サーバを起動できなかった"
fi

# ── ローカルディレクトリ経路 ──────────────────────────────────────────────────

it "ディレクトリ指定で規範が配置される"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-playbook --playbook-from "$PLAYBOOK_SRC" >/dev/null 2>&1
assert_eq "$(count_rules "$out/.ai-playbook")" "$EXPECTED_RULES" "配置された規範数"

it "末尾スラッシュ付きのディレクトリ指定でも規範が配置される"
# 末尾スラッシュがルート判定を通り抜けると rel が二重スラッシュで壊れ、配置先が乱れる。
out="$(new_workdir)/p"
run_bootstrap "$out" --with-playbook --playbook-from "$PLAYBOOK_SRC/" >/dev/null 2>&1
assert_eq "$(count_rules "$out/.ai-playbook")" "$EXPECTED_RULES" "配置された規範数"
assert_file_exists "$out/.ai-playbook/shared-ai-rules.md"

# ── 隣接チェックアウト経路（既定）─────────────────────────────────────────────

it "指定なしで隣接チェックアウトから配置される"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-playbook >/dev/null 2>&1
assert_eq "$(count_rules "$out/.ai-playbook")" "$EXPECTED_RULES" "配置された規範数"

# ── 異常系 ────────────────────────────────────────────────────────────────────

it "ソース不在なら失敗する"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-playbook --playbook-from /nonexistent >/dev/null 2>&1
assert_eq "$?" "1" "終了コード"

it "ソース不在なら副作用を残さない"
assert_file_absent "$out"

it "規範が 0 件のソースは失敗する（沈黙した成功の防止）"
# 規範を 1 件も配置しないまま成功扱いになることを防ぐ。空ディレクトリを指定すると
# 検出は通るが、配置対象の規範が 0 件になり install 段で失敗する。
empty="$(new_workdir)/empty"
mkdir -p "$empty"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --with-playbook --playbook-from "$empty" 2>&1)"
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
assert_file_absent "$out/.ai-playbook"

it "--without-playbook で規範を配置しない"
out="$(new_workdir)/p"
run_bootstrap "$out" --without-playbook >/dev/null 2>&1
assert_file_absent "$out/.ai-playbook"

# ── --playbook-version（既定ソース ojos/ai-playbook タグ tarball への糖衣） ─────
# ネットワークには出さない。取得前に出す展開ログと、排他エラー・両経路の等価性を検証する。

it "--playbook-version は既定ソースのタグ tarball URL へ展開する"
out="$(new_workdir)/p"
# 展開ログは取得前に出る。--without-playbook で取得（ネットワーク）を抑止しつつ、
# 展開された URL 文字列だけを確認する（run-tests.sh の非ネットワーク方針を守る）。
output="$(run_bootstrap "$out" --playbook-version v1.2.3 --without-playbook 2>&1)"
assert_contains "$output" \
  "https://github.com/ojos/ai-playbook/archive/refs/tags/v1.2.3.tar.gz" \
  "展開された playbook-from URL"

it "--playbook-version と --playbook-from の同時指定はエラー"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --playbook-version v1.2.3 --playbook-from /some/dir 2>&1)"
code=$?
if [[ $code -ne 0 ]] && printf '%s' "$output" | grep -q '同時に指定できません'; then
  pass
else
  fail "排他エラーにならなかった (code=$code)"
fi

# 注: --playbook-version の end-to-end 等価性（実 github からの取得）はネットワークに
# 出るため run-tests.sh の非ネットワーク方針では検証しない。上のログ検証で URL 構築の
# 正しさを、既存の「URL 指定で規範が配置される」テストで URL 取得経路の健全性を担保し、
# 両者は PLAYBOOK_FROM 設定後の同一経路を通る（構造的に等価）。

# ── ソース指定は --with-playbook を省略しても配置する（#93 の折り込み） ─────────
# ローカルディレクトリ源を使い、ネットワークには出ない。

it "--playbook-from 指定があれば --with-playbook を省略しても配置する"
out="$(new_workdir)/p"
run_bootstrap "$out" --playbook-from "$PLAYBOOK_SRC" >/dev/null 2>&1
assert_eq "$(count_rules "$out/.ai-playbook")" "$EXPECTED_RULES" "配置された規範数（--with-playbook 省略）"

it "--without-playbook はソース指定より優先される（明示 opt-out）"
out="$(new_workdir)/p"
run_bootstrap "$out" --playbook-from "$PLAYBOOK_SRC" --without-playbook >/dev/null 2>&1
assert_file_absent "$out/.ai-playbook"

exit_with_result
