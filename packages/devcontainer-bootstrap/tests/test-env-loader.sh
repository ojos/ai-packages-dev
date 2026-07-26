#!/usr/bin/env bash
# プロジェクト .env ローダー（scripts/load-project-env.sh）と、生成される on-attach.sh の
# rc 注入を検証する。
#
# 規範: issue #109。remoteEnv がホスト env を注入する構造は維持したまま、プロジェクト .env を
# 後勝ちで上書きする層を DCB の生成物へ持たせる。要件は「source せず安全にパース（任意コード
# 非実行）」「CWD 非依存でスクリプト位置から解決」「bash/zsh 同一結果」「実務的な .env の揺れ
# （CRLF / export / 空白 / クォート）を吸収」「冪等」「rc 注入は冪等・マーカー判定」。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-env-loader"

# ── 生成物を 1 度だけ用意する ────────────────────────────────────────────────
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
LOADER="$out/scripts/load-project-env.sh"
ENVFILE="$out/.env"

it "生成物に load-project-env.sh が含まれる"
assert_file_exists "$LOADER"

it "load-project-env.sh は固有名詞を含まない（パッケージ中立）"
if grep -qi 'ojos' "$LOADER"; then
  fail "固有名詞 ojos が残っている"
else
  pass
fi

# ── パース各形式（bash） ─────────────────────────────────────────────────────
# CRLF・export・KEY = VALUE・二重/単一クォートを 1 つの .env にまとめて検証する。
printf 'PLAIN=plainval\r\nexport EXPORTED=e1\nSPACED = spaced\nDQ="double quoted"\nSQ='\''single quoted'\''\n# comment line\n\n' > "$ENVFILE"

it "CRLF 改行を吸収する（末尾 CR を残さない）"
assert_eq "$(bash -c ". \"$LOADER\"; printf '%s' \"\$PLAIN\"")" "plainval" "PLAIN"

it "export KEY=VALUE 記法を解釈する"
assert_eq "$(bash -c ". \"$LOADER\"; printf '%s' \"\$EXPORTED\"")" "e1" "EXPORTED"

it "KEY = VALUE（= 前後の空白）を解釈する"
assert_eq "$(bash -c ". \"$LOADER\"; printf '%s' \"\$SPACED\"")" "spaced" "SPACED"

it "二重クォート囲みを外し内部の空白を保持する"
assert_eq "$(bash -c ". \"$LOADER\"; printf '%s' \"\$DQ\"")" "double quoted" "DQ"

it "単一クォート囲みを外し内部の空白を保持する"
assert_eq "$(bash -c ". \"$LOADER\"; printf '%s' \"\$SQ\"")" "single quoted" "SQ"

# ── ホスト env を後勝ちで上書き ──────────────────────────────────────────────
it ".env の値が同名のホスト由来環境変数を上書きする（後勝ち）"
printf 'OVERRIDE=fromenv\n' > "$ENVFILE"
assert_eq "$(bash -c "export OVERRIDE=fromhost; . \"$LOADER\"; printf '%s' \"\$OVERRIDE\"")" "fromenv" "OVERRIDE"

# ── .env 不在 ────────────────────────────────────────────────────────────────
it ".env が存在しなければエラーにならず何もしない"
rm -f "$ENVFILE"
if out_rc="$(bash -c "set -e; . \"$LOADER\"; printf 'exit_ok'" 2>&1)"; then
  assert_eq "$out_rc" "exit_ok" "no-op 出力"
else
  fail ".env 不在で失敗した: $out_rc"
fi

# ── 任意コード非実行 ─────────────────────────────────────────────────────────
it "任意のシェルコマンドを含む .env を与えてもコマンドを実行しない"
marker="$out/.SHOULD_NOT_EXIST"
rm -f "$marker"
# $(...) の値・単独の echo 行・= を含まない裸トークンのいずれも実行されてはならない。
printf 'SAFE=ok\nEVIL=$(touch %s)\necho hi\nBARE_TOKEN\n' "$marker" > "$ENVFILE"
safe_val="$(bash -c ". \"$LOADER\"; printf '%s' \"\$SAFE\"")"
evil_val="$(bash -c ". \"$LOADER\"; printf '%s' \"\$EVIL\"")"
if [[ -e "$marker" ]]; then
  fail "コマンド置換が実行され marker が作られた"
elif [[ "$safe_val" != "ok" ]]; then
  fail "SAFE の解釈が誤り: $safe_val"
elif [[ "$evil_val" != '$(touch '"$marker"')' ]]; then
  fail "EVIL がリテラルで保持されていない: $evil_val"
else
  pass
fi

