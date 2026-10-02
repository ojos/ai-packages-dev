#!/usr/bin/env bash
# test-codex.sh — --with-codex（Codex CLI）の条件配線を検証する。
#
# codex は他の AI CLI と 2 点で違い、その 2 点がこのテストの対象になる。
#
#   1. npm 配布ではあるが、版の下限がある。第二意見レビューの既定モデルを引ける
#      版より古い CLI が既に入っている場合、install_if_missing の同型（「在れば
#      飛ばす」）に乗ると、古い版のまま更新されずレビューのたびに失敗する。
#      そのため agy と同じく専用の関数（__CODEX_FUNCTION_LINES__）を持つ。
#   2. 資格情報を ~/.codex へ置く。gemini / antigravity とは共有しない専用の
#      設定ディレクトリなので、永続 volume も専用になる（gemini-storage を
#      共有する agy とは対照的）。
#
# 版の下限チェックの振る舞い（冪等・更新成功・更新失敗）は、生成された
# install-ai-tools.sh を実際に実行して確かめる（test-agy-telemetry.sh が
# 開発リポジトリの正本を実行して確かめるのと同じ方針。ただしこのリポジトリ自身の
# devcontainer には codex を入れないため、codex 用の正本の写しを持たず、
# 生成物そのものを対象にする）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-codex"

compose_of() { printf '%s' "$1/.devcontainer/compose.yaml"; }

# ── フラグそのもの ────────────────────────────────────────────────────────────

it "--with-codex を実装が受理する"
if impl_flags | grep -x -- '--with-codex' >/dev/null; then
  pass
else
  fail "引数解析が --with-codex を持たない"
fi

it "usage に --with-codex が載る"
if bash "$BOOTSTRAP" --help 2>&1 | grep -- '--with-codex' >/dev/null; then
  pass
else
  fail "--help の出力に載っていない"
fi

# ── 生成: --with-codex 単独 ───────────────────────────────────────────────────

OUT_CX="$(new_workdir)/p"
run_bootstrap "$OUT_CX" --with-codex >/dev/null 2>&1
CX_INSTALL="$OUT_CX/scripts/install-ai-tools.sh"

it "単独指定で codex の導入行が入る"
if grep -q '@openai/codex@latest' "$CX_INSTALL" 2>/dev/null \
   && grep -q '^install_codex_if_missing$' "$CX_INSTALL" 2>/dev/null; then
  pass
else
  fail "install-ai-tools.sh に codex の導入が入っていない"
fi

it "単独指定では npm 経由の他 AI CLI 導入行が入らない"
if ! grep -q '^install_if_missing ' "$CX_INSTALL" 2>/dev/null; then
  pass
else
  fail "選んでいない CLI の導入行がある: $(grep '^install_if_missing ' "$CX_INSTALL" | tr '\n' ' ')"
fi

it "単独指定では agy 関連が入らない"
if ! grep -qiE 'agy|antigravity' "$CX_INSTALL" 2>/dev/null; then
  pass
else
  fail "agy 関連が残っている"
fi

it "関数定義が呼び出しより前にある"
def_line="$(grep -n '^install_codex_if_missing() {' "$CX_INSTALL" 2>/dev/null | head -n 1 | cut -d: -f1)"
call_line="$(grep -n '^install_codex_if_missing$' "$CX_INSTALL" 2>/dev/null | head -n 1 | cut -d: -f1)"
if [[ -n "$def_line" && -n "$call_line" && "$def_line" -lt "$call_line" ]]; then
  pass
else
  fail "定義 $def_line / 呼び出し $call_line の順序が不正"
fi

it "版の下限を検査する（CODEX_MIN_VERSION）"
if grep -q '^CODEX_MIN_VERSION=' "$CX_INSTALL" 2>/dev/null; then
  pass
else
  fail "版の下限チェックが無い"
fi

it "読めない版文字列は古い扱いにする（fail-closed）"
if grep -q 'have !~ /\^\[0-9\]+\\\.\[0-9\]+\\\.\[0-9\]+\$/.*exit 0' "$CX_INSTALL" 2>/dev/null; then
  pass
else
  fail "読めない版の扱いが見当たらない"
fi

# ── 永続 volume: 単独 ─────────────────────────────────────────────────────────

it "単独指定で /home/vscode/.codex の named volume が生成される"
cmp_cx="$(compose_of "$OUT_CX")"
if grep -q 'codex-storage:/home/vscode/\.codex' "$cmp_cx" 2>/dev/null \
   && grep -qE '^  codex-storage:' "$cmp_cx" 2>/dev/null; then
  pass
else
  fail "codex-storage が定義・マウントされていない"
