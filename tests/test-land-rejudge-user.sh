#!/usr/bin/env bash
# test-land-rejudge-user.sh — land スキルの雛形の再判定（8）が、待ちを「自分が起こした手動実行」に
# 絞ることを、雛形から rejudge_one を取り出し、gh を偽物に差し替えて検証する（#555）。
#
# ## 背景
#
# 待ちを打ち切る条件は、起こす前より新しい手動実行がすべて終わったことしか見ていなかった。
# ほかの人の手動実行が先に終わると、自分の実行が一覧に現れる前でも成り立ち、unchanged で止まった。
# 修正は gh run list --user <自分の login> で絞ること。login が読めなければ止める。
#
# ## 検査（雛形の目印 # >>> land:rejudge ... # <<< land:rejudge を取り出して実行する）
#   (1) ほかのアカウントの手動実行が先に終わり、自分の実行がまだ無いとき、打ち切らず待ち続ける。
#   (2) 自分の実行が終わり、判定結果が書き直されていないとき、unchanged で止まる。
#   (3) 判定結果が書き直されたとき、REJUDGE_OK になる（success 以外ならその旨で止まる）。
#   (4) 自分の login が得られないとき、実行を起こさず REJUDGE_FAIL で止まる。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-land-rejudge-user"

TEMPLATE="$REPO_ROOT/.ai-playbook/templates/claude-skill-land.md"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/land-rejudge.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

awk -v b="# >>> land:rejudge" -v e="# <<< land:rejudge" '
  $0 == e { on = 0 }
  on { print }
  $0 == b { on = 1 }' "$TEMPLATE" > "$WORK/rejudge.sh"

it "雛形から、再判定の関数を取り出せる"
if [[ -s "$WORK/rejudge.sh" ]]; then pass; else fail "目印で囲まれた部分が空（# >>> land:rejudge）"; fi

# 偽の gh。シナリオのディレクトリ（FAKE_DIR）のファイルを読む。
#   login            api user の出力（無ければ失敗）
#   runs.<n>.json    n 周目以降の gh run list の中身（actor を持つ。新しい順）
#   status.<n>       n 周目以降の commit status 行 "<state> <target_url>"
#   run.<id>         actions/runs/<id> の出力
# n は status を読んだ回数（待ちの周回）。n 以下で最大のファイルを使う。
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'FAKE'
#!/usr/bin/env bash
d="$FAKE_DIR"
pick() { # <接頭辞> <接尾辞> — 周回 n 以下で最大のもの
  local n i; n="$(cat "$d/poll" 2>/dev/null || echo 0)"
  for ((i = n; i >= 0; i--)); do [[ -e "$d/$1.$i$2" ]] && { echo "$d/$1.$i$2"; return; }; done
  return 1
}
jqexpr=""; user=""; limit=1000
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[i]}" in
    --jq) jqexpr="${args[i+1]}" ;;
    --user) user="${args[i+1]}" ;;
    --limit) limit="${args[i+1]}" ;;
  esac
done
case "$1 $2" in
  "api user")
    [[ -e "$d/login" ]] || exit 1
    cat "$d/login" ;;
  "run list")
    f="$(pick runs .json)" || exit 1
    jq -c --arg u "$user" --argjson l "$limit" '[.[] | select($u == "" or .actor == $u)] | .[:$l]' "$f" | jq -r "$jqexpr" ;;
  "workflow run")
    echo run >> "$d/dispatched" ;;
  "api repos/{owner}/{repo}/commits/"*)
    echo $(( $(cat "$d/poll" 2>/dev/null || echo 0) + 1 )) > "$d/poll"
    f="$(pick status "")" || exit 1
    read -r s u < "$f"
    jq -n -r --arg s "$s" --arg u "$u" '{statuses:[{context:"second-opinion-gate",state:$s,target_url:$u}]}' | jq -r "$jqexpr" ;;
  "api repos/{owner}/{repo}/actions/runs/"*)
    cat "$d/run.${2##*/}" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$WORK/bin/gh"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OLD="2020-01-01T00:00:00Z"
URL="https://github.com/o/r/actions/runs"
OKRUN='workflow_dispatch main completed .github/workflows/second-opinion-gate.yml'

