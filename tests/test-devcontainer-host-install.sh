#!/usr/bin/env bash
# devcontainer-host の install.sh（packages/devcontainer-host/install.sh）の回帰テスト（#495）。
#
# ## 何を見るか
#
# install.sh は、外部の機械へ devhost を入れる独立したスクリプト。実際の公開リリースには触れないよう、
# 偽の curl（URL の末尾のファイル名で試験が用意したファイルを写す）と偽の systemctl（呼び出しを記録する）を
# PATH の先頭に置き、HOME を一時ディレクトリにして回す。
#
#   1. 新規の導入: dev・ユニット・projects が置かれ、systemctl --user daemon-reload が呼ばれる
#   2. 既存の projects を上書きしない / 再実行は冪等 / 新しい版へ更新される
#   3. 照合が外れる・形が違う・置き換え先が不適切なら、何も置かずに非 0 で止まる
#   4. --dry-run は何も書かない
#   5. install.sh が dev.sh から写している判定（is_devhost_dev_sh など）が、dev.sh と同じ本文であること
#
# 依存: bash / jq / sha256sum（または shasum）/ cmp / awk。ネットワークには出ない。
# bash 3.2 互換を維持する。

set -uo pipefail
export LC_ALL=C
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-devcontainer-host-install"

HOST_DIR="$REPO_ROOT/packages/devcontainer-host"
INSTALL="$HOST_DIR/install.sh"
DEV_SH="$HOST_DIR/dev.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-host-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

sha_of() { sha256sum "$1" | awk '{print $1}'; }  # bsd-ok: このテストは Linux（Dev Container / CI）で回す

