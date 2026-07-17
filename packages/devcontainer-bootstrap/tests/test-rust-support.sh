#!/usr/bin/env bash
# rust 言語対応と、それに伴う汎用化・拡張条件配線を検証する。
#
# rust は他言語と違い feature 名（rust）と実行コマンド（cargo）が一致しない。
# また本対応で post-rebuild-check の言語別検査行を汎用化し（php 専用プレースホルダ撤去）、
# VS Code language server 拡張を選択言語に応じて条件配線するようにした。
# ここではそのパリティ・回帰・条件配線をまとめて検証する。
#
# ネットワークには出ない。gitignore は取得内容ではなく「ターゲット名の解決」
# （DCB のロジック）だけを検査する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-rust-support"

RUST_FEATURE='ghcr.io/devcontainers/features/rust:1'

# ── feature 配線 ──────────────────────────────────────────────────────────────

it "rust 選択で devcontainer.json に rust feature が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages rust >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if jq -e --arg f "$RUST_FEATURE" '.features | has($f)' "$dc" >/dev/null; then pass; else fail "rust feature が無い"; fi

it "rust 非選択（node のみ）では rust feature も残留プレースホルダも無い"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if jq -e --arg f "$RUST_FEATURE" '.features | has($f)' "$dc" >/dev/null; then
  fail "非選択なのに rust feature がある"
elif grep -q '__IF_RUNTIME_RUST__' "$dc"; then
  fail "未置換プレースホルダ __IF_RUNTIME_RUST__ が残っている"
else
  pass
fi

it "生成された devcontainer.json は妥当な JSON（rust 選択時）"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages rust,go,python --mode full >/dev/null 2>&1
if jq -e . "$out/.devcontainer/devcontainer.json" >/dev/null 2>&1; then pass; else fail "JSON として不正"; fi

# ── post-rebuild-check の検査行（汎用化） ─────────────────────────────────────

it "rust 選択時は post-rebuild-check に cargo 検査行がある"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages rust --mode standard >/dev/null 2>&1
if grep -qE 'command -v cargo .*\[check\] cargo OK' "$out/scripts/post-rebuild-check.sh"; then pass; else fail "cargo 検査行が無い"; fi

it "rust 非選択時は cargo 検査行が無い"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node --mode standard >/dev/null 2>&1
if grep -q 'cargo' "$out/scripts/post-rebuild-check.sh"; then fail "非選択なのに cargo 検査行がある"; else pass; fi

it "汎用化の回帰: php 選択時は php 検査行が従来どおり出る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages php --mode standard >/dev/null 2>&1
if grep -qE 'command -v php .*\[check\] php OK' "$out/scripts/post-rebuild-check.sh"; then pass; else fail "php 検査行が無い（汎用化で回帰）"; fi

it "汎用化: php 専用プレースホルダは撤去されている"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages php --mode standard >/dev/null 2>&1
if grep -q '__IF_RUNTIME_PHP_CHECK__' "$out/scripts/post-rebuild-check.sh"; then fail "旧 php プレースホルダが残留"; else pass; fi

it "検査行の && / 2>&1 が壊れていない（& 置換バグの回帰）"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages rust --mode minimal >/dev/null 2>&1
if grep -q 'command -v cargo >/dev/null 2>&1 && echo "\[check\] cargo OK" || echo "\[check\] cargo missing"' "$out/scripts/post-rebuild-check.sh"; then
  pass
else
  fail "cargo 検査行の & が破損している: $(grep cargo "$out/scripts/post-rebuild-check.sh" | head -1)"
fi

# ── gitignore ターゲット解決（ネットワーク非依存） ────────────────────────────

it "rust 選択で gitignore 管理セクションに Rust ターゲットが入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages rust --mode minimal >/dev/null 2>&1
if grep -q '# template: Rust' "$out/.gitignore"; then pass; else fail "Rust ターゲットが gitignore に無い"; fi

# ── VS Code language server 拡張の条件配線 ───────────────────────────────────

ext_has() { # <devcontainer.json> <ext-id>
  jq -e --arg e "$2" '.customizations.vscode.extensions | index($e)' "$1" >/dev/null
}

it "rust 選択で rust-analyzer 拡張が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages rust --mode standard >/dev/null 2>&1
if ext_has "$out/.devcontainer/devcontainer.json" 'rust-lang.rust-analyzer'; then pass; else fail "rust-analyzer が無い"; fi

it "go / python 選択で対応拡張が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages go,python --mode standard >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if ext_has "$dc" 'golang.go' && ext_has "$dc" 'ms-python.python'; then pass; else fail "golang.go / ms-python.python が揃っていない"; fi

it "非選択言語の拡張は入らない（node のみ選択時）"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node --mode standard >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if ext_has "$dc" 'rust-lang.rust-analyzer' || ext_has "$dc" 'golang.go' || ext_has "$dc" 'ms-python.python'; then
  fail "非選択言語の language server 拡張が混入"
else
  pass
fi

it "node / php はサードパーティ language server 拡張を配線しない"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node,php --mode standard >/dev/null 2>&1
dc="$out/.devcontainer/devcontainer.json"
if jq -r '.customizations.vscode.extensions[]' "$dc" | grep -qiE 'intelephense|php|typescript-language'; then
  fail "node/php にサードパーティ拡張が混入"
else
  pass
fi

it "拡張プレースホルダが残留しない"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages rust --mode minimal >/dev/null 2>&1
if grep -q '__LANGUAGE_EXTENSIONS__' "$out/.devcontainer/devcontainer.json"; then fail "__LANGUAGE_EXTENSIONS__ が残留"; else pass; fi

# ── doctor.sh の rust 検出（言語名≠コマンド名） ──────────────────────────────

it "doctor は rust を cargo で検査する（command -v rust の誤検査をしない）"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages rust --mode minimal >/dev/null 2>&1
output="$(bash "$PKG_DIR/doctor.sh" --target-dir "$out" 2>&1)"
# cargo に言及し、かつ "rust command available/missing" が cargo 付きで出る。
if printf '%s' "$output" | grep -q 'rust command .*(cargo)'; then pass; else fail "rust の検査が cargo で行われていない: $(printf '%s' "$output" | grep -i rust)"; fi

# ── 入力検証 ──────────────────────────────────────────────────────────────────

it "rust は受理される"
out="$(new_workdir)/p"
if run_bootstrap "$out" --languages rust >/dev/null 2>&1; then pass; else fail "rust が受理されない"; fi

exit_with_result
