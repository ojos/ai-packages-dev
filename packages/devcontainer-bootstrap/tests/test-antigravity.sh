#!/usr/bin/env bash
# test-antigravity.sh — --with-antigravity（Antigravity CLI / agy）の条件配線を検証する。
#
# agy は他の AI CLI と 2 点で違い、その 2 点がこのテストの対象になる。
#
#   1. npm 配布ではない。install_if_missing <cmd> <npm-pkg> の同型に乗らず、
#      配布元のインストーラを取得して実行する専用の関数が要る。
#   2. 資格情報を ~/.gemini/antigravity-cli/ へ置く。gemini と設定ディレクトリを
#      共有するため、永続 volume は「どちらかが選ばれていれば 1 つだけ」になる。
#
# 2 は volume 生成の条件が「単一フラグ → 単一ディレクトリ」から外れる唯一の例外
# なので、単独・併用・未指定の 3 通りを個別に固定する。併用で volume 定義が重複
# すると compose は同じ名前の volume を 2 回定義した時点で落ちる。
#
# テレメトリ無効化については「無効化する処理が入ること」と、その処理が満たすべき
# 性質（冪等・非破壊・黙って未適用にしない）を生成物のテキストで固定する。処理を
# 実行しての振る舞い検証は開発リポジトリ側の tests/test-agy-telemetry.sh が行う
# （あちらが正本の実装を実行して確かめており、ここで再実行すると同じ検証を 2 か所
# で持つことになる）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-antigravity"

compose_of() { printf '%s' "$1/.devcontainer/compose.yaml"; }

# ── フラグそのもの ────────────────────────────────────────────────────────────

it "--with-antigravity を実装が受理する"
if impl_flags | grep -x -- '--with-antigravity' >/dev/null; then
  pass
else
  fail "引数解析が --with-antigravity を持たない"
fi

it "usage に --with-antigravity が載る"
if bash "$BOOTSTRAP" --help 2>&1 | grep -- '--with-antigravity' >/dev/null; then
  pass
else
  fail "--help の出力に載っていない"
fi

# ── 生成: --with-antigravity 単独 ─────────────────────────────────────────────

OUT_AG="$(new_workdir)/p"
run_bootstrap "$OUT_AG" --with-antigravity >/dev/null 2>&1
AG_INSTALL="$OUT_AG/scripts/install-ai-tools.sh"

it "単独指定で agy の導入行が入る"
if grep -q 'antigravity.google/cli/install.sh' "$AG_INSTALL" 2>/dev/null \
   && grep -q '^install_agy_if_missing$' "$AG_INSTALL" 2>/dev/null; then
  pass
else
  fail "install-ai-tools.sh に agy の導入が入っていない"
fi

it "単独指定では npm 経由の AI CLI 導入行が入らない"
# --with-gemini を指定していないのに gemini が入ると、フラグを束ねない判断が
# 壊れたことになる（票の設計判断そのもの）。
if ! grep -q '^install_if_missing ' "$AG_INSTALL" 2>/dev/null; then
  pass
else
  fail "選んでいない CLI の導入行がある: $(grep '^install_if_missing ' "$AG_INSTALL" | tr '\n' ' ')"
fi

it "テレメトリ無効化の処理が入る"
if grep -q '^disable_agy_telemetry$' "$AG_INSTALL" 2>/dev/null \
   && grep -q 'enableTelemetry' "$AG_INSTALL" 2>/dev/null; then
  pass
else
  fail "テレメトリ無効化が入っていない"
fi

it "関数定義が呼び出しより前にある"
# 定義が後ろにあると postCreateCommand の実行時に command not found で落ちる。
def_line="$(grep -n '^install_agy_if_missing() {' "$AG_INSTALL" 2>/dev/null | head -n 1 | cut -d: -f1)"
call_line="$(grep -n '^install_agy_if_missing$' "$AG_INSTALL" 2>/dev/null | head -n 1 | cut -d: -f1)"
if [[ -n "$def_line" && -n "$call_line" && "$def_line" -lt "$call_line" ]]; then
  pass
else
  fail "定義 $def_line / 呼び出し $call_line の順序が不正"
fi

it "テレメトリ無効化が冪等である（既に false なら書き込まない）"
if grep -q 'already disabled, skipping' "$AG_INSTALL" 2>/dev/null; then
  pass
else
  fail "冪等の分岐が無い"