# 偽の curl: `-fsSL <URL> -o <出力先>` だけを受け、リリースの取得先以外は落とす。
# URL の末尾のファイル名で $FAKE_CURL_DIR のファイルを写す。呼び出しは $FAKE_LOG へ記録する。
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$FAKE_LOG"
if [[ $# -ne 4 || "$1" != "-fsSL" || "$3" != "-o" ]]; then echo "fake curl: 想定外の呼び出し: $*" >&2; exit 2; fi
case "$2" in
  https://github.com/ojos/devcontainer-host/releases/latest/download/* | https://github.com/ojos/devcontainer-host/releases/download/v*/*) ;;
  *) echo "fake curl: リリースの取得先ではない URL です: $2" >&2; exit 2 ;;
esac
if [[ "${FAKE_CURL_FAIL:-0}" == "1" ]]; then exit 22; fi
cp "$FAKE_CURL_DIR/${2##*/}" "$4" 2>/dev/null || exit 22
STUB
cat > "$FAKEBIN/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_LOG"
exit "${FAKE_SYSTEMCTL_RC:-0}"
STUB
chmod +x "$FAKEBIN/curl" "$FAKEBIN/systemctl"

# 偽のリリースを作る。使い方: make_release <ディレクトリ> <版（v なし）> <dev.sh に足す行>
make_release() {
  local dir="$1" ver="$2" extra="$3"
  mkdir -p "$dir"
  cp "$DEV_SH" "$dir/dev.sh"
  [[ -z "$extra" ]] || printf '%s\n' "$extra" >> "$dir/dev.sh"
  cp "$HOST_DIR/dev-up@.service" "$dir/dev-up@.service"
  [[ -z "$extra" ]] || printf '# %s\n' "$extra" >> "$dir/dev-up@.service"
  cp "$HOST_DIR/projects.example" "$dir/projects.example"
  write_manifest "$dir" "$ver"
}

# マニフェストを（再）生成する。使い方: write_manifest <ディレクトリ> <版>
write_manifest() {
  local dir="$1" ver="$2"
  jq -n --arg v "$ver" \
    --arg d "$(sha_of "$dir/dev.sh")" --arg u "$(sha_of "$dir/dev-up@.service")" --arg p "$(sha_of "$dir/projects.example")" \
    '{package: "devcontainer-host", version: $v, checksums: {"dev.sh": $d, "dev-up@.service": $u, "projects.example": $p}}' \
    > "$dir/RELEASE-MANIFEST.json"
}

REL1="$WORK/rel1"
REL2="$WORK/rel2"
make_release "$REL1" "0.1.0" ""
make_release "$REL2" "0.2.0" "# 新しい版"

# install.sh を、偽の道具と一時の HOME で回す。使い方: run_install <リリースのディレクトリ> [install.sh の引数...]
# 結果: RC / OUT / ERR / LOG。HOME は $H（呼び出し側で決める）。
H=""
run_install() {
  local reldir="$1"
  shift
  LOG="$WORK/calls.log"
  OUT="$WORK/out.txt"
  ERR="$WORK/err.txt"
  : > "$LOG"
  RC=0
  env -u XDG_CONFIG_HOME HOME="$H" PATH="$FAKEBIN:$PATH" FAKE_LOG="$LOG" FAKE_CURL_DIR="$reldir" \
    bash "$INSTALL" "$@" > "$OUT" 2> "$ERR" < /dev/null || RC=$?
}

new_home() {
  H="$(mktemp -d "$WORK/home.XXXXXX")"
}

# $H 配下のファイル数（何も置かれていないことの確認）。一時ファイルも数える。
files_in_home() { find "$H" -type f | wc -l | tr -d ' '; }

BIN() { echo "$H/.local/bin/dev"; }
UNIT() { echo "$H/.config/systemd/user/dev-up@.service"; }
PROJ() { echo "$H/.config/dev/projects"; }

# ── 1. 新規の導入 ─────────────────────────────────────────────────────────────

new_home
run_install "$REL1"

it "新規の導入が 0 で終わる"
if [[ $RC -eq 0 ]]; then pass; else fail "終了コード $RC: $(tail -5 "$ERR")"; fi

it "新規の導入で、dev が写しで置かれ（実行権限あり）、リリースの dev.sh と同じ"
if [[ -f "$(BIN)" && ! -L "$(BIN)" && -x "$(BIN)" ]] && cmp -s "$REL1/dev.sh" "$(BIN)"; then pass; else fail "dev が置かれていない、または内容が違う"; fi

it "新規の導入で、ユニットがリリースの dev-up@.service と同じ内容で置かれる"
if cmp -s "$REL1/dev-up@.service" "$(UNIT)"; then pass; else fail "ユニットが置かれていない、または内容が違う"; fi

it "新規の導入で、projects が projects.example から作られる"
if cmp -s "$REL1/projects.example" "$(PROJ)"; then pass; else fail "projects が作られていない、または内容が違う"; fi

it "新規の導入で、systemctl --user daemon-reload が呼ばれる"
if grep -qxF "systemctl --user daemon-reload" "$LOG"; then pass; else fail "daemon-reload の呼び出しが無い: $(cat "$LOG")"; fi

it "最新を入れるとき、マニフェストだけを latest から取り、残りはマニフェストの版から取る"
if grep -q "releases/latest/download/RELEASE-MANIFEST.json " "$LOG" \
   && grep -q "releases/download/v0.1.0/dev.sh " "$LOG" \
   && grep -q "releases/download/v0.1.0/dev-up@.service " "$LOG" \
   && grep -q "releases/download/v0.1.0/projects.example " "$LOG" \
   && ! grep -q "latest/download/dev.sh" "$LOG" \
   && ! grep -q "PACKAGE_ARCHIVE" "$LOG"; then
  pass
else
  fail "取得先が想定と違う: $(cat "$LOG")"
fi

it "新規の導入のあとに、一時ファイル（.install.*）が残らない"
if [[ -z "$(find "$H" -name '.install.*')" ]]; then pass; else fail "残っている: $(find "$H" -name '.install.*')"; fi

it "次にすること（enable-linger とプロジェクトごとの enable --now）を案内し、自動では行わない"
if grep -q 'loginctl enable-linger' "$OUT" && grep -q 'enable --now dev-up@<名前>.service' "$OUT" \
   && ! grep -q 'loginctl\|enable' "$LOG"; then
  pass
else
  fail "案内が無い、または自動で実行している: $(cat "$LOG")"
fi

# ── 2. 冪等・既存の projects・更新 ────────────────────────────────────────────

it "既存の projects は上書きしない（再実行しても、書き換えた内容のまま）"
printf 'alpha /home/me/alpha\n' > "$(PROJ)"
run_install "$REL1"
if [[ $RC -eq 0 && "$(cat "$(PROJ)")" == "alpha /home/me/alpha" ]]; then pass; else fail "終了コード $RC、projects: $(cat "$(PROJ)")"; fi

it "同じ版の再実行は冪等（dev・ユニットは同じ内容のまま、すでにこの版と案内する）"
if [[ $RC -eq 0 ]] && cmp -s "$REL1/dev.sh" "$(BIN)" && cmp -s "$REL1/dev-up@.service" "$(UNIT)" \
   && grep -q 'dev: すでにこの版' "$OUT" && grep -q 'ユニット: すでにこの版' "$OUT"; then
  pass
else
  fail "冪等でない: $(cat "$OUT")"
fi

it "新しい版を指定して再実行すると、dev とユニットが新しい版に更新され、projects は残る"
run_install "$REL2" --version v0.2.0
if [[ $RC -eq 0 ]] && cmp -s "$REL2/dev.sh" "$(BIN)" && cmp -s "$REL2/dev-up@.service" "$(UNIT)" \
   && [[ "$(cat "$(PROJ)")" == "alpha /home/me/alpha" ]] && [[ -z "$(find "$H" -name '.install.*')" ]]; then
  pass
else
  fail "更新されていない（終了コード $RC）: $(tail -5 "$ERR")"
fi

it "最新（latest）で再実行しても、マニフェストの版（v0.2.0）で取り、更新される"
cp "$REL1/dev.sh" "$(BIN)"
run_install "$REL2"
if [[ $RC -eq 0 ]] && cmp -s "$REL2/dev.sh" "$(BIN)" && grep -q "releases/download/v0.2.0/dev.sh " "$LOG"; then pass; else fail "終了コード $RC: $(cat "$LOG")"; fi

it "更新のとき、動いているユニットの起こし直し（dev restart / systemctl --user restart）を案内する"
cp "$REL1/dev.sh" "$(BIN)"
run_install "$REL2"
if grep -q '起こし直すまで古い版' "$OUT" && grep -q 'dev restart <名前>' "$OUT" && grep -q 'systemctl --user restart dev-up@<名前>.service' "$OUT"; then pass; else fail "案内が無い: $(cat "$OUT")"; fi

it "ユニットのファイルだけを更新したときも（dev は同じ）、起こし直しの案内を出し、daemon-reload は呼ぶ"
new_home
run_install "$REL1"
REL3="$WORK/rel3"
rm -rf "$REL3"
cp -R "$REL1" "$REL3"
printf '# ユニットだけ更新\n' >> "$REL3/dev-up@.service"
write_manifest "$REL3" "0.1.1"
run_install "$REL3" --version v0.1.1
if [[ $RC -eq 0 ]] && cmp -s "$REL3/dev-up@.service" "$(UNIT)" && grep -q 'dev: すでにこの版' "$OUT" \
   && grep -q '起こし直すまで古い版' "$OUT" && grep -q 'dev restart <名前>' "$OUT" && grep -qxF "systemctl --user daemon-reload" "$LOG"; then
  pass
else
  fail "終了コード $RC: $(cat "$OUT")"
fi

it "何も更新しない再実行では、起こし直しの案内は出さない"
run_install "$REL3" --version v0.1.1
if [[ $RC -eq 0 ]] && ! grep -q '起こし直す' "$OUT"; then pass; else fail "出ている: $(cat "$OUT")"; fi

it "新規の導入では、起こし直しの案内は出さない"
new_home
run_install "$REL1"
if ! grep -q '起こし直すまで' "$OUT"; then pass; else fail "新規なのに出ている"; fi

# ── 3. 何も置かずに止まる ─────────────────────────────────────────────────────

# 資産を差し替えた偽のリリースを作る。使い方: tampered <名前> <差し替えるファイル> <内容>
tampered() {
  local dir="$WORK/tampered-$1"
  rm -rf "$dir"
  cp -R "$REL1" "$dir"
  printf '%s' "$3" > "$dir/$2"
  echo "$dir"
}

for asset in dev.sh dev-up@.service projects.example; do
  it "$asset のハッシュがマニフェストと食い違えば、何も置かずに非 0 で止まる"
  new_home
  bad="$(tampered "hash-$asset" "$asset" "改ざん")"
  run_install "$bad"
  if [[ $RC -ne 0 && "$(files_in_home)" == "0" ]] && grep -q "$asset のハッシュがマニフェストと合いません" "$ERR" && ! grep -q 'daemon-reload' "$LOG"; then
    pass
  else
    fail "終了コード $RC、置かれたファイル: $(find "$H" -type f | tr '\n' ' ')"
  fi
done

it "マニフェストにハッシュが無い資産があれば、何も置かずに非 0 で止まる"
new_home
bad="$WORK/tampered-nohash"
rm -rf "$bad"
cp -R "$REL1" "$bad"
jq 'del(.checksums["dev-up@.service"])' "$REL1/RELEASE-MANIFEST.json" > "$bad/RELEASE-MANIFEST.json"
run_install "$bad"
if [[ $RC -ne 0 && "$(files_in_home)" == "0" ]] && grep -q 'checksums の dev-up@.service' "$ERR"; then pass; else fail "終了コード $RC、置かれたファイル: $(find "$H" -type f | tr '\n' ' ')"; fi

it "マニフェストのハッシュが 64 桁の 16 進でなければ、何も置かずに非 0 で止まる"
new_home
bad="$WORK/tampered-shorthash"
rm -rf "$bad"
cp -R "$REL1" "$bad"
jq '.checksums["dev.sh"] = "abc"' "$REL1/RELEASE-MANIFEST.json" > "$bad/RELEASE-MANIFEST.json"
run_install "$bad"
if [[ $RC -ne 0 && "$(files_in_home)" == "0" ]]; then pass; else fail "終了コード $RC"; fi

it "ハッシュが合っていても、devhost の dev.sh の形でなければ（2 行目が「# dev — 」でない）、何も置かずに非 0 で止まる"
new_home
bad="$WORK/tampered-shape"
rm -rf "$bad"
mkdir -p "$bad"
cp "$REL1/dev-up@.service" "$REL1/projects.example" "$bad/"
printf '#!/usr/bin/env bash\n# 別の道具\necho hi\n' > "$bad/dev.sh"
write_manifest "$bad" "0.1.0"
run_install "$bad"
if [[ $RC -ne 0 && "$(files_in_home)" == "0" ]] && grep -q 'devhost の dev.sh だと確かめられません' "$ERR"; then pass; else fail "終了コード $RC、置かれたファイル: $(find "$H" -type f | tr '\n' ' ')"; fi

it "ハッシュが合っていても、dev.sh に構文の誤りがあれば、何も置かずに非 0 で止まる"
new_home
bad="$WORK/tampered-syntax"
rm -rf "$bad"
mkdir -p "$bad"
cp "$REL1/dev-up@.service" "$REL1/projects.example" "$bad/"
printf '#!/usr/bin/env bash\n# dev — 構文の誤り\nif then fi (\n' > "$bad/dev.sh"
write_manifest "$bad" "0.1.0"
run_install "$bad"
if [[ $RC -ne 0 && "$(files_in_home)" == "0" ]] && grep -q '構文の誤り' "$ERR"; then pass; else fail "終了コード $RC、置かれたファイル: $(find "$H" -type f | tr '\n' ' ')"; fi

it "ハッシュが合っていても、ユニットが devhost のものでなければ、何も置かずに非 0 で止まる"
new_home
bad="$WORK/tampered-unit"
rm -rf "$bad"
cp -R "$REL1" "$bad"
printf '[Service]\nExecStart=/bin/true\n' > "$bad/dev-up@.service"
write_manifest "$bad" "0.1.0"
run_install "$bad"
if [[ $RC -ne 0 && "$(files_in_home)" == "0" ]]; then pass; else fail "終了コード $RC、置かれたファイル: $(find "$H" -type f | tr '\n' ' ')"; fi

it "--version で指定した版とマニフェストの版が違えば、何も置かずに非 0 で止まる"
new_home
run_install "$REL1" --version v9.9.9
if [[ $RC -ne 0 && "$(files_in_home)" == "0" ]] && grep -q 'マニフェストの版' "$ERR"; then pass; else fail "終了コード $RC"; fi

it "別のパッケージのマニフェストなら、何も置かずに非 0 で止まる"
new_home
bad="$WORK/tampered-pkg"
rm -rf "$bad"
cp -R "$REL1" "$bad"
jq '.package = "devcontainer-bootstrap"' "$REL1/RELEASE-MANIFEST.json" > "$bad/RELEASE-MANIFEST.json"
run_install "$bad"
if [[ $RC -ne 0 && "$(files_in_home)" == "0" ]]; then pass; else fail "終了コード $RC"; fi

it "取得に失敗したら、何も置かずに非 0 で止まる"
new_home
FAKE_CURL_FAIL=1 run_install "$REL1"
if [[ $RC -ne 0 && "$(files_in_home)" == "0" ]]; then pass; else fail "終了コード $RC"; fi

it "置き換え先の dev が devhost の dev.sh でなければ、取得もせず、何も変えずに非 0 で止まる"
new_home
mkdir -p "$H/.local/bin"
printf '#!/bin/sh\necho other tool\n' > "$(BIN)"
run_install "$REL1"
if [[ $RC -ne 0 && "$(cat "$(BIN)")" == "$(printf '#!/bin/sh\necho other tool')" && ! -e "$(UNIT)" && ! -e "$(PROJ)" && ! -s "$LOG" ]]; then pass; else fail "終了コード $RC、呼び出し: $(cat "$LOG")"; fi

it "置き換え先の dev がリンクなら、リンクの先を書き換えず、何も置かずに非 0 で止まる"
new_home
mkdir -p "$H/.local/bin" "$H/elsewhere"
cp "$DEV_SH" "$H/elsewhere/dev.sh"
ln -s "$H/elsewhere/dev.sh" "$(BIN)"
run_install "$REL2"
if [[ $RC -ne 0 && -L "$(BIN)" && ! -e "$(UNIT)" ]] && cmp -s "$DEV_SH" "$H/elsewhere/dev.sh"; then pass; else fail "終了コード $RC"; fi

it "置き換え先の dev が git で追跡されているファイルなら（リポジトリのチェックアウトの dev.sh）、何も変えずに非 0 で止まる"
new_home
mkdir -p "$H/.local/bin"
cp "$DEV_SH" "$(BIN)"
git -C "$H" init -q
git -C "$H" add .local/bin/dev
run_install "$REL2"
if [[ $RC -ne 0 && ! -e "$(UNIT)" ]] && cmp -s "$DEV_SH" "$(BIN)" && grep -q 'git で追跡されているファイル' "$ERR"; then pass; else fail "終了コード $RC: $(tail -3 "$ERR")"; fi

it "ホームが git の作業ツリー（~/.git）でも、追跡されていなければ、初回も再実行（更新）も通る"
new_home
git -C "$H" init -q
run_install "$REL1"
rc1=$RC
ok1=0
cmp -s "$REL1/dev.sh" "$(BIN)" && ok1=1
run_install "$REL2" --version v0.2.0
if [[ $rc1 -eq 0 && $ok1 -eq 1 && $RC -eq 0 ]] && cmp -s "$REL2/dev.sh" "$(BIN)" && cmp -s "$REL2/dev-up@.service" "$(UNIT)"; then pass; else fail "初回 rc=$rc1、再実行 rc=$RC: $(tail -3 "$ERR")"; fi

it "git が無い機械では、追跡されていないとみなして更新できる"
new_home
run_install "$REL1"
# git を隠した PATH（偽の curl・systemctl と、install.sh が使う最小限の道具だけ）で再実行する。
NOGIT="$WORK/nogit"
rm -rf "$NOGIT"
mkdir -p "$NOGIT"
for t in curl systemctl; do ln -s "$FAKEBIN/$t" "$NOGIT/$t"; done
for t in bash jq sed awk cat cp mv rm mkdir mktemp chmod cmp dirname grep sha256sum shasum tr head; do
  tp="$(command -v "$t" 2>/dev/null || true)"
  [[ -z "$tp" ]] || ln -s "$tp" "$NOGIT/$t"
done
LOG="$WORK/calls.log"; : > "$LOG"; OUT="$WORK/out.txt"; ERR="$WORK/err.txt"
RC=0
env -u XDG_CONFIG_HOME HOME="$H" PATH="$NOGIT" FAKE_LOG="$LOG" FAKE_CURL_DIR="$REL2" "$(command -v bash)" "$INSTALL" --version v0.2.0 > "$OUT" 2> "$ERR" < /dev/null || RC=$?
if [[ $RC -eq 0 ]] && cmp -s "$REL2/dev.sh" "$(BIN)"; then pass; else fail "終了コード $RC: $(tail -3 "$ERR")"; fi

it "置き換え先の dev がディレクトリなら、何も置かずに非 0 で止まる"
new_home
mkdir -p "$(BIN)"
run_install "$REL1"
if [[ $RC -ne 0 && "$(files_in_home)" == "0" && ! -s "$LOG" ]]; then pass; else fail "終了コード $RC、置かれたファイル: $(find "$H" -type f | tr '\n' ' ')"; fi

it "置き換え先のユニットがディレクトリなら、ディレクトリの中へ置かず、何も置かずに非 0 で止まる"
new_home
mkdir -p "$(UNIT)"
run_install "$REL1"
if [[ $RC -ne 0 && "$(files_in_home)" == "0" && ! -e "$(BIN)" ]] && ! grep -q '置きました' "$OUT"; then pass; else fail "終了コード $RC、置かれたファイル: $(find "$H" -type f | tr '\n' ' ')"; fi

it "置き換え先のユニットがリンクなら、何も置かずに非 0 で止まる"
new_home
mkdir -p "$H/.config/systemd/user" "$H/elsewhere"
printf 'x' > "$H/elsewhere/unit"
ln -s "$H/elsewhere/unit" "$(UNIT)"
run_install "$REL1"
if [[ $RC -ne 0 && ! -e "$(BIN)" && "$(cat "$H/elsewhere/unit")" == "x" ]]; then pass; else fail "終了コード $RC"; fi

# projects が通常のファイルでないとき（dev は -f で読むので、そのまま成功させると dev が止まる）。
it "projects がディレクトリなら、何も置かずに非 0 で止まる"
new_home
mkdir -p "$(PROJ)"
run_install "$REL1"
if [[ $RC -ne 0 && "$(files_in_home)" == "0" && ! -e "$(BIN)" && ! -e "$(UNIT)" ]] && grep -q '通常のファイルではありません' "$ERR"; then pass; else fail "終了コード $RC、置かれたファイル: $(find "$H" -type f | tr '\n' ' ')"; fi

it "projects がリンク切れなら、何も置かずに非 0 で止まる"
new_home
mkdir -p "$H/.config/dev"
ln -s "$H/nowhere" "$(PROJ)"
run_install "$REL1"
if [[ $RC -ne 0 && "$(files_in_home)" == "0" && ! -e "$(BIN)" ]]; then pass; else fail "終了コード $RC"; fi

it "projects が通常のファイルへのリンクなら、あるものとして触らずに入る"
new_home
mkdir -p "$H/.config/dev" "$H/elsewhere"
printf 'alpha /home/me/alpha\n' > "$H/elsewhere/projects"
ln -s "$H/elsewhere/projects" "$(PROJ)"
run_install "$REL1"
if [[ $RC -eq 0 && -L "$(PROJ)" && "$(cat "$H/elsewhere/projects")" == "alpha /home/me/alpha" && -f "$(BIN)" ]]; then pass; else fail "終了コード $RC: $(tail -3 "$ERR")"; fi

# 内容が同じでも、権限が違えば直す。
it "dev が同じ内容でも実行権限が無ければ、権限を直す（権限を直しました）"
new_home
run_install "$REL1"
chmod 0644 "$(BIN)"
run_install "$REL1"
if [[ $RC -eq 0 && -x "$(BIN)" ]] && cmp -s "$REL1/dev.sh" "$(BIN)" && grep -q '権限を直しました' "$OUT"; then pass; else fail "終了コード $RC: $(cat "$OUT")"; fi

it "ユニットが同じ内容でも権限が違えば、置くときと同じ 0644 に揃える"
chmod 0600 "$(UNIT)"
run_install "$REL1"
if [[ $RC -eq 0 && -n "$(find "$(UNIT)" -maxdepth 0 -perm 0644)" ]] && grep -q '権限を直しました' "$OUT"; then pass; else fail "終了コード $RC: $(cat "$OUT")"; fi

it "権限も内容も同じなら、権限を直したとは言わない"
run_install "$REL1"
if [[ $RC -eq 0 ]] && ! grep -q '権限を直しました' "$OUT"; then pass; else fail "出ている: $(cat "$OUT")"; fi

it "--dry-run は、権限だけが違う置き先を計画に出し、直さない"
chmod 0644 "$(BIN)"
run_install "$REL1" --dry-run
if [[ $RC -eq 0 && ! -x "$(BIN)" ]] && grep -q '権限が違うので、権限を直す' "$OUT"; then pass; else fail "終了コード $RC: $(cat "$OUT")"; fi

# 何かを置く前に、すべての置き場所を検査する。
if [[ "$(id -u)" != "0" ]]; then
  it "projects の親に書き込めなければ、dev もユニットも置かず、daemon-reload も呼ばずに非 0 で止まる"
  new_home
  mkdir -p "$H/.config/dev"
  chmod 0555 "$H/.config/dev"
  run_install "$REL1"
  chmod 0755 "$H/.config/dev"
  if [[ $RC -ne 0 && "$(files_in_home)" == "0" ]] && ! grep -q 'daemon-reload' "$LOG" && grep -q '書き込めません' "$ERR"; then pass; else fail "終了コード $RC、置かれたファイル: $(find "$H" -type f | tr '\n' ' ')"; fi

  it "dev の親に書き込めなければ、ユニットも projects も置かずに非 0 で止まる"
  new_home
  mkdir -p "$H/.local/bin"
  chmod 0555 "$H/.local/bin"
  run_install "$REL1"
  chmod 0755 "$H/.local/bin"
  if [[ $RC -ne 0 && "$(files_in_home)" == "0" ]] && ! grep -q 'daemon-reload' "$LOG"; then pass; else fail "終了コード $RC、置かれたファイル: $(find "$H" -type f | tr '\n' ' ')"; fi
fi

# 置く段（mv）で失敗したとき: 置いたものと失敗した箇所を示して非 0 で終わり、一時ファイルを残さず、daemon-reload を呼ばない。
REAL_MV="$(command -v mv)"
MVBIN="$WORK/mvbin"
mkdir -p "$MVBIN"
cat > "$MVBIN/mv" <<STUB
#!/usr/bin/env bash
last="\${!#}"
case "\$last" in *dev-up@.service) echo "mv: 失敗させる: \$last" >&2; exit 1 ;; esac
exec "$REAL_MV" "\$@"
STUB
chmod +x "$MVBIN/mv"