# ── サブディレクトリを CWD として解決 ────────────────────────────────────────
it "リポジトリのサブディレクトリを CWD にしても .env を正しく解決する"
printf 'SUBDIR_KEY=resolved\n' > "$ENVFILE"
mkdir -p "$out/scripts/deep/nested"
got="$(bash -c "cd \"$out/scripts/deep/nested\"; . \"$LOADER\"; printf '%s' \"\$SUBDIR_KEY\"")"
assert_eq "$got" "resolved" "SUBDIR_KEY"

# ── PROJECT_ENV_FILE で明示差し替え ─────────────────────────────────────────
it "PROJECT_ENV_FILE で対象 .env を明示的に差し替えできる"
alt="$(new_workdir)/alt.env"
printf 'ALT_KEY=alt\n' > "$alt"
got="$(bash -c "export PROJECT_ENV_FILE=\"$alt\"; . \"$LOADER\"; printf '%s' \"\$ALT_KEY\"")"
assert_eq "$got" "alt" "ALT_KEY"

# ── 冪等（2 回 source） ──────────────────────────────────────────────────────
it "2 回 source しても結果が変わらない"
printf 'IDEM=once\n' > "$ENVFILE"
got="$(bash -c ". \"$LOADER\"; . \"$LOADER\"; printf '%s' \"\$IDEM\"")"
assert_eq "$got" "once" "IDEM"

# ── bash と zsh で同一結果 ───────────────────────────────────────────────────
# zsh は BASH_SOURCE を持たず ${(%):-%x} で解決する。substring/クォート外しの挙動差も
# 併せて検出できるよう、複数形式を含む .env で bash と厳密一致させる。
if command -v zsh >/dev/null 2>&1; then
  printf 'A=plain\nexport B=exp\nC = spaced\nD="dq val"\nE='\''sq val'\''\n' > "$ENVFILE"
  expr='printf "%s|%s|%s|%s|%s" "$A" "$B" "$C" "$D" "$E"'
  bash_out="$(bash -c ". \"$LOADER\"; $expr")"
  zsh_out="$(zsh -c ". \"$LOADER\"; $expr")"
  it "bash と zsh で source 結果が一致する"
  assert_eq "$zsh_out" "$bash_out" "bash/zsh 結果"

  it "zsh 単体でも各形式を正しく解釈する"
  assert_eq "$zsh_out" "plain|exp|spaced|dq val|sq val" "zsh 出力"
else
  echo "  skip zsh 未導入のため bash/zsh 同一性テストをスキップ"
fi

# ── 生成 on-attach.sh の rc 注入（冪等・マーカー判定） ───────────────────────
ONATTACH="$out/scripts/on-attach.sh"
marker='# >>> project .env autoload >>>'

it "on-attach.sh を実行すると rc が無くても作成し .env autoload を注入する"
fakehome="$(new_workdir)/home"
mkdir -p "$fakehome"
HOME="$fakehome" bash "$ONATTACH" >/dev/null 2>&1 || true
if [[ -f "$fakehome/.bashrc" && -f "$fakehome/.zshrc" ]]; then
  b="$(grep -cF "$marker" "$fakehome/.bashrc")"
  z="$(grep -cF "$marker" "$fakehome/.zshrc")"
  if [[ "$b" == "1" && "$z" == "1" ]]; then pass; else fail "注入回数が想定外: bashrc=$b zshrc=$z"; fi
else
  fail "rc が作成されていない"
fi

it "on-attach.sh を 2 回実行しても rc への注入は 1 度だけ（冪等）"
HOME="$fakehome" bash "$ONATTACH" >/dev/null 2>&1 || true
b="$(grep -cF "$marker" "$fakehome/.bashrc")"
z="$(grep -cF "$marker" "$fakehome/.zshrc")"
if [[ "$b" == "1" && "$z" == "1" ]]; then pass; else fail "再実行で重複注入: bashrc=$b zshrc=$z"; fi

it "rc へ注入される helper 参照は絶対パスである"
if grep -qF "$out/scripts/load-project-env.sh" "$fakehome/.bashrc"; then pass; else fail "絶対パス参照が無い"; fi

it "既存 rc の内容を切り詰めず追記する"
# 既存内容の温存: 事前に内容を書いた rc に対して注入しても元の行が残る。
fh2="$(new_workdir)/home2"
mkdir -p "$fh2"
printf '# pre-existing user content\nalias ll="ls -la"\n' > "$fh2/.bashrc"
HOME="$fh2" bash "$ONATTACH" >/dev/null 2>&1 || true
if grep -qF 'alias ll="ls -la"' "$fh2/.bashrc" && grep -qF "$marker" "$fh2/.bashrc"; then pass; else fail "既存内容が失われた、または注入されていない"; fi

exit_with_result
