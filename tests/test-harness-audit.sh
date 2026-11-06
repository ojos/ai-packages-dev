#!/usr/bin/env bash
# scripts/harness-audit.sh（自前の実装の一覧と本体の変更履歴の突き合わせ）の検査（#710）。
#
# 仕込みの変更履歴（4 版）と仕込みの一覧で、起点の決め方・候補の出方・末尾の印・
# 失敗の扱いを確かめる。ネットワークへは出ない（--changelog で必ずファイルを渡す）。
#
# bash 3.2 互換を維持する（連想配列・mapfile を使わない）。jq を要する（スクリプト自身の依存）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-harness-audit"

AUDIT="$REPO_ROOT/scripts/harness-audit.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/test-harness-audit.XXXXXX")"
trap 'rm -rf "$T"' EXIT

cat > "$T/changelog.md" <<'EOF'
# Changelog

## 2.1.12

- Added agent teams broadcast so every teammate sees the message
- Fixed a flicker in the status line

## 2.1.11

- Added a built-in merge confirmation prompt for pull requests
- Fixed an unrelated crash on startup

## 2.1.10

- Added SendMessage between sessions of the same project
- Improved scrollback performance

## 2.1.9

- Changed the old oldmarker behavior of hooks
EOF

cat > "$T/inventory.json" <<'EOF'
{"version":1,"items":[
 {"id":"scripts/a.sh","kind":"script","path":"scripts/a.sh","compensates":"セッション間のメッセージが無い不足","keywords":["sendmessage","agent teams"],"issue":"#1"},
 {"id":"scripts/b.sh","kind":"script","path":"scripts/b.sh","compensates":"マージ前の承認が無い不足","keywords":["merge confirmation"],"issue":null},
 {"id":"scripts/c.sh","kind":"script","path":"scripts/c.sh","compensates":null,"keywords":["oldmarker"],"issue":null},
 {"id":"scripts/d.sh","kind":"script","path":"scripts/d.sh","compensates":null,"keywords":[],"issue":null}
]}
EOF

# 監査を回す。出力は $T/out.md、終了コードは RC に入る。
run_audit() {
  "$AUDIT" --inventory "$T/inventory.json" "$@" > "$T/out.md" 2> "$T/err.txt"
  RC=$?
}

it "--since の版より後の版だけを見る（起点の版そのものは含まない）"
run_audit --changelog "$T/changelog.md" --since 2.1.10
if [[ "$RC" -eq 0 ]] && grep -q 'agent teams' "$T/out.md" && grep -q 'merge confirmation' "$T/out.md" \
  && ! grep -q 'SendMessage between' "$T/out.md" && ! grep -q 'oldmarker' "$T/out.md"; then
  pass
else
  fail "rc=$RC 起点以前の項目が混ざったか、後の項目が出ていない"
fi

it "版の比較は数値で行う（2.1.9 より 2.1.10 が新しい）"
run_audit --changelog "$T/changelog.md" --since 2.1.9
if [[ "$RC" -eq 0 ]] && grep -q 'SendMessage between' "$T/out.md" && ! grep -q 'oldmarker' "$T/out.md"; then
  pass
else
  fail "rc=$RC 2.1.10 が 2.1.9 より古い扱いになっている"
fi

it "--since-from-comment は最後の印を起点にする（複数あれば最後）"
cat > "$T/comment.md" <<'EOF'
前回のコメント
<!-- harness-audit: checked-version=2.1.9 -->
さらに前
<!-- harness-audit: checked-version=2.1.11 -->
EOF
run_audit --changelog "$T/changelog.md" --since-from-comment "$T/comment.md"
if [[ "$RC" -eq 0 ]] && grep -q 'agent teams' "$T/out.md" && ! grep -q 'merge confirmation' "$T/out.md" \
  && ! grep -q '直近' "$T/out.md"; then
  pass
else
  fail "rc=$RC 最後の印（2.1.11）が起点になっていない"
fi

it "印が無ければ直近 N 版に絞り、その旨を出す"
run_audit --changelog "$T/changelog.md" --recent 2
if [[ "$RC" -eq 0 ]] && grep -q '前回の印が無い' "$T/out.md" && grep -q '直近 2 版' "$T/out.md" \
  && grep -q 'merge confirmation' "$T/out.md" && ! grep -q 'SendMessage between' "$T/out.md"; then
  pass
