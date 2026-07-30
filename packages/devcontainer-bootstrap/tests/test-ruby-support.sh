#!/usr/bin/env bash
# ruby 言語対応を検証する。
#
# ruby は rust と違い feature 名（ruby）と実行ファイル名（ruby）が一致するため、
# rust で必要だった「feature 名 ≠ コマンド名」の写像分岐を持たない。その一致を
# 前提に、検査・診断が余計な写像を挟まず ruby 自身で判定することを確認する。
#
# acceptance コマンドは `bundle exec rake` とし、Minitest / RSpec のどちらかを
# 決め打ちしない。実行に必要なツールはテストランナーではなく bundle である点も
# 併せて検証する（コマンド名とツール名が一致しない php/composer と同型）。
#
# ネットワークには出ない。gitignore は取得内容ではなく「ターゲット名の解決」
# （DCB のロジック）だけを検査する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-ruby-support"

RUBY_FEATURE='ghcr.io/devcontainers/features/ruby:1'

# ── feature 配線 ──────────────────────────────────────────────────────────────

it "ruby 選択で devcontainer.json に ruby feature が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages ruby >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if jq -e --arg f "$RUBY_FEATURE" '.features | has($f)' "$dc" >/dev/null; then pass; else fail "ruby feature が無い"; fi

it "ruby 非選択（node のみ）では ruby feature も残留プレースホルダも無い"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if jq -e --arg f "$RUBY_FEATURE" '.features | has($f)' "$dc" >/dev/null; then
  fail "非選択なのに ruby feature がある"
elif grep -q '__IF_RUNTIME_RUBY__' "$dc"; then
  fail "未置換プレースホルダ __IF_RUNTIME_RUBY__ が残っている"
else
  pass
fi

it "生成された devcontainer.json は妥当な JSON（ruby 選択時）"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages ruby,go,python >/dev/null 2>&1
if jq -e . "$out/.devcontainer/devcontainer.json" >/dev/null 2>&1; then pass; else fail "JSON として不正"; fi

it "ruby feature は options 無し（python の uv 同梱に巻き込まれない）"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages ruby,python >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if jq -e --arg f "$RUBY_FEATURE" '.features[$f] == {}' "$dc" >/dev/null; then pass; else fail "ruby feature に余計な options がある: $(jq -c --arg f "$RUBY_FEATURE" '.features[$f]' "$dc")"; fi

# ── post-rebuild-check の検査行 ───────────────────────────────────────────────

it "ruby 選択時は post-rebuild-check に ruby 検査行がある"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages ruby >/dev/null 2>&1
if grep -qE 'command -v ruby .*\[check\] ruby OK' "$out/scripts/post-rebuild-check.sh"; then pass; else fail "ruby 検査行が無い"; fi

it "ruby 非選択時は ruby 検査行が無い"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
if grep -q 'ruby' "$out/scripts/post-rebuild-check.sh"; then fail "非選択なのに ruby 検査行がある"; else pass; fi

it "ruby の検査は ruby 自身で行う（cargo のような写像を挟まない）"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages ruby >/dev/null 2>&1
if grep -q 'command -v ruby >/dev/null 2>&1 && echo "\[check\] ruby OK" || echo "\[check\] ruby missing"' "$out/scripts/post-rebuild-check.sh"; then
  pass
else
  fail "ruby 検査行が期待の形になっていない: $(grep ruby "$out/scripts/post-rebuild-check.sh" | head -1)"
fi

# ── acceptance の言語別既定 ───────────────────────────────────────────────────

it "ruby 選択時は acceptance に bundle exec rake が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages ruby >/dev/null 2>&1
if grep -q 'bundle exec rake' "$out/scripts/acceptance.sh"; then pass; else fail "bundle exec rake が無い"; fi

it "ruby の acceptance はテストフレームワークを決め打ちしない"
# Minitest（rake test）も RSpec（rspec）も直接呼ばない。Rakefile の default へ委譲する。
out="$(new_workdir)/p"
run_bootstrap "$out" --languages ruby >/dev/null 2>&1
if grep -qE 'bundle exec rspec|bundle exec rake test' "$out/scripts/acceptance.sh"; then
  fail "テストフレームワークを決め打ちしている: $(grep -E 'rspec|rake' "$out/scripts/acceptance.sh" | head -1)"
else
  pass
fi

it "ruby の acceptance は Gemfile の実在を確認する"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages ruby >/dev/null 2>&1
if grep -q '\-f Gemfile' "$out/scripts/acceptance.sh"; then pass; else fail "Gemfile の実在確認が無い"; fi

it "非選択時は ruby の検証行が acceptance に入らない（node のみ選択時）"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
if grep -qE 'bundle exec rake|Gemfile' "$out/scripts/acceptance.sh"; then
  fail "非選択なのに ruby の検証行がある"
else
  pass
fi

it "Gemfile が無ければ ruby の検証はスキップし、その旨を出力する"
# 対象が ruby だけで ran_any=0 のため acceptance 全体は非 0 終了する。ここでは
# skip メッセージの出力のみを検証する目的なので、終了コードは意図的に無視する。
out="$(new_workdir)/p"
run_bootstrap "$out" --languages ruby >/dev/null 2>&1
out_txt="$(cd "$out" && bash scripts/acceptance.sh 2>&1)" || true
assert_contains "$out_txt" "skip: Gemfile not found" "acceptance 出力"

