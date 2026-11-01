#!/usr/bin/env bash
# test-install-ai-tools-versions.sh — 生成した scripts/install-ai-tools.sh の、
# AI CLI の版の下限と、agy の SHA-512 照合つきの導入を検証する。
#
# --with-claude / --with-gemini / --with-antigravity / --with-codex で生成した
# install-ai-tools.sh を、PATH の先頭に置いた偽の npm・curl・uname・ldd・各 CLI で
# 実行する。ネットワークには出ない。HOME と TMPDIR は使い捨てのディレクトリへ向ける。
#
# 仕込みの仕組み:
#   - 各 CLI は $SB/ver/<名前> の中身をそのまま `--version` の出力として返す
#     （claude は "2.1.296 (Claude Code)"、codex は "codex-cli 0.162.1" の形）。
#   - 偽の npm は、呼ばれた引数を記録する。$SB/newver/<名前> があれば、入れ替え後の
#     版としてそれを ver へ写して CLI を置く（無ければ版は変わらない＝入れ替えても
#     古いままの失敗経路）。
#   - 偽の curl は、マニフェスト（.json）には $SB/srv/manifest.json を、それ以外の
#     URL には $SB/srv/payload を返す。呼ばれた URL を記録する。
#
# bash 3.2 互換を維持する。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-install-ai-tools-versions"

OUT="$(new_workdir)/p"
run_bootstrap "$OUT" --with-claude --with-gemini --with-antigravity --with-codex >/dev/null 2>&1
INSTALL="$OUT/scripts/install-ai-tools.sh"

AGY_NEW_VERSION="1.4.0"

# 版の出力の形（CLI ごと）。$1=名前 $2=版
fmt_version() {
  case "$1" in
    claude) printf '%s (Claude Code)' "$2" ;;
    codex)  printf 'codex-cli %s' "$2" ;;
    *)      printf '%s' "$2" ;;
  esac
}

# 偽の CLI を置く。$1=SB $2=名前 $3=版の出力全体
put_cli() {
  mkdir -p "$1/ver" "$1/bin"
  printf '%s\n' "$3" > "$1/ver/$2"
  cat > "$1/bin/$2" <<STUB
#!/usr/bin/env bash
if [[ "\${1-}" == "--version" ]]; then
  cat "$1/ver/$2"
fi
exit 0
STUB
  chmod +x "$1/bin/$2"
}

# 使い捨ての作業場を作る。全 CLI を下限以上の版で置く（agy は無し）。
# 作業場の パスを返す。
new_sandbox() {
  local sb
  sb="$(new_workdir)/sb"
  mkdir -p "$sb/bin" "$sb/home/.local/bin" "$sb/tmp" "$sb/srv" "$sb/ver" "$sb/newver"
  put_cli "$sb" claude "$(fmt_version claude 2.1.314)"
  put_cli "$sb" gemini "$(fmt_version gemini 0.64.0)"
  put_cli "$sb" codex "$(fmt_version codex 0.162.1)"

  cat > "$sb/bin/npm" <<STUB
#!/usr/bin/env bash
echo "\$@" >> "$sb/npm.log"
pkg="\${3-}"
case "\$pkg" in
  @anthropic-ai/claude-code*) cmd=claude ;;
  @google/gemini-cli*) cmd=gemini ;;
  @openai/codex*) cmd=codex ;;
  *) exit 0 ;;
esac
if [[ -f "$sb/newver/\$cmd" ]]; then
  cp "$sb/newver/\$cmd" "$sb/ver/\$cmd"
  cat > "$sb/bin/\$cmd" <<INNER
#!/usr/bin/env bash
if [[ "\\\${1-}" == "--version" ]]; then
  cat "$sb/ver/\$cmd"
fi
exit 0
INNER
  chmod +x "$sb/bin/\$cmd"
fi
exit 0
STUB
  chmod +x "$sb/bin/npm"

  cat > "$sb/bin/curl" <<STUB