else
  fail "rc=$RC 直近 2 版（2.1.12・2.1.11）に絞られていない"
fi

it "印の付いたファイルを渡されても印が無ければ直近 N 版に絞る"
printf '印の無いコメント\n' > "$T/nomark.md"
run_audit --changelog "$T/changelog.md" --since-from-comment "$T/nomark.md" --recent 1
if [[ "$RC" -eq 0 ]] && grep -q '前回の印が無い' "$T/out.md" && grep -q 'agent teams' "$T/out.md" \
  && ! grep -q 'merge confirmation' "$T/out.md"; then
  pass
else
  fail "rc=$RC 印が無いときの扱いが違う"
fi

it "キーワードの一致が候補に出て、一致しない項目は出ない"
run_audit --changelog "$T/changelog.md" --since 2.1.8
if grep -q 'scripts/a.sh' "$T/out.md" && grep -q 'scripts/b.sh' "$T/out.md" \
  && ! grep -q 'flicker' "$T/out.md" && ! grep -q 'unrelated crash' "$T/out.md" \
  && ! grep -q 'scrollback' "$T/out.md" && ! grep -q 'scripts/d.sh' "$T/out.md"; then
  pass
else
  fail "候補の出方が違う"
fi

it "小文字化して部分一致する（SendMessage が sendmessage に当たる）"
# shellcheck disable=SC2016
if grep -q '`sendmessage`' "$T/out.md"; then pass; else fail "sendmessage の一致が無い"; fi

it "末尾の印は対象の中で最も新しい版になる"
if [[ "$(tail -n 1 "$T/out.md")" == '<!-- harness-audit: checked-version=2.1.12 -->' ]]; then
  pass
else
  fail "末尾: $(tail -n 1 "$T/out.md")"
fi

it "対象の版が無いときの印は起点の版のまま"
run_audit --changelog "$T/changelog.md" --since 2.1.12
if [[ "$RC" -eq 0 ]] && [[ "$(tail -n 1 "$T/out.md")" == '<!-- harness-audit: checked-version=2.1.12 -->' ]] \
  && grep -q '候補はありません' "$T/out.md"; then
  pass
else
  fail "rc=$RC 空の対象の扱いが違う"
fi

it "冒頭に承認の根拠にならない旨がある"
if grep -q '承認の根拠になりません' <(head -n 2 "$T/out.md"); then pass; else fail "冒頭に断りが無い"; fi

it "数の表が出る（script / フック / スキル / CI のジョブ / 常時の行数）"
if grep -q '^| scripts/\*.sh |' "$T/out.md" && grep -q '^| フック' "$T/out.md" && grep -q '^| スキル' "$T/out.md" \
  && grep -q '^| CI のジョブ' "$T/out.md" && grep -q '常に載る規範の行数' "$T/out.md"; then
  pass
else
  fail "数の表が足りない"
fi

it "変更履歴のファイルが無いと 0 以外で終わり、理由を標準エラーへ出す"
run_audit --changelog "$T/nothing.md"
if [[ "$RC" -eq 2 ]] && [[ -s "$T/err.txt" ]] && [[ ! -s "$T/out.md" ]]; then
  pass
else
  fail "rc=$RC"
fi

it "版の見出しが 1 つも無い変更履歴は 0 以外で終わる（空の候補で通さない）"
printf '# Changelog\n\n- 見出しの無い項目\n' > "$T/nohead.md"
run_audit --changelog "$T/nohead.md"
if [[ "$RC" -eq 2 ]] && [[ -s "$T/err.txt" ]]; then pass; else fail "rc=$RC"; fi

it "未知の引数は 2 で終わり usage を出す"
run_audit --bogus
if [[ "$RC" -eq 2 ]] && grep -q 'usage' "$T/err.txt"; then pass; else fail "rc=$RC"; fi

it "前回の印の版が変更履歴の見出しに無ければ 2 で止める（偽の印・引用の印で黙って止まらない）"
printf '<!-- harness-audit: checked-version=99.0.0 -->\n' > "$T/forged.md"
run_audit --changelog "$T/changelog.md" --since-from-comment "$T/forged.md"
if [[ "$RC" -eq 2 ]] && grep -q '99.0.0' "$T/err.txt" && [[ ! -s "$T/out.md" ]]; then pass; else fail "rc=$RC"; fi

it "語の直前が英数字なら一致にしない（agent teams が subagent teams に当たらない）"
cat > "$T/boundary.md" <<'EOF'
## 3.0.1

