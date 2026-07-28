#!/usr/bin/env bash
# README の Doctor 節が doctor.sh の実際の検査と終了コードを網羅していることを検査する。
#
# doctor 節は「生成後に何を確認するか」の説明で、ここに載っていない検査は利用者から
# 見えない。とりわけ ${localEnv: の混入検出は、このパッケージの中核方針（資格情報を
# ホストから注入しない）を機械で担保する唯一の検査でありながら、README には言語
# ランタイムと cloud CLI の可用性しか書かれていなかった。
#
# 終了コードも同様で、FAIL>0 → 1、--strict かつ WARN>0 → 2 の 3 値なのに記載が無く、
# CI から呼ぶ利用者は 0/1 の 2 値だと誤解する。
#
# 検査対象は doctor.sh から機械抽出する。README 側に一覧を書き写しても、doctor.sh を
# 変えたときに古くなるだけで検出にならない。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-readme-doctor"

README="$PKG_DIR/README.md"
DOCTOR="$PKG_DIR/doctor.sh"

# README の Doctor 節（`## Doctor 自己診断` から次の `## ` 見出しまで）
doctor_section() {
  awk '
    /^## Doctor 自己診断/ { inside = 1; next }
    /^## / { inside = 0 }
    inside { print }
  ' "$README"
}

SECTION="$(doctor_section)"

it "README に Doctor 節がある"
if [[ -n "$SECTION" ]]; then pass; else fail "Doctor 自己診断の節を抽出できなかった"; fi

# ── 静的構造の検査対象 ────────────────────────────────────────────────────────

it "doctor.sh が実在を要求するファイルがすべて Doctor 節に載っている"
# インデントの無い require_file = 無条件に検査される静的構造。
missing=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  case "$SECTION" in
    *"$f"*) ;;
    *) missing="$missing $f" ;;
  esac
done < <(grep -E '^require_file "' "$DOCTOR" | sed 's/^require_file "//; s/"$//')
if [[ -z "$missing" ]]; then
  pass
else
  fail "Doctor 節に載っていない検査対象:$missing"
fi

it "実行時に可用性を見るコマンドがすべて Doctor 節に載っている"
cmds="$(sed -n 's/^for cmd in \(.*\); do$/\1/p' "$DOCTOR")"
missing=""
for c in $cmds aws gcloud terraform docker cargo; do
  case "$SECTION" in
    *"\`$c\`"*) ;;
    *) missing="$missing $c" ;;
  esac
done
if [[ -z "$missing" ]]; then
  pass
else
  fail "Doctor 節に載っていない可用性検査コマンド:$missing"
fi

# ── 取りこぼしていた検査カテゴリ ──────────────────────────────────────────────

it "devcontainer.json の JSON 妥当性検査が記載されている"
case "$SECTION" in
  *"妥当な JSON"*) pass ;;
  *) fail "JSON 妥当性の検査が Doctor 節に無い" ;;
esac

it "\${localEnv: の混入検出が記載されている"
# 単一引用符は意図的（${localEnv: をリテラルとして扱う）。
# shellcheck disable=SC2016
case "$SECTION" in
  *'${localEnv:'*) pass ;;
  *) fail "ホスト資格情報の注入経路（\${localEnv:）を検出する旨が Doctor 節に無い" ;;
esac

it "dockerComposeFile の参照先検査が記載されている"
case "$SECTION" in
  *"dockerComposeFile"*) pass ;;
  *) fail "dockerComposeFile の参照先検査が Doctor 節に無い" ;;
esac

it "生成スクリプトの構文検査と実行ビット検査が記載されている"
case "$SECTION" in
  *"bash -n"*)
    case "$SECTION" in
      *"実行ビット"*) pass ;;
      *) fail "実行ビットの検査が Doctor 節に無い" ;;
    esac
    ;;
  *) fail "bash -n による構文検査が Doctor 節に無い" ;;
esac

# ── 終了コード ────────────────────────────────────────────────────────────────

it "終了コード 0 / 1 / 2 の意味が記載されている"
missing=""
for code in 0 1 2; do
  case "$SECTION" in
    *"| \`$code\` |"*) ;;
    *) missing="$missing $code" ;;
  esac
done
if [[ -z "$missing" ]]; then
  pass
else
  fail "Doctor 節に意味が書かれていない終了コード:$missing"
fi

it "doctor.sh の終了コードが 3 値のままである"
# README が 3 値だと説明する根拠。実装が 2 値へ戻ったら README を直す必要がある。
if grep -q 'exit 1' "$DOCTOR" && grep -q 'exit 2' "$DOCTOR"; then
  pass
else
  fail "doctor.sh に exit 1 / exit 2 の両方が見つからない"
fi

# ── 実行例 ────────────────────────────────────────────────────────────────────

it "実行例が現行の既定出力先と整合している"
# 旧出力先名 result は README のどこにも定義が無く、コピペしても存在しないパスを指す。
case "$SECTION" in
  *"--target-dir result"*) fail "実行例に旧出力先名 result が残っている" ;;
  *) pass ;;
esac

it "doctor.sh のオプションがすべて Doctor 節に載っている"
missing=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  # 引数を取るオプションは `--target-dir <path>` の形で書かれるため、閉じ
  # バッククォートと空白の両方を許す。
  case "$SECTION" in
    *"\`$f\`"*|*"\`$f "*) ;;
    *) missing="$missing $f" ;;
  esac
done < <(sed -n '/^while \[\[ \$# -gt 0 \]\]; do/,/^done$/p' "$DOCTOR" \
  | awk '
      /^[[:space:]]*-/ {
        line = $0
        sub(/\).*$/, "", line)
        gsub(/^[[:space:]]+/, "", line)
        n = split(line, a, "|")
        for (i = 1; i <= n; i++) print a[i]
      }
    ')
if [[ -z "$missing" ]]; then
  pass
else
  fail "Doctor 節に無い doctor.sh のオプション:$missing"
fi

exit_with_result