it "置く段で途中の mv が失敗したら、置いたものと失敗した箇所を示して非 0 で終わり、一時ファイルも daemon-reload も残さない"
new_home
PATH="$MVBIN:$PATH" run_install "$REL1"
if [[ $RC -ne 0 && -f "$(BIN)" && ! -e "$(UNIT)" && ! -e "$(PROJ)" && -z "$(find "$H" -name '.install.*')" ]] \
   && ! grep -q 'daemon-reload' "$LOG" \
   && grep -q "ここまでに置いたもの: $(BIN)" "$ERR" && grep -q "置けなかったもの: $(UNIT)" "$ERR"; then
  pass
else
  fail "終了コード $RC、置かれたファイル: $(find "$H" -type f | tr '\n' ' ')、エラー: $(cat "$ERR")"
fi

# ── 4. --dry-run ──────────────────────────────────────────────────────────────

it "--dry-run は何も書かず（HOME にファイルが増えない）、systemctl も呼ばず、計画を出して 0 で終わる"
new_home
run_install "$REL1" --dry-run
if [[ $RC -eq 0 && "$(files_in_home)" == "0" && -z "$(find "$H" -mindepth 1 | head -1)" ]] && ! grep -q '^systemctl' "$LOG" \
   && grep -q '計画' "$OUT" && grep -q '新規に置く' "$OUT" && grep -q '何も置いていません' "$OUT"; then
  pass