#!/usr/bin/env bash
out=""
url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift ;;
    -*) ;;
    *) url="\$1" ;;
  esac
  shift
done
echo "\$url" >> "$sb/curl.log"
case "\$url" in
  *.json)
    [[ -f "$sb/srv/manifest.json" ]] || exit 22
    cat "$sb/srv/manifest.json"
    ;;
  *)
    [[ -f "$sb/srv/payload" ]] || exit 22
    cp "$sb/srv/payload" "\$out"
    ;;
esac
STUB
  chmod +x "$sb/bin/curl"

  # 判定を決め打ちにする（実機が何であっても同じ結果になる）。
  cat > "$sb/bin/uname" <<STUB
#!/usr/bin/env bash
case "\${1-}" in
  -s) echo "\${FAKE_UNAME_S:-Linux}" ;;
  -m) echo "\${FAKE_UNAME_M:-x86_64}" ;;
  -o) echo "\${FAKE_UNAME_O:-GNU/Linux}" ;;
  *) echo "\${FAKE_UNAME_S:-Linux}" ;;
esac
STUB
  chmod +x "$sb/bin/uname"
  cat > "$sb/bin/ldd" <<STUB
#!/usr/bin/env bash
echo "\${FAKE_LDD_OUT:-libc.so.6 => /lib/libc.so.6}"
STUB
  chmod +x "$sb/bin/ldd"
  printf '%s' "$sb"
}

# agy の本体（偽）を tar.gz にして $SB/srv/payload へ置き、その SHA-512 を返す。
# 本体は --version で $AGY_NEW_VERSION を返し、install で $HOME/agy-install-called を作る。
make_agy_payload() {
  local sb="$1" d
  d="$(new_workdir)/payload"
  mkdir -p "$d"
  cat > "$d/antigravity" <<STUB
#!/usr/bin/env bash
case "\${1-}" in
  --version) echo "$AGY_NEW_VERSION" ;;
  install) touch "\$HOME/agy-install-called" ;;
esac
exit 0
STUB
  chmod +x "$d/antigravity"
  tar -czf "$sb/srv/payload" -C "$d" antigravity
  sha512sum "$sb/srv/payload" | cut -d' ' -f1
}

# マニフェストを書く。$1=SB $2=版 $3=sha512（空ならキーを欠かす）
write_manifest() {
  local sb="$1" ver="$2" sha="$3"
  if [[ -n "$sha" ]]; then
    printf '{"version":"%s","url":"https://example.invalid/agy.tar.gz","sha512":"%s"}\n' "$ver" "$sha" > "$sb/srv/manifest.json"
  else
    printf '{"version":"%s","url":"https://example.invalid/agy.tar.gz"}\n' "$ver" > "$sb/srv/manifest.json"
  fi
}

# install-ai-tools.sh を作業場で実行する。結果は RUN_OUT（標準出力＋標準エラー）と RUN_RC。
# 追加の環境変数は引数（NAME=値）で渡す。
run_install() {
  local sb="$1"; shift
  RUN_OUT="$(env HOME="$sb/home" TMPDIR="$sb/tmp" PATH="$sb/bin:$sb/home/.local/bin:/usr/bin:/bin" "$@" bash "$INSTALL" 2>&1)"
  RUN_RC=$?
}

npm_called_with() { grep -q -- "$2" "$1/npm.log" 2>/dev/null; }

# ── claude・gemini の版の下限 ────────────────────────────────────────────────

it "claude が下限より古ければ @latest で入れ替え、名前・今の版・下限を出す"
SB="$(new_sandbox)"
put_cli "$SB" claude "$(fmt_version claude 2.1.296)"
fmt_version claude 2.1.320 > "$SB/newver/claude"
# agy は導入済みの新しい版にして、この件に集中する。
put_cli "$SB" agy "1.3.4"
run_install "$SB"
if [[ "$RUN_RC" -eq 0 ]] && npm_called_with "$SB" 'install -g @anthropic-ai/claude-code@latest' \
   && printf '%s' "$RUN_OUT" | grep 'claude 2.1.296 は 2.1.314 未満です' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC npm=$(cat "$SB/npm.log" 2>/dev/null | tr '\n' ';') out=$RUN_OUT"
