#!/usr/bin/env bash
# test-update-check.sh — 新しい版の確認と追従（scripts/update-check.sh。#625）を検証する。
#
# 生成物の scripts/update-check.sh を、偽の curl（URL を固定の応答ファイルへ対応させる）と
# 偽の bootstrap.sh（引数を記録するだけ）で動かす。ネットワークには出ない。
# 確かめるもの: 新しい版あり / 無し / API の失敗 / 端末なし / 1 日 1 回 / N の記録 /
# 止め方（--no-update-check・UPDATE_CHECK=off）/ ORIGIN 無し / 照合してからの --upgrade /
# 既定ブランチなら作業用のブランチを切る。

set -uo pipefail
if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-update-check-test.XXXXXX")"
  export TEST_TMP_ROOT
  trap 'rm -rf "$TEST_TMP_ROOT"' EXIT
fi
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-update-check"

DOCTOR="$(dirname "$BOOTSTRAP")/doctor.sh"
BASH_BIN="$(command -v bash)"
TODAY="2026-10-16"
NEXTDAY="2026-10-17"

# ── 偽の curl ────────────────────────────────────────────────────────────────
FIX="$TEST_TMP_ROOT/fixture"; mkdir -p "$FIX"
STUBBIN="$TEST_TMP_ROOT/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/curl" <<'STUB'
#!/usr/bin/env bash
# URL を呼び出しの記録へ足し、同名の応答ファイルを -o の先へ写す。無ければ失敗（22）。
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -H|--proto|--proto-redir|--connect-timeout|--max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$url" >> "$FAKE_CURL_DIR/calls"
[[ -z "${FAKE_CURL_FAIL:-}" ]] || exit "${FAKE_CURL_RC:-22}"
f="$FAKE_CURL_DIR/$(printf '%s' "$url" | tr -c 'A-Za-z0-9' _)"
[[ -f "$f" ]] || exit 22
cp "$f" "$out"
STUB
chmod +x "$STUBBIN/curl"
export FAKE_CURL_DIR="$FIX"