fi

it "テレメトリ無効化が enableTelemetry を直読みする（jq の // を使わない）"
# jq の `//` は null だけでなく false も代替側へ落とす。`.enableTelemetry // empty`
# で判定すると「既に false」を「未設定」と誤り、毎回書き込みが起きる。
if grep -q "jq -r '\.enableTelemetry'" "$AG_INSTALL" 2>/dev/null \
   && ! grep -q 'enableTelemetry //' "$AG_INSTALL" 2>/dev/null; then
  pass
else
  fail "enableTelemetry の読み出しが直読みでない"
fi

it "テレメトリ無効化が非破壊である（上書きではなくマージ）"
# agy 自身も書くファイルなので、丸ごと置き換えると利用者の設定が消える。
if grep -q "jq '\.enableTelemetry = false'" "$AG_INSTALL" 2>/dev/null; then
  pass
else
  fail "マージ（.enableTelemetry = false）になっていない"
fi

it "一時ファイル + mv で原子的に差し替える（同一ディレクトリに作る）"
# `jq ... > 同じファイル` はリダイレクトが先に空へ切り詰めるため設定が消える。
# /tmp は別ファイルシステムのことがあり、その場合 mv が原子的にならない。
if grep -q 'mktemp "\$dir/\.settings\.json\.XXXXXX"' "$AG_INSTALL" 2>/dev/null \
   && grep -q 'mv "\$tmp" "\$AGY_SETTINGS"' "$AG_INSTALL" 2>/dev/null; then
  pass
else
  fail "一時ファイル + mv になっていない"
fi

it "jq 不在と壊れた JSON では非 0 で止まる（黙って未適用にしない）"
if grep -q 'jq が無いため agy のテレメトリを無効化できません' "$AG_INSTALL" 2>/dev/null \
   && grep -q 'JSON として読めないため書き換えを中止しました' "$AG_INSTALL" 2>/dev/null; then
  pass
else
  fail "失敗経路が黙って通過する形になっている"
fi

it "設定ファイルを 600 で置く"
if grep -q 'chmod 600 "\$AGY_SETTINGS"' "$AG_INSTALL" 2>/dev/null \
   && grep -q 'chmod 600 "\$tmp"' "$AG_INSTALL" 2>/dev/null; then
  pass
else
  fail "600 での作成になっていない"
fi

# ── 永続 volume: 単独 ─────────────────────────────────────────────────────────

it "単独指定で /home/vscode/.gemini の named volume が生成される"
cmp_ag="$(compose_of "$OUT_AG")"
if grep -q 'gemini-storage:/home/vscode/\.gemini' "$cmp_ag" 2>/dev/null \
   && grep -qE '^  gemini-storage:' "$cmp_ag" 2>/dev/null; then
  pass
else
  fail "gemini-storage が定義・マウントされていない"
fi

it "単独指定でも volume 名は gemini-storage（antigravity-storage を作らない）"
# 名前を分けると、あとから --with-gemini を足した構成で別の volume へ切り替わり、
# 同じ場所を指しているのにログイン状態が消えたように見える。
if ! grep -q 'antigravity-storage' "$cmp_ag" 2>/dev/null; then
  pass
else
  fail "antigravity-storage が作られている"
fi

it "単独指定で所有権修復の対象に入る"
if grep -q 'fix_mount "/home/vscode/\.gemini"' "$OUT_AG/scripts/fix-mount-owner.sh" 2>/dev/null; then
  pass
else
  fail "fix-mount-owner.sh の対象に入っていない"
fi

it "単独指定で実マウント検査の対象に入る"
if grep -q 'check_mounted "/home/vscode/\.gemini" "gemini-storage"' \
     "$OUT_AG/scripts/post-rebuild-check.sh" 2>/dev/null; then
  pass
else
  fail "post-rebuild-check.sh の対象に入っていない"
fi

it "単独指定で agy の CLI 検査が入る"
if grep -q 'command -v agy ' "$OUT_AG/scripts/post-rebuild-check.sh" 2>/dev/null; then
  pass
else
  fail "post-rebuild-check.sh に agy の検査が無い"
fi

it "単独指定で .env.example に SECOND_OPINION_ENGINE の記入欄が入る"
if grep -q '^SECOND_OPINION_ENGINE=$' "$OUT_AG/.env.example" 2>/dev/null; then
  pass
else
  fail ".env.example に記入欄が無い"
