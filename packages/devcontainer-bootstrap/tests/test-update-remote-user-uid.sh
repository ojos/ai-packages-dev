#!/usr/bin/env bash
# test-update-remote-user-uid.sh — 生成物が updateRemoteUserUID を無効にしていないことを検査する。
#
# ネイティブ Linux の Docker Engine は bind mount の所有者を数値の UID のまま通すため、
# ホストの利用者の UID/GID がコンテナの vscode（1000）と違うと、ワークスペースへ
# 書き込めない。この食い違いは、Dev Containers の updateRemoteUserUID（既定で有効）が
# コンテナを作る時点で vscode の UID/GID をホストの利用者へ付け替えることで吸収される。
# 生成物の dockerComposeFile 方式でも働くことは実測で確かめている（README「ネイティブ
# Linux の Docker でのワークスペースの所有者」）。
#
# 生成物は付け替えを既定に任せ、自前の仕組みを持たない。そのため、devcontainer.json が
# updateRemoteUserUID: false を持つと、ネイティブ Linux のホストで黙って書き込めなくなる。
# 本テストはその退行を機械で止める（キーを書かないか、書くなら true であること）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-update-remote-user-uid"

# devcontainer.json の updateRemoteUserUID が無効でないか。0 = 無効でない / 1 = false。
uid_update_enabled() {
  local json="$1"
  jq -e '(has("updateRemoteUserUID") | not) or .updateRemoteUserUID == true' "$json" >/dev/null
}

it "素の生成物は updateRemoteUserUID を無効にしない"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
if uid_update_enabled "$out/.devcontainer/devcontainer.json"; then
  pass
else
  fail "devcontainer.json が updateRemoteUserUID を無効にしている"
fi

it "全 --with-* 指定の生成物も updateRemoteUserUID を無効にしない"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-aws --with-gcp --with-claude --with-gemini --with-antigravity --with-codex --with-copilot >/dev/null 2>&1
if uid_update_enabled "$out/.devcontainer/devcontainer.json"; then
  pass
else
  fail "devcontainer.json が updateRemoteUserUID を無効にしている"
fi

it "判定は false を検出できる（検査そのものの確認）"
probe="$(new_workdir)/probe.json"
printf '{"updateRemoteUserUID": false}\n' >"$probe"
if uid_update_enabled "$probe"; then
  fail "updateRemoteUserUID: false を無効と判定できていない"
else
  pass
fi

exit_with_result