- Changed subagent teams to run in parallel
- Fixed `agent teams` resume
EOF
run_audit --changelog "$T/boundary.md" --since 3.0.0
if [[ "$RC" -eq 0 ]] && ! grep -q 'subagent teams to run' "$T/out.md" && grep -q 'resume' "$T/out.md"; then
  pass
else
  fail "rc=$RC 語の境界の扱いが違う"
fi

it "外部の文の @ と #数字 と < を無害にする（通知・誤った参照・行の隠れを作らない）"
cat > "$T/inject.md" <<'EOF'
## 3.0.1

- Fixed SendMessage reported by @someone in #123 <!-- hidden
EOF
run_audit --changelog "$T/inject.md" --since 3.0.0
row="$(grep 'SendMessage' "$T/out.md")"
if [[ "$RC" -eq 0 ]] && [[ "$row" != *"@someone"* && "$row" != *"#123"* && "$row" != *"<!--"* ]] \
  && [[ "$row" == *"&#64;someone"* && "$row" == *"&#35;123"* && "$row" == *"&lt;!--"* ]]; then
  pass
else
  fail "rc=$RC 行: $row"
fi

it "長い項目は UTF-8 の文字の途中で切らない"
long="$(printf 'あ%.0s' $(seq 1 100))"
printf '## 3.0.1\n\n- SendMessage %s\n' "$long" > "$T/long.md"
run_audit --changelog "$T/long.md" --since 3.0.0
if [[ "$RC" -eq 0 ]] && grep 'SendMessage' "$T/out.md" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 \
  && grep -q 'SendMessage.*…' "$T/out.md"; then
  pass
else
  fail "rc=$RC 不正な UTF-8 が出たか、切った印が無い"
fi

it "同じ項目の候補は、版を数値で新しい順に並べる（2.1.10 が 2.1.9 より上）"
cat > "$T/order.md" <<'EOF'
## 2.1.10

- SendMessage ten

## 2.1.9

- SendMessage nine
EOF
run_audit --changelog "$T/order.md" --since 2.1.0
if [[ "$RC" -eq 0 ]] && [[ "$(grep -n 'SendMessage ten' "$T/out.md" | cut -d: -f1)" -lt "$(grep -n 'SendMessage nine' "$T/out.md" | cut -d: -f1)" ]]; then
  pass
else
  fail "rc=$RC 並びが違う"
fi

it "箇条書きの * と + も項目として読む"
printf '## 3.0.1\n\n* SendMessage star\n+ SendMessage plus\n' > "$T/bullets.md"
run_audit --changelog "$T/bullets.md" --since 3.0.0
if [[ "$RC" -eq 0 ]] && grep -q 'SendMessage star' "$T/out.md" && grep -q 'SendMessage plus' "$T/out.md"; then pass; else fail "rc=$RC"; fi

it "対象の版に読める項目が 1 件も無ければ 2 で止める（印を進めない）"
printf '## 3.0.2\n\n1. numbered item\n\n## 3.0.1\n\n- SendMessage ok\n' > "$T/noitems.md"
run_audit --changelog "$T/noitems.md" --since 3.0.0
if [[ "$RC" -eq 2 ]] && grep -q '3.0.2' "$T/err.txt" && [[ ! -s "$T/out.md" ]]; then pass; else fail "rc=$RC"; fi

it "起点が変更履歴の最新の版より新しければ 2 で止める（無い版を印に残さない）"
run_audit --changelog "$T/changelog.md" --since 2.1.13
if [[ "$RC" -eq 2 ]] && grep -q '2.1.13' "$T/err.txt" && [[ ! -s "$T/out.md" ]]; then pass; else fail "rc=$RC"; fi

it "どこから実行しても同じに動く（リポジトリの外の作業ディレクトリから）"
run_audit --changelog "$T/changelog.md" --since 2.1.10
( cd "$T" && "$AUDIT" --inventory "$T/inventory.json" --changelog "$T/changelog.md" --since 2.1.10 > "$T/out2.md" 2>/dev/null )
rc2=$?
if [[ "$rc2" -eq 0 ]] && cmp -s <(sed -n 4,'$p' "$T/out2.md") <(sed -n 4,'$p' "$T/out.md"); then
  pass
else
  fail "rc=$rc2 または出力が食い違う"
fi

exit_with_result