fi

it "単独指定では VS Code 拡張を追加しない"
# agy に対応する拡張は無い（本票は CLI のみ）。
dc_ag="$OUT_AG/.devcontainer/devcontainer.json"
if ! grep -qi 'antigravity' "$dc_ag" 2>/dev/null; then
  pass
else
  fail "devcontainer.json に antigravity の記載がある"
fi

# ── 永続 volume: 併用 ─────────────────────────────────────────────────────────

OUT_BOTH="$(new_workdir)/p"
run_bootstrap "$OUT_BOTH" --with-gemini --with-antigravity >/dev/null 2>&1
cmp_both="$(compose_of "$OUT_BOTH")"

it "併用で volume 定義が重複しない"
n="$(grep -cE '^  gemini-storage:' "$cmp_both" 2>/dev/null || true)"
assert_eq "$n" "1" "gemini-storage の定義数"

it "併用で volume マウントが重複しない"
n="$(grep -c 'gemini-storage:/home/vscode/\.gemini' "$cmp_both" 2>/dev/null || true)"
assert_eq "$n" "1" "gemini-storage のマウント数"

it "併用で所有権修復の行が重複しない"
n="$(grep -c 'fix_mount "/home/vscode/\.gemini"' "$OUT_BOTH/scripts/fix-mount-owner.sh" 2>/dev/null || true)"
assert_eq "$n" "1" "fix_mount の行数"

it "併用で実マウント検査の行が重複しない"
n="$(grep -c 'check_mounted "/home/vscode/\.gemini" "gemini-storage"' \
       "$OUT_BOTH/scripts/post-rebuild-check.sh" 2>/dev/null || true)"
assert_eq "$n" "1" "check_mounted の行数"

it "併用では gemini と agy の両方が導入される"
both_install="$OUT_BOTH/scripts/install-ai-tools.sh"
if grep -q '^install_if_missing gemini ' "$both_install" 2>/dev/null \
   && grep -q '^install_agy_if_missing$' "$both_install" 2>/dev/null; then
  pass
else
  fail "併用なのに片方しか導入されない"
fi

it "併用で生成された compose が妥当な YAML として読める"
# 同じ名前の volume を 2 回定義すると compose は起動時に落ちる。重複が無いことは
# 上で行数として固定しているが、構文としても読めることを併せて確認する。
if command -v python3 >/dev/null 2>&1; then
  if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$cmp_both" >/dev/null 2>&1; then
    pass
  else
    # PyYAML 不在は環境側の都合で、生成物の欠陥ではない。読めなかった場合だけ
    # 落とすと環境差で偽の赤が出るため、解釈できたときのみ判定する。
    python3 -c 'import yaml' >/dev/null 2>&1 \
      && fail "compose.yaml を YAML として解釈できない" \
      || pass
  fi
else
  pass
fi

# ── 未指定 ────────────────────────────────────────────────────────────────────

OUT_NONE="$(new_workdir)/p"
run_bootstrap "$OUT_NONE" >/dev/null 2>&1

it "どちらのフラグも指定しなければ agy 関連が 1 行も入らない"
hits="$(grep -rniE 'agy|antigravity' "$OUT_NONE" 2>/dev/null | head -n 5)"
if [[ -z "$hits" ]]; then
  pass
else
  fail "agy 関連が残っている: $hits"
fi

it "--with-gemini 単独では agy 関連が 1 行も入らない"
# 束ねない判断の対偶。gemini を選んだだけで agy が入るなら、フラグを分けた意味が
# 無くなる。
OUT_GEM="$(new_workdir)/p"
run_bootstrap "$OUT_GEM" --with-gemini >/dev/null 2>&1
hits="$(grep -rniE 'agy|antigravity' "$OUT_GEM" 2>/dev/null | head -n 5)"
if [[ -z "$hits" ]]; then
  pass
else
  fail "agy 関連が残っている: $hits"
fi

it "--with-gemini 単独でも gemini-storage は 1 つだけ生成される（対照群）"
# antigravity 対応で volume 生成の条件を変えたため、従来構成が退行していない
# ことを対照として固定する。
cmp_gem="$(compose_of "$OUT_GEM")"
n="$(grep -cE '^  gemini-storage:' "$cmp_gem" 2>/dev/null || true)"
assert_eq "$n" "1" "gemini-storage の定義数"

exit_with_result