fi

it "claude が下限ちょうどなら入れない（npm を呼ばない）"
SB="$(new_sandbox)"
put_cli "$SB" agy "1.3.4"
run_install "$SB"
if [[ "$RUN_RC" -eq 0 && ! -s "$SB/npm.log" ]] && printf '%s' "$RUN_OUT" | grep 'claude 2.1.314 already installed' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC npm=$(cat "$SB/npm.log" 2>/dev/null | tr '\n' ';') out=$RUN_OUT"
fi

it "claude が桁の多い新しい版（2.10.0）でも入れない（数値比較）"
SB="$(new_sandbox)"
put_cli "$SB" claude "$(fmt_version claude 2.10.0)"
put_cli "$SB" agy "1.3.4"
run_install "$SB"
if [[ "$RUN_RC" -eq 0 && ! -s "$SB/npm.log" ]]; then pass; else fail "rc=$RUN_RC out=$RUN_OUT"; fi

it "claude を入れ替えても下限未満のままなら非 0 で、理由を出す"
SB="$(new_sandbox)"
put_cli "$SB" claude "$(fmt_version claude 2.1.296)"
put_cli "$SB" agy "1.3.4"
run_install "$SB"
if [[ "$RUN_RC" -ne 0 ]] && npm_called_with "$SB" 'claude-code@latest' \
   && printf '%s' "$RUN_OUT" | grep '導入後も claude の版が 2.1.314 未満' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

it "claude が無ければ npm で入れる"
SB="$(new_sandbox)"
rm -f "$SB/bin/claude" "$SB/ver/claude"
fmt_version claude 2.1.320 > "$SB/newver/claude"
put_cli "$SB" agy "1.3.4"
run_install "$SB"
if [[ "$RUN_RC" -eq 0 ]] && npm_called_with "$SB" 'claude-code@latest'; then pass; else fail "rc=$RUN_RC out=$RUN_OUT"; fi

it "gemini が下限より古ければ @latest で入れ替え、名前・今の版・下限を出す"
SB="$(new_sandbox)"
put_cli "$SB" gemini "0.63.9"
fmt_version gemini 0.65.0 > "$SB/newver/gemini"
put_cli "$SB" agy "1.3.4"
run_install "$SB"
if [[ "$RUN_RC" -eq 0 ]] && npm_called_with "$SB" 'install -g @google/gemini-cli@latest' \
   && printf '%s' "$RUN_OUT" | grep 'gemini 0.63.9 は 0.64.0 未満です' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

it "gemini が下限以上なら入れない"
SB="$(new_sandbox)"
put_cli "$SB" gemini "0.64.0"
put_cli "$SB" agy "1.3.4"
run_install "$SB"
if [[ "$RUN_RC" -eq 0 ]] && ! npm_called_with "$SB" 'gemini-cli'; then pass; else fail "rc=$RUN_RC out=$RUN_OUT"; fi

it "gemini を入れ替えても下限未満のままなら非 0"
SB="$(new_sandbox)"
put_cli "$SB" gemini "0.60.0"
put_cli "$SB" agy "1.3.4"
run_install "$SB"
if [[ "$RUN_RC" -ne 0 ]] && printf '%s' "$RUN_OUT" | grep '導入後も gemini の版が 0.64.0 未満' >/dev/null; then pass; else fail "rc=$RUN_RC out=$RUN_OUT"; fi

it "codex は下限（0.156.0）未満なら入れ替える（共通の関数を使う）"
SB="$(new_sandbox)"
put_cli "$SB" codex "$(fmt_version codex 0.100.0)"
fmt_version codex 0.162.1 > "$SB/newver/codex"
put_cli "$SB" agy "1.3.4"
run_install "$SB"
if [[ "$RUN_RC" -eq 0 ]] && npm_called_with "$SB" 'install -g @openai/codex@latest' \
   && printf '%s' "$RUN_OUT" | grep 'codex 0.100.0 は 0.156.0 未満です' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