fi

# ── security_opt: 単独 ────────────────────────────────────────────────────────
#
# codex のサンドボックス（bwrap）は、Docker の既定の seccomp（namespace の作成。Docker
# Desktop でも）と、ネイティブ Linux では AppArmor の docker-default（mount）にも止められる
# （#392 で実測）。片方だけでは動かないので、2 つがそろって app に入ることを見る。

# app サービスの security_opt の要素を 1 行 1 件で返す（無ければ空）。
security_opts_of() {
  awk '
    /^    security_opt:$/ { in_opt = 1; next }
    in_opt && /^      - / { sub(/^      - /, ""); print; next }
    { in_opt = 0 }
  ' "$1" 2>/dev/null
}

it "単独指定で app に apparmor=unconfined と seccomp=unconfined がそろって入る"
opts="$(security_opts_of "$cmp_cx" | sort | tr '\n' ' ')"
if [[ "$opts" == "apparmor=unconfined seccomp=unconfined " ]]; then
  pass
else
  fail "security_opt が期待と違う: [$opts]"
fi

it "security_opt は services.app の直下に置かれる（volumes: より前）"
opt_line="$(grep -n '^    security_opt:$' "$cmp_cx" 2>/dev/null | head -n 1 | cut -d: -f1)"
top_vol_line="$(grep -n '^volumes:$' "$cmp_cx" 2>/dev/null | head -n 1 | cut -d: -f1)"
if [[ -n "$opt_line" && -n "$top_vol_line" && "$opt_line" -lt "$top_vol_line" ]]; then
  pass
else
  fail "security_opt $opt_line / トップレベル volumes $top_vol_line の位置が不正"
fi

it "単独指定で所有権修復の対象に入る"
if grep -q 'fix_mount "/home/vscode/\.codex"' "$OUT_CX/scripts/fix-mount-owner.sh" 2>/dev/null; then
  pass
else
  fail "fix-mount-owner.sh の対象に入っていない"
fi

it "単独指定で実マウント検査の対象に入る"
if grep -q 'check_mounted "/home/vscode/\.codex" "codex-storage"' \
     "$OUT_CX/scripts/post-rebuild-check.sh" 2>/dev/null; then
  pass
else
  fail "post-rebuild-check.sh の対象に入っていない"
fi

it "単独指定で codex の CLI 検査が入る"
if grep -q 'command -v codex ' "$OUT_CX/scripts/post-rebuild-check.sh" 2>/dev/null; then
  pass
else
  fail "post-rebuild-check.sh に codex の検査が無い"
fi

it "単独指定で .env.example に codex を含むエンジン選択欄が入る（gemini | codex）"
env_cx="$OUT_CX/.env.example"
if grep -q '^SECOND_OPINION_ENGINE=$' "$env_cx" 2>/dev/null \
   && grep -q 'gemini | codex' "$env_cx" 2>/dev/null \
   && grep -q '^SECOND_OPINION_MODEL=$' "$env_cx" 2>/dev/null; then
  pass
else
  fail ".env.example の記入欄が codex を含んでいない"
fi

it "単独指定では VS Code 拡張を追加しない"
dc_cx="$OUT_CX/.devcontainer/devcontainer.json"
if ! grep -qi 'codex' "$dc_cx" 2>/dev/null; then
  pass
else
  fail "devcontainer.json に codex の記載がある"
fi

# ── 併用: antigravity + codex（.env.example の文面の分岐） ───────────────────

OUT_AC="$(new_workdir)/p"
run_bootstrap "$OUT_AC" --with-antigravity --with-codex >/dev/null 2>&1

it "antigravity + codex では 3 エンジンの記入欄になる"
env_ac="$OUT_AC/.env.example"
if grep -q 'gemini | antigravity | codex' "$env_ac" 2>/dev/null; then
  pass
else
  fail "3 エンジンの文面になっていない"
fi

it "antigravity + codex では volume が重複しない（別名のまま 2 本）"
cmp_ac="$(compose_of "$OUT_AC")"
n_gem="$(grep -cE '^  gemini-storage:' "$cmp_ac" 2>/dev/null || true)"
n_cdx="$(grep -cE '^  codex-storage:' "$cmp_ac" 2>/dev/null || true)"
if [[ "$n_gem" == "1" && "$n_cdx" == "1" ]]; then
  pass
else
  fail "gemini-storage=$n_gem codex-storage=$n_cdx"
fi

it "antigravity + codex でも security_opt は 1 つだけ入る"
if [[ "$(grep -c '^    security_opt:$' "$cmp_ac" 2>/dev/null)" == "1" ]] \
   && [[ "$(security_opts_of "$cmp_ac" | sort | tr '\n' ' ')" == "apparmor=unconfined seccomp=unconfined " ]]; then
  pass