it "Gemfile はあるが bundle が無い場合は導入手順を添えて非 0 で終了する"
# ルートに Gemfile を置き、dirname だけを通す最小 PATH で bundle を不在化する。
out="$(new_workdir)/p"
run_bootstrap "$out" --languages ruby >/dev/null 2>&1
printf "source 'https://rubygems.org'\n" > "$out/Gemfile"
stub="$(new_workdir)/bin"; mkdir -p "$stub"
ln -s "$(command -v dirname)" "$stub/dirname"
bashbin="$(command -v bash)"
if out_txt="$(cd "$out" && PATH="$stub" "$bashbin" scripts/acceptance.sh 2>&1)"; then
  fail "ツール不在なのに合格した: $out_txt"
else
  if printf '%s' "$out_txt" | grep -q 'bundle not found' && printf '%s' "$out_txt" | grep -qi 'install'; then
    pass
  else
    fail "導入手順付きのツール不在エラーが出ていない: $out_txt"
  fi
fi

it "ruby を含む組み合わせで生成 acceptance.sh が bash -n を通る"
bad=""
for c in ruby node,ruby ruby,rust node,go,python,php,rust,ruby; do
  o="$(new_workdir)/p"
  run_bootstrap "$o" --languages "$c" >/dev/null 2>&1
  bash -n "$o/scripts/acceptance.sh" 2>/dev/null || bad="$bad $c"
done
if [[ -z "$bad" ]]; then pass; else fail "構文エラー:$bad"; fi

# ── gitignore ターゲット解決（ネットワーク非依存） ────────────────────────────

it "ruby 選択で gitignore 管理セクションに Ruby ターゲットが入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages ruby >/dev/null 2>&1
if grep -q '# template: Ruby' "$out/.gitignore"; then pass; else fail "Ruby ターゲットが gitignore に無い"; fi

it "ruby 非選択では Ruby ターゲットが入らない"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
if grep -q '# template: Ruby' "$out/.gitignore"; then fail "非選択なのに Ruby ターゲットがある"; else pass; fi

# ── VS Code language server 拡張の条件配線 ───────────────────────────────────

ext_has() { # <devcontainer.json> <ext-id>
  jq -e --arg e "$2" '.customizations.vscode.extensions | index($e)' "$1" >/dev/null
}

it "ruby 選択で ruby-lsp 拡張が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages ruby >/dev/null 2>&1
if ext_has "$out/.devcontainer/devcontainer.json" 'Shopify.ruby-lsp'; then pass; else fail "Shopify.ruby-lsp が無い"; fi

it "ruby 非選択では ruby-lsp 拡張が入らない"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node,go >/dev/null 2>&1
if ext_has "$out/.devcontainer/devcontainer.json" 'Shopify.ruby-lsp'; then
  fail "非選択なのに Shopify.ruby-lsp が混入"
else
  pass
fi

it "既存言語の拡張配線が回帰していない（ruby と併用時）"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages ruby,rust,go,python >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if ext_has "$dc" 'Shopify.ruby-lsp' && ext_has "$dc" 'rust-lang.rust-analyzer' \
   && ext_has "$dc" 'golang.go' && ext_has "$dc" 'ms-python.python'; then
  pass
else
  fail "拡張が揃っていない: $(jq -c '.customizations.vscode.extensions' "$dc")"
fi

# ── doctor.sh の ruby 検出 ────────────────────────────────────────────────────

it "doctor は ruby feature を検出し ruby で検査する"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages ruby >/dev/null 2>&1
output="$(bash "$PKG_DIR/doctor.sh" --target-dir "$out" 2>&1)"
if printf '%s' "$output" | grep -q 'ruby command .*(ruby)'; then pass; else fail "ruby の検査が行われていない: $(printf '%s' "$output" | grep -i ruby)"; fi

it "doctor は ruby 非選択時に ruby を報告しない"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
output="$(bash "$PKG_DIR/doctor.sh" --target-dir "$out" 2>&1)"
if printf '%s' "$output" | grep -q 'ruby command'; then fail "非選択なのに ruby を報告している"; else pass; fi

# ── 入力検証 ──────────────────────────────────────────────────────────────────

it "ruby は受理される"
out="$(new_workdir)/p"
if run_bootstrap "$out" --languages ruby >/dev/null 2>&1; then pass; else fail "ruby が受理されない"; fi

it "未対応言語のエラーメッセージが ruby を列挙する"
out="$(new_workdir)/p"
if err="$(run_bootstrap "$out" --languages unsupported 2>&1)"; then
  fail "未対応言語が受理された: $err"
elif printf '%s' "$err" | grep -q 'ruby'; then
  pass
else
  fail "対応言語の列挙に ruby が無い: $err"
fi

it "ヘルプの --languages 説明が ruby を列挙する"
if bash "$BOOTSTRAP" --help 2>&1 | grep -q 'node,go,python,php,rust,ruby'; then pass; else fail "ヘルプに ruby が無い"; fi

exit_with_result