else
  fail "終了コード $RC、HOME の中身: $(find "$H" -mindepth 1 | tr '\n' ' ')"
fi

it "--dry-run でも、ハッシュの食い違いは非 0 で報告する"
new_home
bad="$(tampered "dry" dev.sh "改ざん")"
run_install "$bad" --dry-run
if [[ $RC -ne 0 && "$(files_in_home)" == "0" ]]; then pass; else fail "終了コード $RC"; fi

it "--dry-run は、すでに入っている環境でも何も変えない（更新の計画だけを出す）"
new_home
run_install "$REL1"
before="$(cat "$(BIN)" "$(UNIT)" "$(PROJ)" | cksum)"
run_install "$REL2" --version v0.2.0 --dry-run
after="$(cat "$(BIN)" "$(UNIT)" "$(PROJ)" | cksum)"
if [[ $RC -eq 0 && "$before" == "$after" ]] && grep -q '新しい版へ置き換える' "$OUT" \
   && grep -q '実行すると dev かユニットのファイルを更新します' "$OUT" && ! grep -q 'dev restart' "$OUT"; then pass; else fail "終了コード $RC: $(cat "$OUT")"; fi

# ── 5. 使い方の誤り ───────────────────────────────────────────────────────────

for args in "--version" "--version latest" "--version v1.0.0/../x" "bogus" "--dry-run extra"; do
  it "使い方の誤りは 2 で止まり、何も置かない（$args）"
  new_home
  # shellcheck disable=SC2086
  run_install "$REL1" $args
  if [[ $RC -eq 2 && "$(files_in_home)" == "0" && ! -s "$LOG" ]]; then pass; else fail "終了コード $RC"; fi
