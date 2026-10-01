#!/usr/bin/env bash
# scripts/second-opinion-gate-exempt.sh の判定を表で確かめる（#361）。
#
# .github/workflows/second-opinion-gate.yml は GitHub 上でしか動かないので、
# 除外の判定はここで機械的に押さえる（check-writeback-serial.sh と同じ形）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-second-opinion-gate-exempt"

TARGET="$REPO_ROOT/scripts/second-opinion-gate-exempt.sh"

it "判定本体が存在する"
if [[ -f "$TARGET" ]]; then
  pass
else
  fail "見つからない: $TARGET"
fi

# case <名前> <期待する終了コード> <期待する出力> <入力>
case_() {
  local name="$1" want_rc="$2" want_out="$3" input="$4" got_out got_rc=0
  it "$name"
  got_out="$(printf '%b' "$input" | bash "$TARGET" 2>/dev/null)" || got_rc=$?
  if [[ "$got_rc" == "$want_rc" && "$got_out" == "$want_out" ]]; then
    pass
  else
    fail "want rc=$want_rc out=$want_out / got rc=$got_rc out=$got_out"
  fi
}

case_ "Dependabot の PR（コミットも Dependabot）は除外" 0 exempt \
  "dependabot[bot]\ndependabot[bot]\n"
case_ "コミットが複数でも全部 Dependabot なら除外" 0 exempt \
  "dependabot[bot]\ndependabot[bot]\ndependabot[bot]\n"
case_ "人の PR は判定する" 0 judge "someone\nsomeone\n"
# Dependabot のブランチへ人が足したコミットを、第二意見なしで通さない。
case_ "Dependabot の PR に人のコミットが混ざれば判定する" 0 judge \
  "dependabot[bot]\ndependabot[bot]\nsomeone\n"
case_ "アカウントに紐づかないコミットが混ざれば判定する" 0 judge \
  "dependabot[bot]\ndependabot[bot]\n-\n"
case_ "人の PR に Dependabot のコミットだけでも判定する" 0 judge \
  "someone\ndependabot[bot]\n"
case_ "ほかの bot は除外しない" 0 judge \
  "github-actions[bot]\ngithub-actions[bot]\n"
case_ "似た名前は除外しない" 0 judge "dependabot\ndependabot\n"
case_ "CRLF でも同じ答え" 0 exempt "dependabot[bot]\r\ndependabot[bot]\r\n"
case_ "末尾の改行が無くても読む" 0 exempt "dependabot[bot]\ndependabot[bot]"
# 読めないことを exempt に倒さない。
case_ "空の入力は判定できない" 2 "" ""
case_ "コミットが無ければ判定できない" 2 "" "dependabot[bot]\n"
case_ "著者が空なら判定できない" 2 "" "\ndependabot[bot]\n"

exit_with_result