else
  fail "security_opt の数か中身が不正: $(grep -c '^    security_opt:$' "$cmp_ac")"
fi

it "antigravity + codex では両方の導入処理が入る"
both_install="$OUT_AC/scripts/install-ai-tools.sh"
if grep -q '^install_agy_if_missing$' "$both_install" 2>/dev/null \
   && grep -q '^install_codex_if_missing$' "$both_install" 2>/dev/null; then
  pass
else
  fail "併用なのに片方しか導入されない"
fi

# ── 未指定 / 他フラグ単独（対照） ─────────────────────────────────────────────

OUT_NONE="$(new_workdir)/p"
run_bootstrap "$OUT_NONE" >/dev/null 2>&1

it "どのフラグも指定しなければ codex 関連が 1 行も入らない"
hits="$(grep -rni 'codex' "$OUT_NONE" 2>/dev/null | head -n 5)"
if [[ -z "$hits" ]]; then
  pass
else
  fail "codex 関連が残っている: $hits"
fi

it "--with-gemini 単独では codex 関連が 1 行も入らない"
OUT_GEM="$(new_workdir)/p"
run_bootstrap "$OUT_GEM" --with-gemini >/dev/null 2>&1
hits="$(grep -rni 'codex' "$OUT_GEM" 2>/dev/null | head -n 5)"
if [[ -z "$hits" ]]; then
  pass
else
  fail "codex 関連が残っている: $hits"
fi

it "--with-antigravity 単独では codex 関連が 1 行も入らない"
# 票の制約「gemini / antigravity の挙動は変えない」の対偶。
OUT_AG="$(new_workdir)/p"
run_bootstrap "$OUT_AG" --with-antigravity >/dev/null 2>&1
hits="$(grep -rni 'codex' "$OUT_AG" 2>/dev/null | head -n 5)"
if [[ -z "$hits" ]]; then
  pass
else
  fail "codex 関連が残っている: $hits"
fi

it "codex を選ばない構成には security_opt が入らない（未指定・gemini・antigravity）"
# 隔離を弱める設定なので、サンドボックスを使う codex を選んだ構成に限る（#392）。
hits=""
for o in "$OUT_NONE" "$OUT_GEM" "$OUT_AG"; do
  [[ -n "$(security_opts_of "$(compose_of "$o")")" ]] && hits+="$o "
  grep -q 'unconfined' "$(compose_of "$o")" 2>/dev/null && hits+="$o(unconfined) "
done
if [[ -z "$hits" ]]; then
  pass
else
  fail "security_opt か unconfined が入っている: $hits"
fi

# ── 版の下限チェックの振る舞い（生成された install-ai-tools.sh を実行） ───────
#
# 本物の codex CLI は要らない。仕込みの codex / npm を PATH の先へ置き、
# 「在る・新しい → skip」「在る・古い → 入れ替え」「入れ替えても古い → 失敗」
# 「読めない版 → 古い扱い」の 4 パターンを固定する。
#
# 仕込みの codex は環境変数 FAKE_CODEX_VERSION の値をそのまま `codex-cli <値>`
# の形で返す。仕込みの npm は、呼ばれた記録を残すだけで、FAKE_CODEX_VERSION を
# 書き換えない（「入れ替えても古いままだった」失敗経路を再現するため）。
# 「入れ替えに成功した」経路は、呼び出し元が FAKE_CODEX_VERSION を
# 入れ替え後の値へ変えたうえで再実行することで表す（本物の npm install は
# バイナリの版を変えるが、スタブにその真似をさせると stub 自身が状態機械を
# 持つことになり、何を検査しているのかが読みにくくなるため）。

BEHAV_BIN="$(new_workdir)/bin"
mkdir -p "$BEHAV_BIN"

cat > "$BEHAV_BIN/codex" <<'STUB'
#!/usr/bin/env bash
if [[ "${1-}" == "--version" ]]; then
  if [[ -n "${FAKE_CODEX_VERSION:-}" ]]; then
    printf 'codex-cli %s\n' "$FAKE_CODEX_VERSION"
  fi
  exit 0
fi
exit 0
STUB
chmod +x "$BEHAV_BIN/codex"

cat > "$BEHAV_BIN/npm" <<'STUB'
#!/usr/bin/env bash
echo "$@" >> "${FAKE_NPM_CALLS:-/dev/null}"
exit 0
STUB
chmod +x "$BEHAV_BIN/npm"