it "claude の版に前置の v やプレリリースの印が付いていても読み、下限以上なら入れない"
SB="$(new_sandbox)"
put_cli "$SB" claude "v2.1.320-beta.1 (Claude Code)"
put_cli "$SB" agy "1.3.4"
run_install "$SB"
if [[ "$RUN_RC" -eq 0 ]] && ! npm_called_with "$SB" '@anthropic-ai/claude-code' \
   && printf '%s' "$RUN_OUT" | grep 'claude 2.1.320-beta.1 already installed' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC npm=$(cat "$SB/npm.log" 2>/dev/null | tr '\n' ';') out=$RUN_OUT"
fi

it "claude が下限と同じ番号のプレリリース版（2.1.314-beta.1）なら、古いとして入れ替える"
SB="$(new_sandbox)"
put_cli "$SB" claude "2.1.314-beta.1 (Claude Code)"
fmt_version claude 2.1.320 > "$SB/newver/claude"
put_cli "$SB" agy "1.3.4"
run_install "$SB"
if [[ "$RUN_RC" -eq 0 ]] && npm_called_with "$SB" 'install -g @anthropic-ai/claude-code@latest' \
   && printf '%s' "$RUN_OUT" | grep 'claude 2.1.314-beta.1 は 2.1.314 未満です' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

it "gemini の --version が非 0 で終われば、出力の数字（Node.js 22.0.0）を版とみなさず入れ替える"
SB="$(new_sandbox)"
cat > "$SB/bin/gemini" <<'STUB'
#!/usr/bin/env bash
echo "Node.js 22.0.0 is required"
exit 1
STUB
chmod +x "$SB/bin/gemini"
fmt_version gemini 0.66.0 > "$SB/newver/gemini"
put_cli "$SB" agy "1.3.4"
run_install "$SB"
if [[ "$RUN_RC" -eq 0 ]] && npm_called_with "$SB" 'install -g @google/gemini-cli@latest' \
   && printf '%s' "$RUN_OUT" | grep 'gemini （版を読めません） は 0.64.0 未満です' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC npm=$(cat "$SB/npm.log" 2>/dev/null | tr '\n' ';') out=$RUN_OUT"
fi

it "claude を入れ替えても下限未満のままなら、PATH の先の別の claude を疑う案内を出す"
SB="$(new_sandbox)"
put_cli "$SB" claude "$(fmt_version claude 2.1.296)"
put_cli "$SB" agy "1.3.4"
run_install "$SB"
if [[ "$RUN_RC" -ne 0 ]] && printf '%s' "$RUN_OUT" | grep 'より前に別の claude があるか' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

# ── agy: SHA-512 を照合して置く ─────────────────────────────────────────────

it "agy: SHA-512 が合えば本体を置き、agy install を呼ぶ"
SB="$(new_sandbox)"
sha="$(make_agy_payload "$SB")"
write_manifest "$SB" "$AGY_NEW_VERSION" "$sha"
run_install "$SB"
if [[ "$RUN_RC" -eq 0 && -x "$SB/home/.local/bin/agy" && -f "$SB/home/agy-install-called" ]] \
   && grep -q 'manifests/linux_amd64.json' "$SB/curl.log"; then
  pass
else
  fail "rc=$RUN_RC curl=$(cat "$SB/curl.log" 2>/dev/null | tr '\n' ';') out=$RUN_OUT"
fi

it "agy: 置いた本体が動く（--version が返る）"
if [[ "$("$SB/home/.local/bin/agy" --version 2>/dev/null)" == "$AGY_NEW_VERSION" ]]; then pass; else fail "版が違う"; fi

it "agy: 成功しても一時ディレクトリを残さない"
if [[ -z "$(ls -A "$SB/tmp")" ]]; then pass; else fail "残っている: $(ls -A "$SB/tmp")"; fi

