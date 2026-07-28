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
# グローバルな /tmp/tmp.* を数えると、同一ホストの無関係なプロセスの mktemp が
# 計数に混入し、テスト対象と無関係な理由で落ちる（並列実行時にのみ再現する偽陽性）。
# bootstrap.sh の一時領域は mktemp 由来なので TMPDIR で作成先を制御できる。
# この実行専用の空ディレクトリへ向け、そこだけを数えることで計数範囲を閉じる。
tmpwatch="$(mktemp -d "$TEST_TMP_ROOT/tmpwatch.XXXXXX")"
out2="$(new_workdir)/p"
archive2="$(make_playbook_tarball)"
if url2="$(serve_file "$archive2")"; then
  # TMPDIR は子プロセスへ渡すだけで、テストプロセス自身の一時領域は動かさない。
  (export TMPDIR="$tmpwatch"; run_bootstrap "$out2" --with-playbook --playbook-from "$url2") >/dev/null 2>&1
  stop_http_server
  # 空ディレクトリへ向けたので、残骸があれば必ずここに現れる。
  leftover="$(ls -A "$tmpwatch" 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "$leftover" "0" "実行後に残った一時ディレクトリ・ファイルの数"
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
# 検出は通るが、配置対象の規範が 0 件になり書き込み前に失敗する。
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

it "規範 0 件のソースは 1 つもファイルを書かない（アトミック配置）"
assert_file_absent "$out"

it "URL 取得が壊れたアーカイブでも書き込み前に失敗する（アトミック配置）"
# curl は 200 だが tar 展開に失敗するケース。非 tarball をローカル配信して再現する
# （ネットワークには出ない）。取得失敗で devcontainer を部分生成してから遅れて
# 失敗する不具合（404 で全ファイルを書いてしまう）の回帰を防ぐ。
bogus="$(mktemp "$TEST_TMP_ROOT/bogus.XXXXXX.tar.gz")"
printf 'this is not a valid gzip tarball' > "$bogus"
if url="$(serve_file "$bogus")"; then
  out="$(new_workdir)/p"
  output="$(run_bootstrap "$out" --playbook-from "$url" 2>&1)"
  code=$?
  stop_http_server
  if [[ $code -ne 0 ]] && [[ ! -d "$out/.devcontainer" ]]; then
    pass
  else
    fail "壊れたアーカイブで部分生成または成功した (code=$code, .devcontainer=$([ -d "$out/.devcontainer" ] && echo yes || echo no))"
  fi
else
  fail "ローカル HTTP サーバを起動できず検証できなかった"
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

# ── 導入した規範のソースを VERSION に記録する（自己診断 F-7）──────────────────
# 生成後の環境から「どのバージョンの playbook を取り込んだか」を証跡照合できる
# ようにする。--playbook-version の実タグ取得はネットワークに出るため、ここでは
# 非ネットワークで通る既定ソース／ローカルソース経路で source 記録を検証する。

it "規範導入時に .ai-playbook/VERSION を作る"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-playbook >/dev/null 2>&1
assert_file_exists "$out/.ai-playbook/VERSION"

it "VERSION に version と source を記録する（既定は隣接チェックアウト）"
ver_content="$(cat "$out/.ai-playbook/VERSION" 2>/dev/null)"
assert_contains "$ver_content" "version=(unspecified)" "VERSION の version 行"
assert_contains "$ver_content" "source=<adjacent checkout>" "VERSION の source 行"

it "--playbook-from 指定時は source にそのソースを記録する"
out="$(new_workdir)/p"
run_bootstrap "$out" --playbook-from "$PLAYBOOK_SRC" >/dev/null 2>&1
assert_contains "$(cat "$out/.ai-playbook/VERSION" 2>/dev/null)" "source=$PLAYBOOK_SRC" "VERSION の source 行"

it "規範を配置しないなら VERSION も作らない"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
assert_file_absent "$out/.ai-playbook/VERSION"

it "dry-run は VERSION の生成を計画に含める"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --with-playbook --dry-run 2>&1)"
assert_contains "$output" ".ai-playbook/VERSION" "dry-run 計画"

it "再実行では既存 VERSION を skip ポリシーに従い上書きしない"
# 規範 *.md を skip で温存したまま VERSION だけ書き換えると、記録が実際の
# on-disk 規範とずれて嘘になる。VERSION も規範と同じ衝突ポリシーに従うこと。
out="$(new_workdir)/p"
altsrc="$(new_workdir)/alt"; mkdir -p "$altsrc"; cp -R "$PLAYBOOK_SRC/." "$altsrc/"
run_bootstrap "$out" --playbook-from "$PLAYBOOK_SRC" >/dev/null 2>&1
first="$(cat "$out/.ai-playbook/VERSION" 2>/dev/null)"
run_bootstrap "$out" --playbook-from "$altsrc" >/dev/null 2>&1
assert_eq "$(cat "$out/.ai-playbook/VERSION" 2>/dev/null)" "$first" "再実行後の VERSION（skip で不変）"

it "再実行でも conflict-policy overwrite なら VERSION を更新する"
run_bootstrap "$out" --playbook-from "$altsrc" --playbook-conflict-policy overwrite >/dev/null 2>&1
assert_contains "$(cat "$out/.ai-playbook/VERSION" 2>/dev/null)" "source=$altsrc" "overwrite 後の source"

exit_with_result