fixture_path() { printf '%s/%s' "$FIX" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' _)"; }
DCB_API="https://api.github.com/repos/ojos/devcontainer-bootstrap/releases"
PB_TAGS="https://api.github.com/repos/ojos/ai-playbook/tags?per_page=100"

# set_latest <API> <tag>: releases/latest の応答を置く。
set_latest() {
  printf '{\n  "tag_name": "%s",\n  "draft": false,\n  "prerelease": false\n}\n' "$2" > "$(fixture_path "$1/latest")"
}
# set_tags <URL> <tag>...: tags の応答（ai-playbook は Release を作らないため、タグの一覧から取る）を置く。
# 並びは与えた順（GitHub は新しい順を返すが、最大は並びによらず取る）。
set_tags() {
  local url="$1" t sep="" body="["; shift
  for t in "$@"; do
    body="$body$sep{\"name\":\"$t\",\"zipball_url\":\"https://x/zip/$t\",\"commit\":{\"sha\":\"0000\",\"url\":\"https://x/c\"},\"node_id\":\"n\"}"
    sep=","
  done
  printf '%s]\n' "$body" > "$(fixture_path "$url")"
}
# set_changelog <owner/repo> <最新のタグ> <版:移行の節あり(1)/なし(0)>...: 配布先の CHANGELOG.md を置く。
set_changelog() {
  local slug="$1" latest="$2" spec tag mig; shift 2
  {
    echo "# Release Notes"
    echo
    for spec in "$@"; do
      tag="${spec%%:*}"; mig="${spec##*:}"
      printf '## %s\n\n### Summary\n- x\n\n' "$tag"
      if [[ "$mig" == 1 ]]; then printf '### 移行\n- 追従する\n\n'; fi
    done
  } > "$(fixture_path "https://raw.githubusercontent.com/$slug/$latest/CHANGELOG.md")"
}
reset_fixture() { rm -f "$FIX"/*; }
calls() { if [[ -f "$FIX/calls" ]]; then wc -l < "$FIX/calls" | tr -d ' '; else echo 0; fi; }

# ── 生成物 ───────────────────────────────────────────────────────────────────
OUT="$(new_workdir)/p"
run_bootstrap "$OUT" >/dev/null 2>&1
UC="$OUT/scripts/update-check.sh"

it "scripts/update-check.sh が実行権限つきで生成される"
if [[ -x "$UC" ]]; then pass; else fail "無い、または実行できない"; fi

it "既定では ORIGIN に input:update-check の行を書かない"
if ! grep -q '^input:update-check=' "$OUT/.devcontainer/ORIGIN"; then pass; else fail "行がある"; fi

it "usage に --no-update-check / --update-check が載る"
usage="$(bash "$BOOTSTRAP" --help 2>&1)"
if [[ "$usage" == *--no-update-check* && "$usage" == *--update-check* ]]; then pass; else fail "載っていない"; fi

it ".env.example に UPDATE_CHECK の説明がある"
if grep -q '^# UPDATE_CHECK=off' "$OUT/.env.example" && ! grep -q '^UPDATE_CHECK=' "$OUT/.env.example"; then pass; else fail "無い、または有効な行になっている"; fi

it "on-attach.sh が update-check.sh の notify と rc への注入を持つ"
if grep -q 'update-check.sh' "$OUT/scripts/on-attach.sh" && grep -q 'dcb update check' "$OUT/scripts/on-attach.sh" \
  && grep -q 'notify' "$OUT/scripts/on-attach.sh"; then pass; else fail "配線が無い"; fi

# 版は ORIGIN の version= から読む。
ORIGIN_VER="$(sed -n 's/^version=//p' "$OUT/.devcontainer/ORIGIN")"

# run_uc <cache> <サブコマンド> [env...]: 偽の curl を先頭に置いて実行する。標準入力は /dev/null。
run_uc() {
  local cache="$1" sub="$2"; shift 2
  env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$cache" UPDATE_CHECK_TODAY="${UPDATE_CHECK_TODAY:-$TODAY}" \
    FAKE_CURL_DIR="$FIX" "$@" "$BASH_BIN" "$UC" "$sub" </dev/null 2>&1
}

# ── 新しい版あり / 無し ──────────────────────────────────────────────────────
reset_fixture
set_latest "$DCB_API" "v0.99.0"
C1="$TEST_TMP_ROOT/c1"
it "新しい版があれば、notify が通知を 1 行だけ出す（版を含む）"
o="$(run_uc "$C1" notify)"
if [[ "$(printf '%s\n' "$o" | wc -l | tr -d ' ')" == 1 && "$o" == *"$ORIGIN_VER -> v0.99.0"* ]]; then pass; else fail "出力: $o"; fi

it "同じ日の 2 回目は問い合わせず（1 日 1 回）、通知はキャッシュから出る"
n0="$(calls)"
o="$(run_uc "$C1" notify)"
if [[ "$(calls)" == "$n0" && "$o" == *v0.99.0* ]]; then pass; else fail "calls $n0 -> $(calls) 出力: $o"; fi

it "翌日は問い合わせ直す"
n0="$(calls)"
o="$(run_uc "$C1" notify UPDATE_CHECK_TODAY="$NEXTDAY")"
if [[ "$(calls)" -gt "$n0" ]]; then pass; else fail "問い合わせていない"; fi

it "最新が今と同じなら、何も出さない"
reset_fixture; set_latest "$DCB_API" "$ORIGIN_VER"
o="$(run_uc "$TEST_TMP_ROOT/c2" notify)"
if [[ -z "$o" ]]; then pass; else fail "出力: $o"; fi

it "最新が今より古ければ、何も出さない"
reset_fixture; set_latest "$DCB_API" "v0.0.1"
o="$(run_uc "$TEST_TMP_ROOT/c2b" notify)"
if [[ -z "$o" ]]; then pass; else fail "出力: $o"; fi

it "プレリリースを指す tag_name（vX.Y.Z でない）は新しい版として扱わない"
reset_fixture; set_latest "$DCB_API" "v9.9.9-rc1"
o="$(run_uc "$TEST_TMP_ROOT/c2c" notify)"
if [[ -z "$o" ]]; then pass; else fail "出力: $o"; fi

# ── API の失敗 ───────────────────────────────────────────────────────────────
it "API が失敗しても、何も出さず 0 で終わる（起動を止めない）"
reset_fixture
o="$(run_uc "$TEST_TMP_ROOT/c3" notify FAKE_CURL_FAIL=1)"; rc=$?
if [[ -z "$o" && "$rc" == 0 ]]; then pass; else fail "rc=$rc 出力: $o"; fi

it "失敗した日は、もう一度問い合わせない（1 日 1 回）"
n0="$(calls)"
run_uc "$TEST_TMP_ROOT/c3" notify FAKE_CURL_FAIL=1 >/dev/null
if [[ "$(calls)" == "$n0" ]]; then pass; else fail "再度問い合わせた"; fi

# ── 端末なし ─────────────────────────────────────────────────────────────────
reset_fixture; set_latest "$DCB_API" "v0.99.0"
C4="$TEST_TMP_ROOT/c4"
run_uc "$C4" notify >/dev/null
it "端末が付いていなければ、prompt は何も出さず何も聞かない"
o="$(run_uc "$C4" prompt)"; rc=$?
if [[ -z "$o" && "$rc" == 0 ]]; then pass; else fail "rc=$rc 出力: $o"; fi

# ── N の記録 ─────────────────────────────────────────────────────────────────
# 端末の代わりに UPDATE_CHECK_ASSUME_TTY=1 で、標準入力から答えを読ませる。
ask() { # <cache> <答え> [env...]
  local cache="$1" ans="$2"; shift 2
  printf '%s\n' "$ans" | env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$cache" UPDATE_CHECK_TODAY="$TODAY" \
    UPDATE_CHECK_ASSUME_TTY=1 FAKE_CURL_DIR="$FIX" "$@" "$BASH_BIN" "$UC" prompt 2>&1
}
it "prompt は「追従しますか？ [y/N]」と聞き、今の版と最新の版を示す"
o="$(ask "$C4" n)"
if [[ "$o" == *"追従しますか？ [y/N]"* && "$o" == *"$ORIGIN_VER -> v0.99.0"* ]]; then pass; else fail "出力: $o"; fi

it "N と答えた版は、その版のあいだ聞かない（notify の通知も出ない）"
o1="$(ask "$C4" n)"; o2="$(run_uc "$C4" notify)"
if [[ -z "$o1" && -z "$o2" ]]; then pass; else fail "聞いた/通知した: [$o1] [$o2]"; fi

it "さらに新しい版が出たら、また聞く"
reset_fixture; set_latest "$DCB_API" "v0.100.0"
run_uc "$C4" notify UPDATE_CHECK_TODAY="$NEXTDAY" >/dev/null
o="$(ask "$C4" n UPDATE_CHECK_TODAY="$NEXTDAY")"
if [[ "$o" == *"追従しますか？"* && "$o" == *v0.100.0* ]]; then pass; else fail "出力: $o"; fi

it "答えが空（Enter）でも N として扱い、追従しない"
C4B="$TEST_TMP_ROOT/c4b"; run_uc "$C4B" notify >/dev/null
o="$(ask "$C4B" "")"
if [[ "$o" != *"次の手順"* && -f "$C4B/declined-dcb" ]]; then pass; else fail "出力: $o"; fi

# ── 止め方 ───────────────────────────────────────────────────────────────────
reset_fixture; set_latest "$DCB_API" "v0.99.0"
it "UPDATE_CHECK=off なら、問い合わせず何も出さない"
n0="$(calls)"
o="$(run_uc "$TEST_TMP_ROOT/c5" notify UPDATE_CHECK=off)"
if [[ -z "$o" && "$(calls)" == "$n0" ]]; then pass; else fail "出力: $o"; fi

it "プロジェクトの .env の UPDATE_CHECK=off も効く"
printf 'UPDATE_CHECK=off\n' > "$OUT/.env"
n0="$(calls)"
o="$(run_uc "$TEST_TMP_ROOT/c5b" notify)"
rm -f "$OUT/.env"
if [[ -z "$o" && "$(calls)" == "$n0" ]]; then pass; else fail "出力: $o"; fi

it "環境の UPDATE_CHECK=off は、.env の空の UPDATE_CHECK= で打ち消されない"
printf 'UPDATE_CHECK=\n' > "$OUT/.env"
n0="$(calls)"
o="$(run_uc "$TEST_TMP_ROOT/c5c" notify UPDATE_CHECK=off)"
rm -f "$OUT/.env"
if [[ -z "$o" && "$(calls)" == "$n0" ]]; then pass; else fail "出力: $o"; fi

OUT_OFF="$(new_workdir)/p"
run_bootstrap "$OUT_OFF" --no-update-check >/dev/null 2>&1
it "--no-update-check は ORIGIN に input:update-check=off を記録する"
if grep -qx 'input:update-check=off' "$OUT_OFF/.devcontainer/ORIGIN"; then pass; else fail "記録が無い"; fi

it "--no-update-check の構成では notify も prompt も、問い合わせず何も出さない"
n0="$(calls)"
o1="$(env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/c6" UPDATE_CHECK_TODAY="$TODAY" "$BASH_BIN" "$OUT_OFF/scripts/update-check.sh" notify </dev/null 2>&1)"
o2="$(printf 'y\n' | env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/c6" UPDATE_CHECK_TODAY="$TODAY" UPDATE_CHECK_ASSUME_TTY=1 "$BASH_BIN" "$OUT_OFF/scripts/update-check.sh" prompt 2>&1)"
if [[ -z "$o1" && -z "$o2" && "$(calls)" == "$n0" ]]; then pass; else fail "[$o1] [$o2]"; fi

it "--upgrade は off の記録を引き継ぐ"
if bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_OFF" >/dev/null 2>&1 \
  && grep -qx 'input:update-check=off' "$OUT_OFF/.devcontainer/ORIGIN"; then pass; else fail "引き継がれていない"; fi

it "doctor は input:update-check=off を不正としない"
d_out="$(bash "$DOCTOR" --target-dir "$OUT_OFF" 2>&1)"
if [[ "$d_out" != *"input:update-check"* && "$d_out" != *"認識できない入力の行"* ]]; then pass; else fail "$d_out"; fi

it "doctor は off 以外の値を検出する"
OUT_DB="$(new_workdir)/p"
run_bootstrap "$OUT_DB" --no-update-check >/dev/null 2>&1
sed 's/^input:update-check=off$/input:update-check=maybe/' "$OUT_DB/.devcontainer/ORIGIN" > "$OUT_DB/.devcontainer/ORIGIN.new"
mv "$OUT_DB/.devcontainer/ORIGIN.new" "$OUT_DB/.devcontainer/ORIGIN"
d_out="$(bash "$DOCTOR" --target-dir "$OUT_DB" 2>&1)"
if [[ "$d_out" == *"input:update-check が off ではない"* ]]; then pass; else fail "$d_out"; fi

it "--upgrade --update-check で off の記録を外せる"
if bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_OFF" --update-check >/dev/null 2>&1 \
  && ! grep -q '^input:update-check=' "$OUT_OFF/.devcontainer/ORIGIN"; then pass; else fail "外れていない"; fi

it "--no-update-check と --update-check の同時指定は、何も書かずに止まる"
OUT_BOTH="$(new_workdir)/p"
if ! run_bootstrap "$OUT_BOTH" --no-update-check --update-check >/dev/null 2>&1 && [[ ! -e "$OUT_BOTH/.devcontainer/ORIGIN" ]]; then pass; else fail "止まっていない"; fi

it "ORIGIN の値が off 以外なら、ORIGIN の破損として --upgrade が止まる"
OUT_BAD="$(new_workdir)/p"
run_bootstrap "$OUT_BAD" --no-update-check >/dev/null 2>&1
sed 's/^input:update-check=off$/input:update-check=maybe/' "$OUT_BAD/.devcontainer/ORIGIN" > "$OUT_BAD/.devcontainer/ORIGIN.new"
mv "$OUT_BAD/.devcontainer/ORIGIN.new" "$OUT_BAD/.devcontainer/ORIGIN"
if ! bash "$BOOTSTRAP" --upgrade --output-dir "$OUT_BAD" >/dev/null 2>&1; then pass; else fail "止まっていない"; fi

# ── ORIGIN 無し / リリースでない版 ───────────────────────────────────────────
it "ORIGIN が無ければ、何もしない（問い合わせない）"
NOORG="$(new_workdir)/p"; mkdir -p "$NOORG/scripts"; cp "$UC" "$NOORG/scripts/update-check.sh"
n0="$(calls)"
o="$(env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/c7" UPDATE_CHECK_TODAY="$TODAY" "$BASH_BIN" "$NOORG/scripts/update-check.sh" notify </dev/null 2>&1)"
if [[ -z "$o" && "$(calls)" == "$n0" ]]; then pass; else fail "出力: $o"; fi

it "ORIGIN の version= が vX.Y.Z でなければ（リリースから取得した版でなければ）、何もしない"
NOREL="$(new_workdir)/p"; mkdir -p "$NOREL/scripts" "$NOREL/.devcontainer"; cp "$UC" "$NOREL/scripts/update-check.sh"
printf 'version=main\ninputs-format=1\n' > "$NOREL/.devcontainer/ORIGIN"
n0="$(calls)"
o="$(env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/c8" UPDATE_CHECK_TODAY="$TODAY" "$BASH_BIN" "$NOREL/scripts/update-check.sh" notify </dev/null 2>&1)"
if [[ -z "$o" && "$(calls)" == "$n0" ]]; then pass; else fail "出力: $o"; fi

# ── 移行の節の判定 ───────────────────────────────────────────────────────────
reset_fixture; set_latest "$DCB_API" "v0.99.0"
set_changelog "ojos/devcontainer-bootstrap" "v0.99.0" "v0.99.0:1" "v0.98.0:1" "v0.97.0:0" "v0.0.1:1"
it "CHANGELOG.md の「### 移行」を持つ版を 2 つ以上飛び越えるときは、注意を目立たせる（古い版・節の無い版は数えない）"
C9="$TEST_TMP_ROOT/c9"; run_uc "$C9" notify >/dev/null
o="$(ask "$C9" n)"
if [[ "$o" == *"[注意]"* && "$o" == *v0.99.0* && "$o" == *v0.98.0* && "$o" != *v0.97.0* && "$o" != *"v0.0.1"* ]]; then pass; else fail "出力: $o"; fi

it "CHANGELOG.md を取得できなければ、リリースノートを読む案内に留める"
reset_fixture; set_latest "$DCB_API" "v0.99.0"
C10="$TEST_TMP_ROOT/c10"; run_uc "$C10" notify >/dev/null
o="$(ask "$C10" n)"
if [[ "$o" != *"[注意]"* && "$o" == *リリースノート* ]]; then pass; else fail "出力: $o"; fi

# ── 追従（y） ────────────────────────────────────────────────────────────────
sha_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

# 偽の bootstrap.sh と、その SHA256SUMS を応答に置く。引数を記録して、出力先に印のファイルを作る。
FAKE_BOOT="$TEST_TMP_ROOT/fake-bootstrap.sh"
cat > "$FAKE_BOOT" <<'FB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_BOOT_LOG"
out=""
while [[ $# -gt 0 ]]; do case "$1" in --output-dir) out="$2"; shift 2 ;; *) shift ;; esac; done
[[ -n "${FAKE_BOOT_NOWRITE:-}" ]] || echo changed > "$out/upgraded-marker"
exit "${FAKE_BOOT_RC:-0}"
FB
DL="https://github.com/ojos/devcontainer-bootstrap/releases/download/v0.99.0"
put_release_assets() { # <hash を正しくするか: ok|bad>
  cp "$FAKE_BOOT" "$(fixture_path "$DL/bootstrap.sh")"
  if [[ "$1" == ok ]]; then h="$(sha_of "$FAKE_BOOT")"; else h="0000000000000000000000000000000000000000000000000000000000000000"; fi
  printf '%s  bootstrap.sh\n%s  other.txt\n' "$h" "$h" > "$(fixture_path "$DL/SHA256SUMS")"
}

# git 管理下の生成物を作る（既定ブランチ main の上）。
make_repo() { # <out> [生成の追加引数...]
  local o="$1"; shift
  run_bootstrap "$o" "$@" >/dev/null 2>&1
  git -C "$o" init -q -b main
  git -C "$o" add -A
  git -C "$o" -c user.name=t -c user.email=t@example.com commit -q -m init
}
BOOT_LOG="$TEST_TMP_ROOT/boot.log"
yes_run() { # <out> <cache> [env...]
  local o="$1" cache="$2"; shift 2
  : > "$BOOT_LOG"
  printf 'y\n' | env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$cache" UPDATE_CHECK_TODAY="$TODAY" UPDATE_CHECK_ASSUME_TTY=1 \
    FAKE_CURL_DIR="$FIX" FAKE_BOOT_LOG="$BOOT_LOG" "$@" "$BASH_BIN" "$o/scripts/update-check.sh" prompt 2>&1
}

reset_fixture; set_latest "$DCB_API" "v0.99.0"; put_release_assets ok
R1="$(new_workdir)/p"; make_repo "$R1"
env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/cy1" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$R1/scripts/update-check.sh" notify >/dev/null 2>&1
it "y: 照合に通った bootstrap.sh を、ORIGIN を引き継ぐ --upgrade で呼ぶ"
o="$(yes_run "$R1" "$TEST_TMP_ROOT/cy1")"
if [[ "$(cat "$BOOT_LOG")" == "--upgrade --output-dir $R1" ]]; then pass; else fail "引数: $(cat "$BOOT_LOG") 出力: $o"; fi

it "y: 既定ブランチ（main）の上なら、作業用のブランチを切ってから流す"
if [[ "$(git -C "$R1" symbolic-ref --short HEAD)" == "chore/update-dcb-v0.99.0" ]]; then pass; else fail "ブランチ: $(git -C "$R1" symbolic-ref --short HEAD)"; fi

it "y: 差分を残して止め、変わったファイルと次の手順を出し、コミットはしない"
n_commits="$(git -C "$R1" rev-list --count HEAD)"
if [[ "$o" == *upgraded-marker* && "$o" == *"次の手順"* && "$o" == *verify.sh* && "$n_commits" == 1 ]]; then pass; else fail "commits=$n_commits 出力: $o"; fi

it "y: 既定ブランチの上でなければ、ブランチを切らない"
R2="$(new_workdir)/p"; make_repo "$R2"; git -C "$R2" switch -q -c feature/x
env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/cy2" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$R2/scripts/update-check.sh" notify >/dev/null 2>&1
yes_run "$R2" "$TEST_TMP_ROOT/cy2" >/dev/null
if [[ "$(git -C "$R2" symbolic-ref --short HEAD)" == "feature/x" && -s "$BOOT_LOG" ]]; then pass; else fail "ブランチ: $(git -C "$R2" symbolic-ref --short HEAD)"; fi

it "y: ハッシュが SHA256SUMS と一致しなければ、実行せず、ブランチも切らない"
put_release_assets bad
R3="$(new_workdir)/p"; make_repo "$R3"
env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/cy3" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$R3/scripts/update-check.sh" notify >/dev/null 2>&1
o="$(yes_run "$R3" "$TEST_TMP_ROOT/cy3")"
if [[ ! -s "$BOOT_LOG" && "$(git -C "$R3" symbolic-ref --short HEAD)" == main && "$o" == *一致しません* ]]; then pass; else fail "引数: $(cat "$BOOT_LOG") 出力: $o"; fi

it "y: SHA256SUMS に bootstrap.sh の行が無ければ、実行しない"
put_release_assets ok
printf '%s  other.txt\n' "$(sha_of "$FAKE_BOOT")" > "$(fixture_path "$DL/SHA256SUMS")"
R4="$(new_workdir)/p"; make_repo "$R4"
env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/cy4" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$R4/scripts/update-check.sh" notify >/dev/null 2>&1
yes_run "$R4" "$TEST_TMP_ROOT/cy4" >/dev/null
if [[ ! -s "$BOOT_LOG" ]]; then pass; else fail "実行された"; fi

it "y: 未コミットの変更があれば、追従せずに止める"
put_release_assets ok
R5="$(new_workdir)/p"; make_repo "$R5"; echo dirty > "$R5/dirty.txt"
env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/cy5" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$R5/scripts/update-check.sh" notify >/dev/null 2>&1
o="$(yes_run "$R5" "$TEST_TMP_ROOT/cy5")"
if [[ ! -s "$BOOT_LOG" && "$o" == *未コミット* ]]; then pass; else fail "出力: $o"; fi

it "y: ai-playbook を tag で使っていて、新しい版があれば --playbook-version を渡す"
reset_fixture; set_latest "$DCB_API" "v0.99.0"; set_tags "$PB_TAGS" "v9.0.0"; put_release_assets ok
R6="$(new_workdir)/p"; make_repo "$R6"
# 規範を tag で使う構成の ORIGIN にする（取得はしない: 偽の bootstrap.sh は何も取りに行かない）。
sed 's/^input:playbook=none$/input:playbook=installed\ninput:playbook-source=tag\ninput:playbook-ref=v0.1.0/' "$R6/.devcontainer/ORIGIN" > "$R6/.devcontainer/ORIGIN.new"
mv "$R6/.devcontainer/ORIGIN.new" "$R6/.devcontainer/ORIGIN"
git -C "$R6" add -A; git -C "$R6" -c user.name=t -c user.email=t@example.com commit -q -m origin
env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/cy6" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$R6/scripts/update-check.sh" notify >/dev/null 2>&1
o="$(yes_run "$R6" "$TEST_TMP_ROOT/cy6")"
if [[ "$(cat "$BOOT_LOG")" == "--upgrade --output-dir $R6 --playbook-version v9.0.0" ]]; then pass; else fail "引数: $(cat "$BOOT_LOG") 出力: $o"; fi

it "規範の取得元が tag でなければ（adjacent / local）、ai-playbook は確認しない"
reset_fixture; set_latest "$DCB_API" "v0.99.0"; set_tags "$PB_TAGS" "v9.0.0"
R7="$(new_workdir)/p"; make_repo "$R7"
sed 's/^input:playbook=none$/input:playbook=installed\ninput:playbook-source=adjacent/' "$R7/.devcontainer/ORIGIN" > "$R7/.devcontainer/ORIGIN.new"
mv "$R7/.devcontainer/ORIGIN.new" "$R7/.devcontainer/ORIGIN"
: > "$FIX/calls"
env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/cy7" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$R7/scripts/update-check.sh" notify >/dev/null 2>&1
if ! grep -q 'ai-playbook' "$FIX/calls"; then pass; else fail "ai-playbook を問い合わせた"; fi

# 取得元・版の組み合わせ
put_assets_for() { # <tag>: その版の偽の bootstrap.sh と SHA256SUMS を置く
  local u="https://github.com/ojos/devcontainer-bootstrap/releases/download/$1" h
  cp "$FAKE_BOOT" "$(fixture_path "$u/bootstrap.sh")"
  h="$(sha_of "$FAKE_BOOT")"
  printf '%s  bootstrap.sh\n' "$h" > "$(fixture_path "$u/SHA256SUMS")"
}
# set_origin_playbook <out> <source> [ref]: ORIGIN を規範ありの記録にして、コミットする。
set_origin_playbook() {
  local o="$1" src="$2" ref="${3:-}" extra
  extra="input:playbook=installed\ninput:playbook-source=$src"
  [[ -z "$ref" ]] || extra="$extra\ninput:playbook-ref=$ref"
  sed "s|^input:playbook=none\$|$extra|" "$o/.devcontainer/ORIGIN" > "$o/.devcontainer/ORIGIN.new"
  mv "$o/.devcontainer/ORIGIN.new" "$o/.devcontainer/ORIGIN"
  git -C "$o" add -A; git -C "$o" -c user.name=t -c user.email=t@example.com commit -q -m origin
}
notify_in() { # <out> <cache>
  env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$2" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$1/scripts/update-check.sh" notify >/dev/null 2>&1
}

it "y: フォークの url で使う規範は、フォークのまま版だけ替えた url を --playbook-from で渡す"
reset_fixture; set_latest "$DCB_API" "v0.99.0"; set_tags "https://api.github.com/repos/fork/ai-playbook/tags?per_page=100" "v9.0.0"; put_assets_for v0.99.0
R9="$(new_workdir)/p"; make_repo "$R9"
set_origin_playbook "$R9" url "https://github.com/fork/ai-playbook/archive/refs/tags/v0.1.0.tar.gz"
notify_in "$R9" "$TEST_TMP_ROOT/cy9"
o="$(yes_run "$R9" "$TEST_TMP_ROOT/cy9")"
if [[ "$(cat "$BOOT_LOG")" == "--upgrade --output-dir $R9 --playbook-from https://github.com/fork/ai-playbook/archive/refs/tags/v9.0.0.tar.gz" ]]; then pass; else fail "引数: $(cat "$BOOT_LOG") 出力: $o"; fi

it "規範の取得元が adjacent なら、自動では追従せず案内に留め、ブランチも切らない（その版のあいだは聞かない）"
reset_fixture; set_latest "$DCB_API" "v0.99.0"; put_assets_for v0.99.0
R10="$(new_workdir)/p"; make_repo "$R10"
set_origin_playbook "$R10" adjacent
notify_in "$R10" "$TEST_TMP_ROOT/cy10"
o="$(yes_run "$R10" "$TEST_TMP_ROOT/cy10")"
o2="$(yes_run "$R10" "$TEST_TMP_ROOT/cy10")"
if [[ ! -s "$BOOT_LOG" && "$o" == *自動では追従できません* && -z "$o2" && "$(git -C "$R10" symbolic-ref --short HEAD)" == main ]]; then pass; else fail "出力: $o / $o2"; fi

it "規範の取得元が adjacent のとき、手で呼ぶ upgrade も実行せず、ブランチも切らない"
o="$(env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/cy10" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" FAKE_BOOT_LOG="$BOOT_LOG" "$BASH_BIN" "$R10/scripts/update-check.sh" upgrade </dev/null 2>&1)"; rc=$?
if [[ "$rc" != 0 && ! -s "$BOOT_LOG" && "$(git -C "$R10" symbolic-ref --short HEAD)" == main ]]; then pass; else fail "rc=$rc 出力: $o"; fi

it "手で呼ぶ upgrade は、最新の版を取得できなければ「すでに最新」と言わずに失敗で終える"
reset_fixture
RUF="$(new_workdir)/p"; make_repo "$RUF"
o="$(env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/cyuf" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" FAKE_CURL_FAIL=1 FAKE_BOOT_LOG="$BOOT_LOG" "$BASH_BIN" "$RUF/scripts/update-check.sh" upgrade </dev/null 2>&1)"; rc=$?
if [[ "$rc" != 0 && "$o" == *取得できなかった* && "$o" != *すでに最新* && ! -s "$BOOT_LOG" ]]; then pass; else fail "rc=$rc 出力: $o"; fi

it "--upgrade が途中で書いてから失敗したら、自動では戻さず、作業用のブランチに留まって戻し方を案内する"
reset_fixture; set_latest "$DCB_API" "v0.99.0"; put_assets_for v0.99.0
R11="$(new_workdir)/p"; make_repo "$R11"
notify_in "$R11" "$TEST_TMP_ROOT/cy11"
o="$(yes_run "$R11" "$TEST_TMP_ROOT/cy11" FAKE_BOOT_RC=1)"
# 偽の bootstrap.sh は失敗の前に upgraded-marker を書く。書かれたファイルは自動では消さず、作業用のブランチに留まる
# （既定ブランチの作業ツリーを汚さない。ほかの端末の編集を消しうる reset / clean はしない）。
if [[ "$(git -C "$R11" symbolic-ref --short HEAD)" == chore/update-dcb-v0.99.0 && -e "$R11/upgraded-marker" && "$o" == *失敗しました* && "$o" == *留まります* && "$o" == *"git restore ."* ]]; then pass; else fail "ブランチ: $(git -C "$R11" symbolic-ref --short HEAD) 出力: $o"; fi

it "--upgrade が何も書かずに失敗したら、切った作業用のブランチを消して元のブランチへ戻す"
reset_fixture; set_latest "$DCB_API" "v0.99.0"; put_assets_for v0.99.0
RNW="$(new_workdir)/p"; make_repo "$RNW"
notify_in "$RNW" "$TEST_TMP_ROOT/cynw"
o="$(yes_run "$RNW" "$TEST_TMP_ROOT/cynw" FAKE_BOOT_RC=1 FAKE_BOOT_NOWRITE=1)"
if [[ "$(git -C "$RNW" symbolic-ref --short HEAD)" == main && -z "$(git -C "$RNW" branch --list 'chore/*')" && "$o" == *失敗しました* ]]; then pass; else fail "ブランチ: $(git -C "$RNW" branch --list) 出力: $o"; fi

it "既定ブランチを判定できない（origin/HEAD が無く、main / master でもない）ときも、作業用のブランチを切ってから追従する"
reset_fixture; set_latest "$DCB_API" "v0.99.0"; put_assets_for v0.99.0
RDB="$(new_workdir)/p"; make_repo "$RDB"; git -C "$RDB" branch -q -m main develop
notify_in "$RDB" "$TEST_TMP_ROOT/cydb"
o="$(yes_run "$RDB" "$TEST_TMP_ROOT/cydb")"
if [[ "$(git -C "$RDB" symbolic-ref --short HEAD)" == chore/update-dcb-v0.99.0 ]]; then pass; else fail "ブランチ: $(git -C "$RDB" symbolic-ref --short HEAD) 出力: $o"; fi

it "今の DCB が最新より新しく ai-playbook だけ新しいとき、今の版の bootstrap.sh で追従する（DCB を下げない）"
reset_fixture; set_latest "$DCB_API" "v0.99.0"; set_tags "$PB_TAGS" "v9.0.0"; put_assets_for v0.99.0; put_assets_for v1.0.0
R12="$(new_workdir)/p"; make_repo "$R12"
sed 's/^version=.*$/version=v1.0.0/' "$R12/.devcontainer/ORIGIN" > "$R12/.devcontainer/ORIGIN.new"; mv "$R12/.devcontainer/ORIGIN.new" "$R12/.devcontainer/ORIGIN"
set_origin_playbook "$R12" tag v0.1.0
notify_in "$R12" "$TEST_TMP_ROOT/cy12"
o="$(yes_run "$R12" "$TEST_TMP_ROOT/cy12")"
if [[ "$(cat "$BOOT_LOG")" == "--upgrade --output-dir $R12 --playbook-version v9.0.0" ]] \
  && grep -q 'download/v1.0.0/bootstrap.sh' "$FIX/calls" && ! grep -q 'download/v0.99.0/bootstrap.sh' "$FIX/calls"; then pass; else fail "引数: $(cat "$BOOT_LOG") 出力: $o"; fi

it "N と答えた DCB の版は、ai-playbook の y の追従で一緒に上がらない（今の版の bootstrap.sh を使う）"
reset_fixture; set_latest "$DCB_API" "v0.99.0"; set_tags "$PB_TAGS" "v9.0.0"; put_assets_for v0.99.0; put_assets_for "$ORIGIN_VER"
R13="$(new_workdir)/p"; make_repo "$R13"
set_origin_playbook "$R13" tag v0.1.0
notify_in "$R13" "$TEST_TMP_ROOT/cy13"
printf 'v0.99.0\n' > "$TEST_TMP_ROOT/cy13/declined-dcb"
o="$(yes_run "$R13" "$TEST_TMP_ROOT/cy13")"
if [[ "$(cat "$BOOT_LOG")" == "--upgrade --output-dir $R13 --playbook-version v9.0.0" ]] \
  && grep -q "download/$ORIGIN_VER/bootstrap.sh" "$FIX/calls" && ! grep -q 'download/v0.99.0/bootstrap.sh' "$FIX/calls" \
  && [[ "$o" != *"devcontainer-bootstrap $ORIGIN_VER ->"* ]]; then pass; else fail "引数: $(cat "$BOOT_LOG") 出力: $o"; fi

# ── 見せた版だけが declined と追従の対象（#633） ────────────────────────────
# 問いかけを出したあとで latest-dcb を書き換えてから、答えを返す。表示を待ってから書き換える。
ask_with_rewrite() { # <out> <cache> <答え> <書き換える版> [env...]
  local o="$1" cache="$2" ans="$3" newv="$4" outf="$TEST_TMP_ROOT/ask-out.$$" i; shift 4
  : > "$outf"
  : > "$BOOT_LOG"
  {
    for i in $(seq 100); do
      if command grep -q '追従しますか' "$outf" 2>/dev/null; then break; fi
      sleep 0.1
    done
    if [[ "$newv" == REMOVE ]]; then rm -f "$cache/latest-dcb"; else printf '%s\n' "$newv" > "$cache/latest-dcb"; fi
    printf '%s\n' "$ans"
  } | env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$cache" UPDATE_CHECK_TODAY="$TODAY" UPDATE_CHECK_ASSUME_TTY=1 \
    FAKE_CURL_DIR="$FIX" FAKE_BOOT_LOG="$BOOT_LOG" "$@" "$BASH_BIN" "$o/scripts/update-check.sh" prompt > "$outf" 2>&1
  cat "$outf"
}

it "問いかけの最中に latest が新しい版へ書き換わっても、N なら declined には表示した版が書かれる"
reset_fixture; set_latest "$DCB_API" "v0.99.0"
R33="$(new_workdir)/p"; make_repo "$R33"
notify_in "$R33" "$TEST_TMP_ROOT/c33n"
o="$(ask_with_rewrite "$R33" "$TEST_TMP_ROOT/c33n" n v0.100.0)"
if [[ "$(cat "$TEST_TMP_ROOT/c33n/declined-dcb" 2>/dev/null)" == v0.99.0 ]]; then pass; else fail "declined=$(cat "$TEST_TMP_ROOT/c33n/declined-dcb" 2>/dev/null) 出力: $o"; fi

it "その場合、書き換わった新しい版は、次の問いかけで聞かれる（declined に飲まれない）"
o="$(ask "$TEST_TMP_ROOT/c33n" n)"
if [[ "$o" == *"追従しますか？"* && "$o" == *v0.100.0* ]]; then pass; else fail "出力: $o"; fi

it "問いかけの最中に latest が新しい版へ書き換わっても、y なら表示した版で追従する"
reset_fixture; set_latest "$DCB_API" "v0.99.0"; put_assets_for v0.99.0; put_assets_for v0.100.0
R33Y="$(new_workdir)/p"; make_repo "$R33Y"
notify_in "$R33Y" "$TEST_TMP_ROOT/c33y"
o="$(ask_with_rewrite "$R33Y" "$TEST_TMP_ROOT/c33y" y v0.100.0)"
if [[ "$(cat "$BOOT_LOG")" == "--upgrade --output-dir $R33Y" ]] \
  && grep -q 'download/v0.99.0/bootstrap.sh' "$FIX/calls" && ! grep -q 'download/v0.100.0/bootstrap.sh' "$FIX/calls" \
  && [[ "$(git -C "$R33Y" symbolic-ref --short HEAD)" == chore/update-dcb-v0.99.0 ]]; then pass; else fail "引数: $(cat "$BOOT_LOG") 出力: $o"; fi

# ── origin/HEAD が無いときは既定ブランチを推定しない（#634） ─────────────────
branch_after_follow() { # <out> <cache>: y で流したあとのブランチ名
  reset_fixture; set_latest "$DCB_API" "v0.99.0"; put_assets_for v0.99.0
  notify_in "$1" "$2"
  yes_run "$1" "$2" >/dev/null
  git -C "$1" symbolic-ref --short HEAD
}
it "origin/HEAD が無く main と master の両方があるとき、master の上から追従すると作業用のブランチが切られる"
R34A="$(new_workdir)/p"; make_repo "$R34A"; git -C "$R34A" branch -q master; git -C "$R34A" switch -q master
b="$(branch_after_follow "$R34A" "$TEST_TMP_ROOT/c34a")"
if [[ "$b" == chore/update-dcb-v0.99.0 ]]; then pass; else fail "ブランチ: $b"; fi

it "同じく main の上から追従しても、作業用のブランチが切られる"
R34B="$(new_workdir)/p"; make_repo "$R34B"; git -C "$R34B" branch -q master
b="$(branch_after_follow "$R34B" "$TEST_TMP_ROOT/c34b")"
if [[ "$b" == chore/update-dcb-v0.99.0 ]]; then pass; else fail "ブランチ: $b"; fi

it "origin/HEAD が無く、main / master の上でもなければ、ブランチを切らない"
R34C="$(new_workdir)/p"; make_repo "$R34C"; git -C "$R34C" branch -q master; git -C "$R34C" switch -q -c feature/y
b="$(branch_after_follow "$R34C" "$TEST_TMP_ROOT/c34c")"
if [[ "$b" == feature/y ]]; then pass; else fail "ブランチ: $b"; fi

it "origin/HEAD があるときは従来どおり、それが指すブランチの上でだけ切る（master が既定なら main の上では切らない）"
R34D="$(new_workdir)/p"; make_repo "$R34D"; git -C "$R34D" branch -q master
git -C "$R34D" update-ref refs/remotes/origin/master master
git -C "$R34D" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
b1="$(branch_after_follow "$R34D" "$TEST_TMP_ROOT/c34d")"
R34E="$(new_workdir)/p"; make_repo "$R34E"; git -C "$R34E" branch -q master
git -C "$R34E" update-ref refs/remotes/origin/master master
git -C "$R34E" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/master
git -C "$R34E" switch -q master
b2="$(branch_after_follow "$R34E" "$TEST_TMP_ROOT/c34e")"
if [[ "$b1" == main && "$b2" == chore/update-dcb-v0.99.0 ]]; then pass; else fail "main の上: $b1 / master の上: $b2"; fi

# ── 見落としの修正（オフライン・ページ・一体の差し替え・後始末） ─────────────
it "オフラインの upgrade は、前の日のキャッシュが残っていても、「すでに最新」と言わず、古い版へ追従せず、失敗で終える"
reset_fixture; set_latest "$DCB_API" "v0.99.0"; put_assets_for v0.99.0
R35="$(new_workdir)/p"; make_repo "$R35"
C35="$TEST_TMP_ROOT/c35"; mkdir -p "$C35"
printf 'v0.99.0\n' > "$C35/latest-dcb"; printf 'v0.99.0=v0.99.0\n' > "$C35/migrations-dcb"; printf '%s\n' "$TODAY" > "$C35/checked"
: > "$BOOT_LOG"
o="$(env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$C35" UPDATE_CHECK_TODAY="$NEXTDAY" FAKE_CURL_DIR="$FIX" FAKE_BOOT_LOG="$BOOT_LOG" FAKE_CURL_FAIL=1 FAKE_CURL_RC=7 "$BASH_BIN" "$R35/scripts/update-check.sh" upgrade </dev/null 2>&1)"; rc=$?
if [[ "$rc" != 0 && "$o" != *すでに最新* && ! -s "$BOOT_LOG" && ! -e "$C35/latest-dcb" && "$(cat "$C35/checked")" == "$TODAY" ]]; then pass; else fail "rc=$rc 出力: $o"; fi

it "ai-playbook のタグが 100 件を超えるときは、ページをたどって最大を取る（2 ページ目に最大がある）"
reset_fixture
set_tags "$PB_TAGS" $(seq -f 'v0.0.%g' 1 100)
set_tags "$PB_TAGS&page=2" "v10.0.0" "v1.0.0-rc1"
RPG="$(new_workdir)/p"; make_repo "$RPG"; set_origin_playbook "$RPG" tag v0.1.0
CPG="$TEST_TMP_ROOT/cpg"
env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$CPG" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$RPG/scripts/update-check.sh" notify </dev/null >/dev/null 2>&1
if [[ "$(cat "$CPG/latest-playbook" 2>/dev/null)" == v10.0.0 ]] && grep -q 'page=2' "$FIX/calls" && ! grep -q 'page=3' "$FIX/calls"; then pass; else fail "latest=$(cat "$CPG/latest-playbook" 2>/dev/null) calls: $(grep ai-playbook "$FIX/calls")"; fi

it "問いかけの最中に latest が消えても、N なら表示した版が declined に書かれる"
reset_fixture; set_latest "$DCB_API" "v0.99.0"
R36="$(new_workdir)/p"; make_repo "$R36"
notify_in "$R36" "$TEST_TMP_ROOT/c36n"
o="$(ask_with_rewrite "$R36" "$TEST_TMP_ROOT/c36n" n REMOVE)"
if [[ "$(cat "$TEST_TMP_ROOT/c36n/declined-dcb" 2>/dev/null)" == v0.99.0 ]]; then pass; else fail "declined=$(cat "$TEST_TMP_ROOT/c36n/declined-dcb" 2>/dev/null) 出力: $o"; fi

it "問いかけの最中に latest が消えても、y なら表示した版で追従する（キャッシュへ戻らない）"
reset_fixture; set_latest "$DCB_API" "v0.99.0"; put_assets_for v0.99.0
R37="$(new_workdir)/p"; make_repo "$R37"
notify_in "$R37" "$TEST_TMP_ROOT/c37y"
o="$(ask_with_rewrite "$R37" "$TEST_TMP_ROOT/c37y" y REMOVE)"
if [[ "$(cat "$BOOT_LOG")" == "--upgrade --output-dir $R37" ]] && grep -q 'download/v0.99.0/bootstrap.sh' "$FIX/calls"; then pass; else fail "引数: $(cat "$BOOT_LOG") 出力: $o"; fi

it "latest と版の違う migrations（差し替えの途中の組み合わせ）は使わず、リリースノートを読む案内に留める"
reset_fixture; set_latest "$DCB_API" "v0.99.0"
CMX="$TEST_TMP_ROOT/cmx"; run_uc "$CMX" notify >/dev/null
printf 'v0.50.0=v0.40.0 v0.45.0\n' > "$CMX/migrations-dcb"
o="$(ask "$CMX" n)"
if [[ "$o" != *"[注意]"* && "$o" == *リリースノート* ]]; then pass; else fail "出力: $o"; fi

it "latest と版の合う migrations は使う"
printf 'v0.99.0=v0.98.0 v0.99.0\n' > "$CMX/migrations-dcb"; rm -f "$CMX/declined-dcb"
o="$(ask "$CMX" n)"
if [[ "$o" == *"[注意]"* && "$o" == *v0.98.0* ]]; then pass; else fail "出力: $o"; fi

it "取得の途中で TERM を受けても（中断しても）、作業用のファイル・ディレクトリを残さない"
STUBBIN3="$TEST_TMP_ROOT/stubbin3"; mkdir -p "$STUBBIN3"
printf '#!/usr/bin/env bash\nkill -TERM "$PPID"\nsleep 1\nexit 22\n' > "$STUBBIN3/curl"; chmod +x "$STUBBIN3/curl"
CTR="$TEST_TMP_ROOT/ctrap"; mkdir -p "$CTR"
env PATH="$STUBBIN3:$PATH" UPDATE_CHECK_CACHE_DIR="$CTR" UPDATE_CHECK_TODAY="$TODAY" "$BASH_BIN" "$UC" notify </dev/null >/dev/null 2>&1; rc=$?
left="$(ls -A "$CTR" | command grep '^\.' || true)"
if [[ "$rc" == 143 && -z "$left" && ! -e "$CTR/checked" ]]; then pass; else fail "rc=$rc 残り: $left"; fi

it "1 日より古い作業用のファイル・ディレクトリは、取得の開始時に片づける（新しいものは残す）"
CLN="$TEST_TMP_ROOT/cclean"; mkdir -p "$CLN/.stage.old" "$CLN/.stage.new"; : > "$CLN/.fetch.old"
touch -t 200001010000 "$CLN/.stage.old" "$CLN/.fetch.old"
reset_fixture; set_latest "$DCB_API" "v0.99.0"
run_uc "$CLN" notify >/dev/null
if [[ ! -e "$CLN/.stage.old" && ! -e "$CLN/.fetch.old" && -d "$CLN/.stage.new" ]]; then pass; else fail "残り: $(ls -A "$CLN" | tr '\n' ' ')"; fi

it "origin/HEAD が無く main / master も無いときに切った場合、既定ブランチの上だったとは言わず、念のため切ったと言う"
reset_fixture; set_latest "$DCB_API" "v0.99.0"; put_assets_for v0.99.0
R38="$(new_workdir)/p"; make_repo "$R38"; git -C "$R38" branch -q -m main develop
notify_in "$R38" "$TEST_TMP_ROOT/c38"
o="$(yes_run "$R38" "$TEST_TMP_ROOT/c38")"
if [[ "$o" == *念のため* && "$o" != *"既定ブランチ（"* ]]; then pass; else fail "出力: $o"; fi

it "origin/HEAD が無く main の上だったときは、origin/HEAD が無いため main / master の上とみなして切ったと言う"
reset_fixture; set_latest "$DCB_API" "v0.99.0"; put_assets_for v0.99.0
R39="$(new_workdir)/p"; make_repo "$R39"
notify_in "$R39" "$TEST_TMP_ROOT/c39"
o="$(yes_run "$R39" "$TEST_TMP_ROOT/c39")"
if [[ "$o" == *"origin/HEAD が無いため"* && "$o" != *念のため* ]]; then pass; else fail "出力: $o"; fi

# 排他
reset_fixture; set_latest "$DCB_API" "v0.99.0"
CL="$TEST_TMP_ROOT/clock"; run_uc "$CL" notify >/dev/null
it "ほかの端末が聞いているあいだ（flock）は、この端末では聞かない"
if command -v flock >/dev/null 2>&1; then
  flock "$CL/lock" sleep 3 &
  holder=$!
  sleep 1
  o="$(ask "$CL" n)"
  wait "$holder" 2>/dev/null
  o2="$(ask "$CL" n)"
  if [[ -z "$o" && "$o2" == *"追従しますか？"* ]]; then pass; else fail "保持中: [$o] 解放後: [$o2]"; fi
else
  pass
fi

it "flock が無い環境でも、ロックのディレクトリで排他する（持ち主が生きているあいだ聞かない・消えていれば奪う）"
rm -f "$CL/declined-dcb"
mkdir -p "$CL/lock.d"
sleep 5 & live=$!
printf '%s\n' "$live" > "$CL/lock.d/pid"
o="$(ask "$CL" n UPDATE_CHECK_NO_FLOCK=1)"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
o2="$(ask "$CL" n UPDATE_CHECK_NO_FLOCK=1)"
if [[ -z "$o" && "$o2" == *"追従しますか？"* && ! -d "$CL/lock.d" ]]; then pass; else fail "生存中: [$o] 消滅後: [$o2]"; fi

# rc への差し込み
it "rc への差し込みの印はプロジェクトごとで、2 つ目のプロジェクトも注入され、そのプロジェクトの中でだけ聞く"
RCH="$TEST_TMP_ROOT/rchome"; mkdir -p "$RCH"
PA="$(new_workdir)/pa"; PB="$(new_workdir)/pb"
run_bootstrap "$PA" >/dev/null 2>&1; run_bootstrap "$PB" >/dev/null 2>&1
for pr in "$PA" "$PB"; do
  env HOME="$RCH" PATH="$STUBBIN:$PATH" FAKE_CURL_DIR="$FIX" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/rcc" "$BASH_BIN" "$pr/scripts/on-attach.sh" >/dev/null 2>&1 </dev/null
done
n_marks="$(grep -c '^# >>> dcb update check: ' "$RCH/.bashrc")"
if [[ "$n_marks" == 2 ]] && grep -qF "dcb update check: $(cd "$PB" && pwd) >>>" "$RCH/.bashrc" \
  && grep -qF '$PWD/' "$RCH/.bashrc"; then pass; else fail "印の数: $n_marks"; fi

it "on-attach.sh を 2 回流しても、印は増えない（冪等）"
env HOME="$RCH" PATH="$STUBBIN:$PATH" FAKE_CURL_DIR="$FIX" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/rcc" "$BASH_BIN" "$PA/scripts/on-attach.sh" >/dev/null 2>&1 </dev/null
if [[ "$(grep -c '^# >>> dcb update check: ' "$RCH/.bashrc")" == 2 ]]; then pass; else fail "増えた"; fi

# ── 前の日のキャッシュ / 片方の失敗 ─────────────────────────────────────────
it "今日の取得に失敗したら、前の日にキャッシュした最新の版は使わない"
reset_fixture; set_latest "$DCB_API" "v0.99.0"
CS="$TEST_TMP_ROOT/cstale"; run_uc "$CS" notify >/dev/null
o1="$(ask "$CS" "")"; rm -f "$CS/declined-dcb"
o2="$(run_uc "$CS" notify UPDATE_CHECK_TODAY="$NEXTDAY" FAKE_CURL_FAIL=1)"
o3="$(printf 'n\n' | env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$CS" UPDATE_CHECK_TODAY="$NEXTDAY" UPDATE_CHECK_ASSUME_TTY=1 "$BASH_BIN" "$UC" prompt 2>&1)"
if [[ "$o1" == *"追従しますか？"* && -z "$o2" && -z "$o3" ]]; then pass; else fail "[$o1] [$o2] [$o3]"; fi

it "DCB の問い合わせが（通信以外の理由で）失敗しても、ai-playbook の確認は止めない"
reset_fixture; set_tags "$PB_TAGS" "v9.0.0"
RP="$(new_workdir)/p"; make_repo "$RP"; set_origin_playbook "$RP" tag v0.1.0
o="$(env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/cpb" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$RP/scripts/update-check.sh" notify </dev/null 2>&1)"
if [[ "$o" == *"ai-playbook v0.1.0 -> v9.0.0"* && "$o" != *"devcontainer-bootstrap"* ]]; then pass; else fail "出力: $o"; fi

it "通信ができない（curl の終了コード 7）と分かったら、残りの問い合わせは試さない"
: > "$FIX/calls"
env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/cpb2" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" FAKE_CURL_FAIL=1 FAKE_CURL_RC=7 "$BASH_BIN" "$RP/scripts/update-check.sh" notify </dev/null >/dev/null 2>&1
if [[ "$(calls)" == 1 ]]; then pass; else fail "問い合わせ回数 $(calls)"; fi

# ── ai-playbook はタグから取る（#631） ───────────────────────────────────────
it "ai-playbook の最新は、タグの一覧のうち vX.Y.Z の最大（並びによらず・プレリリースの形は採らない）で、notify が知らせる"
reset_fixture; set_tags "$PB_TAGS" "v9.0.0-rc1" "v1.2.0" "v10.0.0" "v9.9.9" "v11.0.0-beta" "latest"
RT="$(new_workdir)/p"; make_repo "$RT"; set_origin_playbook "$RT" tag v0.1.0
CT="$TEST_TMP_ROOT/ctag"
o="$(env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$CT" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$RT/scripts/update-check.sh" notify </dev/null 2>&1)"
if [[ "$(cat "$CT/latest-playbook" 2>/dev/null)" == "v10.0.0" && "$o" == *"ai-playbook v0.1.0 -> v10.0.0"* ]]; then pass; else fail "latest=$(cat "$CT/latest-playbook" 2>/dev/null) 出力: $o"; fi

it "ai-playbook は releases/latest を問い合わせない（タグの一覧だけ）"
if ! grep -q 'ai-playbook/releases' "$FIX/calls" && grep -q 'ai-playbook/tags' "$FIX/calls" && ! grep -q 'page=2' "$FIX/calls"; then pass; else fail "calls: $(grep ai-playbook "$FIX/calls")"; fi

it "ai-playbook のタグが形の合うものを 1 つも含まなければ、通知を出さず latest-playbook も書かない"
reset_fixture; set_tags "$PB_TAGS" "v1.2.3-rc1" "main"
CT2="$TEST_TMP_ROOT/ctag2"
o="$(env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$CT2" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$RT/scripts/update-check.sh" notify </dev/null 2>&1)"
if [[ -z "$o" && ! -e "$CT2/latest-playbook" ]]; then pass; else fail "出力: $o"; fi

it "ai-playbook のタグの取得に失敗したら、通知を出さず 0 で終わる"
reset_fixture
CT3="$TEST_TMP_ROOT/ctag3"
o="$(env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$CT3" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$RT/scripts/update-check.sh" notify </dev/null 2>&1)"; rc=$?
if [[ -z "$o" && "$rc" == 0 && ! -e "$CT3/latest-playbook" ]]; then pass; else fail "rc=$rc 出力: $o"; fi

it "ai-playbook でも、飛び越える版の「### 移行」の節を最新のタグの CHANGELOG.md から読む"
reset_fixture; set_tags "$PB_TAGS" "v10.0.0" "v9.0.0" "v0.1.0"
set_changelog "ojos/ai-playbook" "v10.0.0" "v10.0.0:1" "v9.0.0:1" "v0.1.0:1"
CT4="$TEST_TMP_ROOT/ctag4"
env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$CT4" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$RT/scripts/update-check.sh" notify </dev/null >/dev/null 2>&1
if [[ "$(cat "$CT4/migrations-playbook" 2>/dev/null)" == "v10.0.0=v10.0.0 v9.0.0" ]]; then pass; else fail "migrations=$(cat "$CT4/migrations-playbook" 2>/dev/null)"; fi

# ── notify のキャッシュ更新中の prompt（#632） ───────────────────────────────
# 取得の途中（latest の書き直しの前）に prompt が読む状況を、偽の curl が呼ばれた時点で別に prompt を走らせて作る。
STUBBIN2="$TEST_TMP_ROOT/stubbin2"; mkdir -p "$STUBBIN2"
cat > "$STUBBIN2/curl" <<'STUB2'
#!/usr/bin/env bash
# 呼ばれた時点のキャッシュの内容を記録し、prompt を走らせて出力を残してから、通常の偽の curl に委ねる。
if [[ -n "${MID_PROMPT_OUT:-}" && ! -e "$MID_PROMPT_OUT" ]]; then
  ls -A "$UPDATE_CHECK_CACHE_DIR" > "$MID_PROMPT_OUT.ls" 2>/dev/null
  printf 'n\n' | env UPDATE_CHECK_ASSUME_TTY=1 PATH="$ORIG_PATH" "$UC_BASH" "$UC_PATH" prompt > "$MID_PROMPT_OUT" 2>&1
fi
exec "$REAL_STUB" "$@"
STUB2
chmod +x "$STUBBIN2/curl"

it "notify の取得の途中に prompt が読んでも、古い latest が見えて、問いかけの候補が空にならない"
reset_fixture; set_latest "$DCB_API" "v0.99.0"
CM="$TEST_TMP_ROOT/cmid"; run_uc "$CM" notify >/dev/null
rm -f "$CM/declined-dcb"
set_latest "$DCB_API" "v0.100.0"
MID="$TEST_TMP_ROOT/mid-out"; rm -f "$MID" "$MID.ls"
env PATH="$STUBBIN2:$STUBBIN:$PATH" ORIG_PATH="$STUBBIN:$PATH" REAL_STUB="$STUBBIN/curl" UC_BASH="$BASH_BIN" UC_PATH="$UC" MID_PROMPT_OUT="$MID" \
  UPDATE_CHECK_CACHE_DIR="$CM" UPDATE_CHECK_TODAY="$NEXTDAY" FAKE_CURL_DIR="$FIX" "$BASH_BIN" "$UC" notify </dev/null >/dev/null 2>&1
if [[ -f "$MID" && "$(cat "$MID")" == *"追従しますか？"* && "$(cat "$MID")" == *"-> v0.99.0"* ]] && grep -qx 'latest-dcb' "$MID.ls"; then pass; else fail "途中の prompt: [$(cat "$MID" 2>/dev/null)] ls: [$(cat "$MID.ls" 2>/dev/null)]"; fi

it "取得が成功したあとは、latest・migrations・checked が新しい内容になり、作業用のファイルは残らない"
set_changelog "ojos/devcontainer-bootstrap" "v0.100.0" "v0.100.0:1" "v0.99.0:1"
rm -f "$CM/checked"
run_uc "$CM" notify UPDATE_CHECK_TODAY="$NEXTDAY" >/dev/null
if [[ "$(cat "$CM/latest-dcb")" == v0.100.0 && "$(cat "$CM/checked")" == "$NEXTDAY" && "$(cat "$CM/migrations-dcb")" == "v0.100.0=v0.100.0 v0.99.0" ]] \
  && [[ -z "$(ls -A "$CM" | grep '^\.')" ]]; then pass; else fail "latest=$(cat "$CM/latest-dcb") checked=$(cat "$CM/checked") mig=$(cat "$CM/migrations-dcb" 2>/dev/null) ls=$(ls -A "$CM" | tr '\n' ' ')"; fi

it "通信ができずに途中で抜けたら、checked は書かれず、前の日の latest も消え、次の notify で取り直す"
CO="$TEST_TMP_ROOT/coff"; reset_fixture; set_latest "$DCB_API" "v0.99.0"
run_uc "$CO" notify >/dev/null
run_uc "$CO" notify UPDATE_CHECK_TODAY="$NEXTDAY" FAKE_CURL_FAIL=1 FAKE_CURL_RC=7 >/dev/null
gone=0; [[ ! -e "$CO/latest-dcb" && ! -e "$CO/migrations-dcb" ]] && gone=1
n0="$(calls)"
run_uc "$CO" notify UPDATE_CHECK_TODAY="$NEXTDAY" >/dev/null
if [[ "$gone" == 1 && "$(cat "$CO/checked")" == "$NEXTDAY" && "$(calls)" -gt "$n0" && "$(cat "$CO/latest-dcb")" == v0.99.0 ]]; then pass; else fail "gone=$gone checked=$(cat "$CO/checked") calls $n0 -> $(calls)"; fi

it "通信ができずに抜けた日は、checked が書かれない（前の日の印のまま）"
CO2="$TEST_TMP_ROOT/coff2"; reset_fixture; set_latest "$DCB_API" "v0.99.0"
run_uc "$CO2" notify >/dev/null
run_uc "$CO2" notify UPDATE_CHECK_TODAY="$NEXTDAY" FAKE_CURL_FAIL=1 FAKE_CURL_RC=7 >/dev/null
if [[ "$(cat "$CO2/checked")" == "$TODAY" ]]; then pass; else fail "checked=$(cat "$CO2/checked")"; fi

# ── lock.d の持ち主判定 ──────────────────────────────────────────────────────
it "lock.d に pid がまだ無くても、作った直後は持ち主ありとみなして消さない"
reset_fixture; set_latest "$DCB_API" "v0.99.0"
CP="$TEST_TMP_ROOT/cpidless"; run_uc "$CP" notify >/dev/null
mkdir -p "$CP/lock.d"
o="$(ask "$CP" n UPDATE_CHECK_NO_FLOCK=1)"
if [[ -z "$o" && -d "$CP/lock.d" ]]; then pass; else fail "消した/聞いた: [$o]"; fi

it "pid の無い lock.d が十分古ければ、奪って聞く"
touch -t 200001010000 "$CP/lock.d"
o="$(ask "$CP" n UPDATE_CHECK_NO_FLOCK=1)"
if [[ "$o" == *"追従しますか？"* ]]; then pass; else fail "聞かなかった: [$o]"; fi

# ── rc への差し込みを、危険なパスでもコマンドにしない ────────────────────────
it "パスに \$(...)・引用符・空白を含むプロジェクトでも、rc の差し込みはコマンドとして解釈されず、そのプロジェクトの中でだけ動く"
EVIL_PARENT="$(new_workdir)"
EVIL="$EVIL_PARENT"'/a$(touch PWNED)b "q" `touch PWNED2` x'
run_bootstrap "$EVIL" >/dev/null 2>&1
EH="$TEST_TMP_ROOT/evilhome"; mkdir -p "$EH"
env HOME="$EH" PATH="$STUBBIN:$PATH" FAKE_CURL_DIR="$FIX" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/evc" "$BASH_BIN" "$EVIL/scripts/on-attach.sh" >/dev/null 2>&1 </dev/null
# update-check.sh を、呼ばれたことを記録するだけの物に替える。
printf '#!/usr/bin/env bash\necho ran >> "$HOME/ran"\n' > "$EVIL/scripts/update-check.sh"
# 端末（pty）つきの対話シェルは script(1)（util-linux）で作る。無い環境では確かめられないので飛ばす。
run_pty() { # <cwd>
  ( cd "$1" && HOME="$EH" script -qec 'bash -i -c true' /dev/null </dev/null ) >/dev/null 2>&1
}
PTY_ELSEWHERE="$(new_workdir)"
ran_elsewhere=0
if script -qec true /dev/null </dev/null >/dev/null 2>&1; then
  run_pty "$PTY_ELSEWHERE"
  [[ -f "$EH/ran" ]] && ran_elsewhere=1
  run_pty "$EVIL"
else
  # script(1) が無い環境: 実行されないこと（PWNED が無い）だけを確かめ、動作の確認は飛ばす。
  ( cd "$EVIL" && HOME="$EH" bash -i -c true ) >/dev/null 2>&1 </dev/null
  echo ran > "$EH/ran"
fi
if [[ "$ran_elsewhere" == 0 && -f "$EH/ran" ]] \
  && [[ ! -e "$PTY_ELSEWHERE/PWNED" && ! -e "$EVIL/PWNED" && ! -e "$PTY_ELSEWHERE/PWNED2" && ! -e "$EVIL/PWNED2" && ! -e "$EH/PWNED" && ! -e "$EH/PWNED2" ]]; then pass; else fail "別の場所で動いた=$ran_elsewhere 中で動いた=$([[ -f "$EH/ran" ]] && echo 1 || echo 0) PWNED=$(find "$TEST_TMP_ROOT" -name 'PWNED*' | head -2)"; fi

it "印の行（コメント）に改行を含むパスでも、行が分かれてコマンドにならない"
EVIL2="$EVIL_PARENT"'/nl'$'\n''touch PWNED3'$'\n''x'
run_bootstrap "$EVIL2" >/dev/null 2>&1
EH2="$TEST_TMP_ROOT/evilhome2"; mkdir -p "$EH2"
env HOME="$EH2" PATH="$STUBBIN:$PATH" FAKE_CURL_DIR="$FIX" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/evc2" "$BASH_BIN" "$EVIL2/scripts/on-attach.sh" >/dev/null 2>&1 </dev/null
( cd "$EH2" && HOME="$EH2" bash -i -c true ) >/dev/null 2>&1 </dev/null
( cd "$EVIL_PARENT" && HOME="$EH2" bash -i -c true ) >/dev/null 2>&1 </dev/null
if [[ -s "$EH2/.bashrc" && -z "$(find "$TEST_TMP_ROOT" -name 'PWNED3*' 2>/dev/null)" && ! -e "$EH2/touch" ]]; then pass; else fail "実行された"; fi

# ── 本物の bootstrap.sh との結合 ─────────────────────────────────────────────
it "本物の bootstrap.sh（版だけ新しくした写し）で --upgrade が通り、ORIGIN の版が進む"
reset_fixture; set_latest "$DCB_API" "v0.99.0"
REAL="$TEST_TMP_ROOT/real-bootstrap.sh"
sed 's/^DCB_VERSION="v[0-9.]*"$/DCB_VERSION="v0.99.0"/' "$BOOTSTRAP" > "$REAL"
cp "$REAL" "$(fixture_path "$DL/bootstrap.sh")"
printf '%s  bootstrap.sh\n' "$(sha_of "$REAL")" > "$(fixture_path "$DL/SHA256SUMS")"
R8="$(new_workdir)/p"; make_repo "$R8"
o="$(env PATH="$STUBBIN:$PATH" UPDATE_CHECK_CACHE_DIR="$TEST_TMP_ROOT/cy8" UPDATE_CHECK_TODAY="$TODAY" FAKE_CURL_DIR="$FIX" \
  TEST_BASE_IMAGE_UNUSED=1 "$BASH_BIN" "$R8/scripts/update-check.sh" upgrade </dev/null 2>&1)"
if grep -qx 'version=v0.99.0' "$R8/.devcontainer/ORIGIN" && [[ "$(git -C "$R8" rev-list --count HEAD)" == 1 ]] \
  && [[ "$(git -C "$R8" symbolic-ref --short HEAD)" == "chore/update-dcb-v0.99.0" ]]; then pass; else fail "出力: $o"; fi

exit_with_result