done

it "--help は 0 で説明を出し、何も置かない"
new_home
run_install "$REL1" --help
if [[ $RC -eq 0 && "$(files_in_home)" == "0" ]] && grep -q '^install.sh — ' "$OUT"; then pass; else fail "終了コード $RC"; fi

# ── 6. dev.sh と写している判定の一致 ──────────────────────────────────────────

# install.sh は dev.sh が無い状態で動くので、判定を dev.sh から写している。片方だけを直すと食い違うため、
# 写しの一覧をここに 1 か所で持ち、その全部を dev.sh の本文と機械で突き合わせる。
# さらに、install.sh の「ここから」〜「写しここまで」の間にあるものがこの一覧と一致することも確かめる
# （写しを足したのに一覧へ足し忘れる、一覧にないものが混ざる、を落とす）。
COPIED_FUNCS="is_devhost_dev_sh sha256_of is_git_tracked dev_target_refusal"
COPIED_VARS="SELF_HEADER_PREFIX SEMVER_RE"

func_body() { # $1 = ファイル, $2 = 関数名
  awk -v n="$2" '$0 == n "() {" { f = 1 } f { print } f && $0 == "}" { exit }' "$1"
}
for fn in $COPIED_FUNCS; do
  it "install.sh の $fn は、dev.sh のものと同じ本文である"
  a="$(func_body "$INSTALL" "$fn")"
  b="$(func_body "$DEV_SH" "$fn")"
  if [[ -n "$a" && "$a" == "$b" ]]; then pass; else fail "本文が違う、または見つからない（install.sh ${#a} 字 / dev.sh ${#b} 字）"; fi