it "agy: SHA-512 が合わなければ、何も置かずに非 0（理由を出す）"
SB="$(new_sandbox)"
make_agy_payload "$SB" >/dev/null
write_manifest "$SB" "$AGY_NEW_VERSION" "$(printf '0%.0s' $(seq 1 128))"
run_install "$SB"
if [[ "$RUN_RC" -ne 0 && ! -e "$SB/home/.local/bin/agy" ]] && printf '%s' "$RUN_OUT" | grep 'SHA-512' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

it "agy: 照合に失敗しても一時ディレクトリを残さない"
if [[ -z "$(ls -A "$SB/tmp")" ]]; then pass; else fail "残っている: $(ls -A "$SB/tmp")"; fi

it "agy: マニフェストを読めなければ、何も置かずに非 0（理由を出す）"
SB="$(new_sandbox)"
make_agy_payload "$SB" >/dev/null
run_install "$SB"
if [[ "$RUN_RC" -ne 0 && ! -e "$SB/home/.local/bin/agy" ]] && printf '%s' "$RUN_OUT" | grep 'マニフェストを取得できません' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

it "agy: マニフェストにキー（sha512）が欠けていれば、何も置かずに非 0（理由を出す）"
SB="$(new_sandbox)"
make_agy_payload "$SB" >/dev/null
write_manifest "$SB" "$AGY_NEW_VERSION" ""
run_install "$SB"
if [[ "$RUN_RC" -ne 0 && ! -e "$SB/home/.local/bin/agy" ]] && printf '%s' "$RUN_OUT" | grep 'マニフェストの形が想定と違います' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

it "agy: マニフェストが JSON として壊れていれば（末尾のカンマ）、何も置かずに非 0"
SB="$(new_sandbox)"
sha="$(make_agy_payload "$SB")"
printf '{"version":"%s","url":"https://example.invalid/agy.tar.gz","sha512":"%s",}\n' "$AGY_NEW_VERSION" "$sha" > "$SB/srv/manifest.json"
run_install "$SB"
if [[ "$RUN_RC" -ne 0 && ! -e "$SB/home/.local/bin/agy" ]] && printf '%s' "$RUN_OUT" | grep 'マニフェストの形が想定と違います' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

it "agy: キーが最上位に無い（入れ子の）マニフェストなら、何も置かずに非 0"
SB="$(new_sandbox)"
sha="$(make_agy_payload "$SB")"
printf '{"asset":{"version":"%s","url":"https://example.invalid/agy.tar.gz","sha512":"%s"}}\n' "$AGY_NEW_VERSION" "$sha" > "$SB/srv/manifest.json"
run_install "$SB"
if [[ "$RUN_RC" -ne 0 && ! -e "$SB/home/.local/bin/agy" ]] && printf '%s' "$RUN_OUT" | grep 'マニフェストの形が想定と違います' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

it "agy: 取り出した本体の版が下限未満なら、SHA-512 が合っていても何も置かずに非 0"
SB="$(new_sandbox)"
sha="$(AGY_NEW_VERSION=1.2.0 make_agy_payload "$SB")"
write_manifest "$SB" "$AGY_NEW_VERSION" "$sha"
run_install "$SB"
if [[ "$RUN_RC" -ne 0 && ! -e "$SB/home/.local/bin/agy" ]] && printf '%s' "$RUN_OUT" | grep '取り出した agy の本体の版が 1.3.4 未満' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

it "agy: 置き先（~/.local/bin/agy）がディレクトリなら、中へ移さずに非 0"
SB="$(new_sandbox)"
sha="$(make_agy_payload "$SB")"
write_manifest "$SB" "$AGY_NEW_VERSION" "$sha"
mkdir -p "$SB/home/.local/bin/agy"
run_install "$SB"
if [[ "$RUN_RC" -ne 0 && -z "$(ls -A "$SB/home/.local/bin/agy")" ]] && printf '%s' "$RUN_OUT" | grep 'ディレクトリのため、agy を置けません' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC 中身=$(ls -A "$SB/home/.local/bin/agy") out=$RUN_OUT"
fi

