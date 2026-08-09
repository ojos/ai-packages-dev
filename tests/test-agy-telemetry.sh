#!/usr/bin/env bash
# scripts/install-ai-tools.sh が agy のテレメトリを無効化することを検査する。
#
# agy（Antigravity CLI）は利用統計・クラッシュログ・対話ログを既定で送る
# （settings.json の enableTelemetry、既定 true）。環境変数によるオプトアウトは
# 存在せず（バイナリ実測。DO_NOT_TRACK も非対応）、設定ファイルへ書く以外の手段が
# 無い。プロビジョニング（postCreateCommand）で無効化し、コンテナを作り直した
# 直後から利用者が手を動かさずにオプトアウト済みになっている状態を保つ。
#
# ここで固定するのは、その書き込みが**利用者の設定を壊さない**こと。この
# settings.json は agy 自身も書き込む（colorScheme / trustedWorkspaces 等）ため、
# 上書きではなくマージでなければならない。壊れた JSON を黙って捨てないことと、
# オプトアウトが黙って未適用にならないことも、同じ理由で両方向から固定する。
#
# 他のプロジェクト層テストと違い、このテストは対象スクリプトを実行する（文書と
# 実装のテキスト照合ではない）。実行に伴い jq を要求するが、これは対象スクリプト
# 自身の依存で、テストが新たに持ち込む依存ではない（scripts/acceptance.sh も
# 同じ理由で jq を前提にしている）。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-agy-telemetry"

INSTALL="$REPO_ROOT/scripts/install-ai-tools.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-agy-telemetry.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

n=0
new_home() {
  n=$((n + 1))
  local h="$TMP_ROOT/home$n"
  mkdir -p "$h"
  printf '%s' "$h"
}

# 導入処理を走らせないための stub。install_if_missing / install_agy_if_missing は
# command -v で存在を見て skip するため、PATH 上に空の実行ファイルがあれば足りる。
# npm も curl も呼ばれない（呼ばれたらネットワークへ出るので、それ自体が異常）。
STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"
for c in claude gemini agy npm curl; do
  # $0 は stub の実行時に展開させる。ここで展開すると、どの stub が呼ばれたのかが
  # 分からなくなる。単一引用符は意図的。
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\necho "STUB $0 は呼ばれてはいけない" >&2\nexit 97\n' > "$STUB_BIN/$c"
  chmod +x "$STUB_BIN/$c"
done
# 存在検査だけで skip される 3 つは、呼ばれない前提なので中身を空にしない
# （呼ばれた場合に 97 で落ちて、skip の破れが検出できる）。

run_install() {
  local home="$1"
  shift
  ( HOME="$home" PATH="$STUB_BIN:$PATH" bash "$INSTALL" "$@" 2>&1 )
}

settings_of() {
  printf '%s/.gemini/antigravity-cli/settings.json' "$1"
}

# ── 初回（ファイルが無い） ────────────────────────────────────────────────────

it "設定ファイルが無くても作られ、テレメトリが無効になる"
h="$(new_home)"
out="$(run_install "$h")"; rc=$?
s="$(settings_of "$h")"
if [[ "$rc" -ne 0 ]]; then
  fail "install-ai-tools.sh が落ちた (exit $rc): $out"
elif [[ ! -f "$s" ]]; then
  fail "settings.json が作られていない: $s"
else
  assert_eq "$(jq -r '.enableTelemetry' "$s")" "false" "enableTelemetry"
fi

it "作られる設定ファイルのパーミッションは 600"
# 資格情報そのものではないが、agy 自身が 600 で作る。プロビジョニングが先に
# 作ることで緩くなると、後から agy が作り直すまで緩いままになる。
h="$(new_home)"
run_install "$h" >/dev/null 2>&1
s="$(settings_of "$h")"
mode="$(stat -c %a "$s" 2>/dev/null || stat -f %Lp "$s" 2>/dev/null || echo '?')"
assert_eq "$mode" "600" "settings.json のパーミッション"

# ── 既存設定とのマージ ────────────────────────────────────────────────────────

it "既存キーを保持したままテレメトリだけを無効にする"
# 丸ごと上書きすると、agy が書いた設定（配色・信頼済みワークスペース）が消える。
h="$(new_home)"
s="$(settings_of "$h")"
mkdir -p "$(dirname "$s")"
printf '%s\n' '{"colorScheme":"dark","trustedWorkspaces":["/workspaces/x"]}' > "$s"
out="$(run_install "$h")"; rc=$?
bad=0
[[ "$rc" -eq 0 ]] || { echo "  exit $rc: $out"; bad=1; }
[[ "$(jq -r '.enableTelemetry' "$s")" == "false" ]] || { echo "  enableTelemetry が false でない"; bad=1; }
[[ "$(jq -r '.colorScheme' "$s")" == "dark" ]] || { echo "  colorScheme が消えた"; bad=1; }
[[ "$(jq -r '.trustedWorkspaces[0]' "$s")" == "/workspaces/x" ]] || { echo "  trustedWorkspaces が消えた"; bad=1; }
if [[ "$bad" -eq 0 ]]; then pass; else fail "既存設定を壊している"; fi