done
for v in $COPIED_VARS; do
  it "install.sh の $v は、dev.sh のものと同じである"
  a="$(grep -m1 "^$v=" "$INSTALL" || true)"
  b="$(grep -m1 "^$v=" "$DEV_SH" || true)"
  if [[ -n "$a" && "$a" == "$b" ]]; then pass; else fail "違う: [$a] / [$b]"; fi
done

it "install.sh の写しの区間にある関数と代入が、写しの一覧と過不足なく一致する"
region="$(awk '/^# ── ここから ──/ { f = 1 } /^# ── 写しここまで/ { f = 0 } f' "$INSTALL")"
found="$( { printf '%s\n' "$region" | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)() {$/\1/p'; printf '%s\n' "$region" | sed -n 's/^\([A-Z][A-Z0-9_]*\)=.*/\1/p'; } | sort -u)"
listed="$(printf '%s\n' $COPIED_FUNCS $COPIED_VARS | sort -u)"
assert_same_set "$found" "$listed" "install.sh の写しの区間" "写しの一覧"

it "dev.sh の self-update と install.sh が、置き換え先の確認（dev_target_refusal）と版の形（SEMVER_RE）を使っている"
if grep -q 'dev_target_refusal "\$self"' "$DEV_SH" && grep -q 'dev_target_refusal "\$bin_path"' "$INSTALL" \
   && [[ "$(grep -c '=~ \$SEMVER_RE' "$DEV_SH")" == "2" && "$(grep -c '=~ \$SEMVER_RE' "$INSTALL")" == "2" ]]; then
  pass
else
  fail "どちらかが、写しを使わず独自の条件を持っている"
fi

# ── 7. 公開物に入る .sh の実行権限 ────────────────────────────────────────────

# 編集の道具（sed -i など）が、一時ファイルを作り直して実行権限を落とすことがある。公開物に入るので、
# git に記録されたモードが 100755 であることを確かめる。
for f in packages/devcontainer-host/install.sh packages/devcontainer-host/dev.sh packages/devcontainer-host/selftest.sh scripts/release-packages.sh; do
  it "$f は git 上で実行権限（100755）を持つ"
  mode="$(git -C "$REPO_ROOT" ls-files -s -- "$f" | awk '{print $1}')"
  if [[ "$mode" == "100755" ]]; then pass; else fail "モード: ${mode:-追跡されていない}"; fi
done

it "install.sh は実行権限を持ち、構文が通る"
if [[ -x "$INSTALL" ]] && bash -n "$INSTALL"; then pass; else fail "実行権限が無い、または構文の誤り"; fi

exit_with_result