it "agy: マニフェストの版が下限（1.3.4）未満なら、何も置かずに非 0（理由を出す）"
SB="$(new_sandbox)"
sha="$(make_agy_payload "$SB")"
write_manifest "$SB" "1.3.3" "$sha"
run_install "$SB"
if [[ "$RUN_RC" -ne 0 && ! -e "$SB/home/.local/bin/agy" ]] && printf '%s' "$RUN_OUT" | grep '下限 1.3.4 未満' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

it "agy: 本体の取得に失敗すれば、何も置かずに非 0"
SB="$(new_sandbox)"
sha="$(make_agy_payload "$SB")"
write_manifest "$SB" "$AGY_NEW_VERSION" "$sha"
rm -f "$SB/srv/payload"
run_install "$SB"
if [[ "$RUN_RC" -ne 0 && ! -e "$SB/home/.local/bin/agy" ]] && printf '%s' "$RUN_OUT" | grep '本体を取得できません' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

# ── agy: 既にある agy ───────────────────────────────────────────────────────

it "agy: 既にある agy が下限未満なら入れ替える（名前・今の版・下限を出す）"
SB="$(new_sandbox)"
put_cli "$SB" agy "1.2.0"
mv "$SB/bin/agy" "$SB/home/.local/bin/agy"
sha="$(make_agy_payload "$SB")"
write_manifest "$SB" "$AGY_NEW_VERSION" "$sha"
run_install "$SB"
if [[ "$RUN_RC" -eq 0 ]] \
   && [[ "$("$SB/home/.local/bin/agy" --version 2>/dev/null)" == "$AGY_NEW_VERSION" ]] \
   && printf '%s' "$RUN_OUT" | grep 'agy 1.2.0 は 1.3.4 未満です' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

it "agy: 既にある agy が下限以上なら何もしない（curl を呼ばない）"
SB="$(new_sandbox)"
put_cli "$SB" agy "1.3.4"
run_install "$SB"
if [[ "$RUN_RC" -eq 0 && ! -e "$SB/curl.log" ]] && printf '%s' "$RUN_OUT" | grep 'agy 1.3.4 already installed' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

# ── agy: プラットフォーム ───────────────────────────────────────────────────

it "agy: 対応表に無いプラットフォーム（Android）は、理由を出して非 0（curl を呼ばない）"
SB="$(new_sandbox)"
sha="$(make_agy_payload "$SB")"
write_manifest "$SB" "$AGY_NEW_VERSION" "$sha"
run_install "$SB" FAKE_UNAME_O=Android
if [[ "$RUN_RC" -ne 0 && ! -e "$SB/curl.log" && ! -e "$SB/home/.local/bin/agy" ]] \
   && printf '%s' "$RUN_OUT" | grep '配布に無いプラットフォームです: android_amd64' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

it "agy: 対応しない OS は、理由を出して非 0"
SB="$(new_sandbox)"
run_install "$SB" FAKE_UNAME_S=FreeBSD
if [[ "$RUN_RC" -ne 0 && ! -e "$SB/curl.log" ]] && printf '%s' "$RUN_OUT" | grep '対応しない OS' >/dev/null; then pass; else fail "rc=$RUN_RC out=$RUN_OUT"; fi

it "agy: 対応しないアーキテクチャは、理由を出して非 0"
SB="$(new_sandbox)"
run_install "$SB" FAKE_UNAME_M=riscv64
if [[ "$RUN_RC" -ne 0 && ! -e "$SB/curl.log" ]] && printf '%s' "$RUN_OUT" | grep '対応しないアーキテクチャ' >/dev/null; then pass; else fail "rc=$RUN_RC out=$RUN_OUT"; fi