# install_codex_if_missing と codex_version_is_old だけを切り出して走らせる。
# install-ai-tools.sh 全体を実行すると、選んでいない他 CLI の存在確認
# （command -v claude 等）が混ざるため、対象の 2 関数だけを抽出する。
extract_codex_funcs() {
  awk '
    /^CODEX_MIN_VERSION=/ { print; next }
    /^codex_version_is_old\(\) \{/ { inside=1 }
    /^install_codex_if_missing\(\) \{/ { inside=1 }
    inside { print; if ($0 == "}") inside=0 }
  ' "$1"
}

FUNCS_FILE="$(new_workdir)/funcs.sh"
extract_codex_funcs "$CX_INSTALL" > "$FUNCS_FILE"

it "対象の 2 関数と CODEX_MIN_VERSION を抽出できる"
if grep -q '^CODEX_MIN_VERSION=' "$FUNCS_FILE" \
   && grep -q '^codex_version_is_old() {' "$FUNCS_FILE" \
   && grep -q '^install_codex_if_missing() {' "$FUNCS_FILE"; then
  pass
else
  fail "抽出に失敗した: $(cat "$FUNCS_FILE")"
fi

run_install_codex() {
  # set -e は抽出したスニペット単体では不要（呼び出し側で終了コードを見る）。
  bash -c '
    set -uo pipefail
    . "$1"
    install_codex_if_missing
  ' _ "$FUNCS_FILE"
}

it "新しい版が既に入っていれば skip する（npm を呼ばない）"
calls_file="$(new_workdir)/npm-calls"
: > "$calls_file"
out="$(PATH="$BEHAV_BIN:$PATH" FAKE_CODEX_VERSION="0.158.0" FAKE_NPM_CALLS="$calls_file" run_install_codex)"; rc=$?
if [[ "$rc" -eq 0 ]] && [[ ! -s "$calls_file" ]] && printf '%s' "$out" | grep -q 'already installed'; then
  pass
else
  fail "skip されていない (exit $rc, npm呼び出し=$(cat "$calls_file" 2>/dev/null | wc -l)): $out"
fi

it "古い版が入っていれば npm で入れ替える"
calls_file="$(new_workdir)/npm-calls"
: > "$calls_file"
# 入れ替え後の再取得でも古い版しか返らない設定にする（失敗経路の対照）。
out="$(PATH="$BEHAV_BIN:$PATH" FAKE_CODEX_VERSION="0.100.0" FAKE_NPM_CALLS="$calls_file" run_install_codex)"; rc=$?
bad=0
[[ -s "$calls_file" ]] || { echo "  npm が呼ばれていない"; bad=1; }
grep -q '@openai/codex@latest' "$calls_file" 2>/dev/null || { echo "  npm の引数が不正: $(cat "$calls_file")"; bad=1; }
[[ "$rc" -ne 0 ]] || { echo "  入れ替え後も古いままなのに成功した (rc=$rc)"; bad=1; }
if [[ "$bad" -eq 0 ]]; then pass; else fail "古い版の扱いが誤っている: $out"; fi

it "CLI が無ければ npm で新規導入する"
calls_file="$(new_workdir)/npm-calls"
: > "$calls_file"
# codex バイナリ自体を PATH から外す（新しいディレクトリへ絞る）。
EMPTY_BIN="$(new_workdir)/emptybin"
mkdir -p "$EMPTY_BIN"
cp "$BEHAV_BIN/npm" "$EMPTY_BIN/npm"
out="$(PATH="$EMPTY_BIN:/usr/bin:/bin" FAKE_NPM_CALLS="$calls_file" run_install_codex)"; rc=$?
bad=0
[[ -s "$calls_file" ]] || { echo "  npm が呼ばれていない"; bad=1; }
# 新規導入後も codex が見つからない（スタブを置いていない）ため、版が
# 取れず「導入後も下限未満」で失敗する。これは「新規導入そのものが npm を
# 正しく呼んだか」を見るための対照であり、導入後の判定は別観点のため rc は見ない。
if [[ "$bad" -eq 0 ]]; then pass; else fail "新規導入で npm を呼んでいない: $out"; fi

it "読めない版文字列は古い扱いになる（fail-closed）"
calls_file="$(new_workdir)/npm-calls"
: > "$calls_file"
out="$(PATH="$BEHAV_BIN:$PATH" FAKE_CODEX_VERSION="unknown" FAKE_NPM_CALLS="$calls_file" run_install_codex)"; rc=$?
if [[ -s "$calls_file" ]]; then
  pass
else
  fail "読めない版なのに npm を呼んでいない（新しい扱いになっている）: $out"
fi

exit_with_result