it "true が設定済みでも false へ倒す"
h="$(new_home)"
s="$(settings_of "$h")"
mkdir -p "$(dirname "$s")"
printf '%s\n' '{"enableTelemetry":true}' > "$s"
run_install "$h" >/dev/null 2>&1
assert_eq "$(jq -r '.enableTelemetry' "$s")" "false" "enableTelemetry"

# ── 冪等 ──────────────────────────────────────────────────────────────────────

it "再実行しても内容が変わらない（書き込みもしない）"
# 毎回書き換えると、agy が起動中の場合に書き戻しと競合する余地を無駄に増やす。
h="$(new_home)"
run_install "$h" >/dev/null 2>&1
s="$(settings_of "$h")"
mtime_of() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo '?'
}
before="$(cat "$s")"
before_mtime="$(mtime_of "$s")"
out="$(run_install "$h")"
after="$(cat "$s")"
after_mtime="$(mtime_of "$s")"
bad=0
[[ "$before" == "$after" ]] || { echo "  内容が変わった"; bad=1; }
[[ "$before_mtime" == "$after_mtime" ]] || { echo "  書き込みが起きている（mtime が動いた）"; bad=1; }
printf '%s' "$out" | grep -q 'already disabled' || { echo "  skip した旨が出ていない: $out"; bad=1; }
if [[ "$bad" -eq 0 ]]; then pass; else fail "冪等でない"; fi

# ── 壊れた JSON ───────────────────────────────────────────────────────────────

it "JSON として不正なら上書きせず、非 0 で終わる"
# 黙って {} から作り直すと、利用者の設定を捨てたことに誰も気づけない。
# かといって警告だけ出して 0 で終えると、オプトアウトが未適用のまま
# プロビジョニングが成功したように見える。どちらも避ける。
h="$(new_home)"
s="$(settings_of "$h")"
mkdir -p "$(dirname "$s")"
printf '%s\n' '{"colorScheme": "dark",' > "$s"
before="$(cat "$s")"
out="$(run_install "$h")"; rc=$?
bad=0
[[ "$rc" -ne 0 ]] || { echo "  不正な JSON なのに成功した"; bad=1; }
[[ "$(cat "$s")" == "$before" ]] || { echo "  上書きされている"; bad=1; }
printf '%s' "$out" | grep -q 'JSON として読めない' || { echo "  理由が出ていない: $out"; bad=1; }
if [[ "$bad" -eq 0 ]]; then pass; else fail "壊れた JSON の扱いが誤っている"; fi

it "一時ファイルを残さない"
# 差し替え用の一時ファイルが残ると、agy 側から見て素性の分からない設定断片が
# 設定ディレクトリに溜まる。
h="$(new_home)"
run_install "$h" >/dev/null 2>&1
leftovers="$(find "$h/.gemini/antigravity-cli" -name '.settings.json.*' 2>/dev/null)"
if [[ -z "$leftovers" ]]; then pass; else fail "一時ファイルが残っている: $leftovers"; fi

# ── jq が無い環境 ─────────────────────────────────────────────────────────────

it "jq が無ければ黙って未適用にせず、非 0 で止まる"
# ここで 0 を返すと、テレメトリが有効なまま「プロビジョニング成功」になる。
h="$(new_home)"
minbin="$TMP_ROOT/minbin"
mkdir -p "$minbin"
# jq の検査へ到達するまでに要る外部コマンドだけを通す（それ以外は builtin）。
ln -sf "$(command -v dirname)" "$minbin/dirname"
for c in claude gemini agy; do
  cp "$STUB_BIN/$c" "$minbin/$c"
done
# bash は PATH ではなく絶対パスで起動する。PATH を絞る目的は jq を消すことで、
# インタプリタごと見えなくすると「jq が無いから落ちた」ことを確かめられない。
BASH_BIN="$(command -v bash)"
out="$( HOME="$h" PATH="$minbin" "$BASH_BIN" "$INSTALL" 2>&1 )"; rc=$?
bad=0
[[ "$rc" -ne 0 ]] || { echo "  jq 不在でも成功した"; bad=1; }
printf '%s' "$out" | grep -q 'jq' || { echo "  jq 不在が理由として出ていない: $out"; bad=1; }
if [[ "$bad" -eq 0 ]]; then pass; else fail "jq 不在が fail-closed になっていない"; fi

exit_with_result