it "agy: arm64 の darwin と、musl の linux を、表どおりのマニフェストへ引く"
SB="$(new_sandbox)"
run_install "$SB" FAKE_UNAME_S=Darwin FAKE_UNAME_M=arm64
d_ok=0; grep -q 'manifests/darwin_arm64.json' "$SB/curl.log" 2>/dev/null && d_ok=1
SB="$(new_sandbox)"
run_install "$SB" FAKE_LDD_OUT="musl libc (aarch64)" FAKE_UNAME_M=aarch64
m_ok=0; grep -q 'manifests/linux_arm64_musl.json' "$SB/curl.log" 2>/dev/null && m_ok=1
if [[ "$d_ok" -eq 1 && "$m_ok" -eq 1 ]]; then pass; else fail "darwin_arm64=$d_ok linux_arm64_musl=$m_ok"; fi

# ── 雛形・値の一致 ──────────────────────────────────────────────────────────

it "agy: SHA-512 を計算する道具が無ければ、「一致しない」ではなくその理由を出して非 0"
SB="$(new_sandbox)"
sha="$(make_agy_payload "$SB")"
write_manifest "$SB" "$AGY_NEW_VERSION" "$sha"
# /usr/bin と /bin のコマンドを、sha512sum と shasum だけ除いて並べた PATH で動かす。
mkdir -p "$SB/sys"
for f in /usr/bin/* /bin/*; do
  b="${f##*/}"
  case "$b" in sha512sum|shasum) continue ;; esac
  [[ -e "$SB/sys/$b" ]] || ln -s "$f" "$SB/sys/$b"
done
RUN_OUT="$(env HOME="$SB/home" TMPDIR="$SB/tmp" PATH="$SB/bin:$SB/home/.local/bin:$SB/sys" bash "$INSTALL" 2>&1)"
RUN_RC=$?
if [[ "$RUN_RC" -ne 0 && ! -e "$SB/home/.local/bin/agy" ]] \
   && printf '%s' "$RUN_OUT" | grep 'SHA-512 を計算する道具' >/dev/null \
   && ! printf '%s' "$RUN_OUT" | grep 'マニフェストと一致しません' >/dev/null; then
  pass
else
  fail "rc=$RUN_RC out=$RUN_OUT"
fi

it "雛形に、遠くのスクリプトを実行する「| bash」「| sh」の行が無い"
if ! grep -Eq '\|[[:space:]]*(bash|sh)([[:space:]]|$)' "$INSTALL"; then pass; else fail "$(grep -nE '\|[[:space:]]*(bash|sh)([[:space:]]|$)' "$INSTALL")"; fi

it "bootstrap.sh 本体にも、install-ai-tools.sh の雛形に「curl ... | bash」の行が無い"
if ! grep -Eq 'curl[^#]*\|[[:space:]]*(bash|sh)([[:space:]]|$)' "$BOOTSTRAP"; then pass; else fail "$(grep -nE 'curl[^#]*\|[[:space:]]*(bash|sh)([[:space:]]|$)' "$BOOTSTRAP")"; fi

it "claude の下限が doctor.sh の CLAUDE_MIN_VERSION と一致する"
doctor_min="$(sed -n 's/^CLAUDE_MIN_VERSION="\([0-9.]*\)".*/\1/p' "$PKG_DIR/doctor.sh" | head -n 1)"
install_min="$(sed -n 's/^install_if_missing claude "[^"]*" "\([0-9.]*\)"$/\1/p' "$INSTALL" | head -n 1)"
if [[ -n "$doctor_min" && "$doctor_min" == "$install_min" ]]; then pass; else fail "doctor.sh='$doctor_min' install-ai-tools.sh='$install_min'"; fi

it "リポジトリ自身の scripts/install-ai-tools.sh の claude の下限も doctor.sh と一致する"
repo_min="$(sed -n 's/^install_if_missing claude "[^"]*" "\([0-9.]*\)"$/\1/p' "$REPO_ROOT/scripts/install-ai-tools.sh" | head -n 1)"
if [[ -n "$doctor_min" && "$doctor_min" == "$repo_min" ]]; then pass; else fail "doctor.sh='$doctor_min' repo='$repo_min'"; fi

exit_with_result