# run_case <シナリオのディレクトリ> — 出力（と rc=終了コード）を返す
run_case() {
  PATH="$WORK/bin:$PATH" FAKE_DIR="$1" bash -c '
    . "$1"
    sleep() { :; }
    rejudge_one second-opinion-gate.yml main abc123
    echo "rc=$?"' _ "$WORK/rejudge.sh" 2>&1
}
mk() { rm -rf "${WORK:?}/$1"; mkdir -p "$WORK/$1"; }
# run_json <id> <actor> <createdAt> — gh run list の 1 件
run_json() { printf '{"databaseId":%s,"status":"completed","createdAt":"%s","actor":"%s"}' "$1" "$3" "$2"; }

R100="$(run_json 100 other "$OLD")"
R105="$(run_json 105 other "$NOW")"
R106="$(run_json 106 me "$NOW")"

# 起こす前: 最新の手動実行は 100（ほかの人）。判定結果は古い run 90 のまま。
# (1) ほかの人の 105 が先に終わる。自分の 106 は 3 周目に現れ、同時に判定結果が書き直される（1・2 周目は旧い old 結果のまま）。
mk c1; D="$WORK/c1"; echo me > "$D/login"
printf 'success %s/90\n' "$URL" > "$D/status.0"
printf 'success %s/106\n' "$URL" > "$D/status.3"
echo "$OKRUN" > "$D/run.106"
echo "[$R100]" > "$D/runs.0.json"
echo "[$R105,$R100]" > "$D/runs.1.json"
echo "[$R106,$R105,$R100]" > "$D/runs.3.json"
it "ほかのアカウントの手動実行が先に終わっても、自分の実行が現れるまで unchanged で打ち切らず待ち、書き直されれば REJUDGE_OK"
OUT="$(run_case "$D")"
if [[ "$OUT" == *"REJUDGE_OK second-opinion-gate.yml: run 106"* && "$OUT" == *"rc=0"* ]]; then pass; else fail "出力: $OUT"; fi

# (2) 自分の 106 が終わったが、判定結果は古いまま。
mk c2; D="$WORK/c2"; echo me > "$D/login"
printf 'success %s/90\n' "$URL" > "$D/status.0"
echo "[$R100]" > "$D/runs.0.json"
echo "[$R106,$R100]" > "$D/runs.1.json"
it "自分の実行が終わり、判定結果が書き直されていないときは、unchanged で止まる"
OUT="$(run_case "$D")"
if [[ "$OUT" == *"REJUDGE_FAIL second-opinion-gate.yml: 手動実行は終わったが"* && "$OUT" == *"rc=1"* ]]; then pass; else fail "出力: $OUT"; fi

# (3) 判定結果が書き直され、failure のとき。
mk c3; D="$WORK/c3"; echo me > "$D/login"
printf 'success %s/90\n' "$URL" > "$D/status.0"
printf 'failure %s/106\n' "$URL" > "$D/status.1"
echo "$OKRUN" > "$D/run.106"
echo "[$R100]" > "$D/runs.0.json"
it "判定結果が書き直されても success でなければ REJUDGE_FAIL（結果が success ではない）"
OUT="$(run_case "$D")"
if [[ "$OUT" == *"再判定の結果が success ではない"* && "$OUT" == *"rc=1"* ]]; then pass; else fail "出力: $OUT"; fi

# (4) login が読めない。
mk c4; D="$WORK/c4"
printf 'success %s/90\n' "$URL" > "$D/status.0"
echo "[$R100]" > "$D/runs.0.json"
it "自分の login が得られないときは、手動実行を起こさず REJUDGE_FAIL で止まる"
OUT="$(run_case "$D")"
if [[ "$OUT" == *"REJUDGE_FAIL second-opinion-gate.yml: 自分の login"* && "$OUT" == *"rc=1"* && ! -e "$D/dispatched" ]]; then pass; else fail "出力: $OUT"; fi

it "待ちの絞り込みが --user で行われる（雛形の関数に --user \"\$me\" がある）"
if command grep -F -- '--user "$me"' "$WORK/rejudge.sh" >/dev/null; then pass; else fail "--user が無い"; fi

exit_with_result
