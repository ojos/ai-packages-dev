#!/usr/bin/env bash
# .github/workflows/second-opinion-gate.yml の判定を、gh を差し替えて回す（#361）。
#
# test-second-opinion-gate-exempt.sh は判定スクリプト（second-opinion-gate-exempt.sh）の
# exempt / judge しか見ない。**ゲートがそれを success / failure の status へ結び付ける
# ところは、ワークフローの run: | の中にある。** そこで run の本文を YAML からそのまま
# 取り出し、次を差し替えて回す。
#
#   gh    … 用意した JSON に、呼ばれた --jq の式を本物の jq で当てて返す。**YAML に書いた
#           jq の式もそのまま確かめる。** status の投稿（POST statuses）は state を
#           記録するだけ
#   sleep … 何もしない（猶予の 300 秒を待たない）
#
# 回すのは pull_request の経路と、掃き寄せ（schedule）の経路である。掃き寄せは同じ judge を
# 呼ぶので、ここで見るのは「判定するか、見送るか」の分かれ目（push の時刻の採り方）だけ。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-second-opinion-gate-workflow"

WORKFLOW="$REPO_ROOT/.github/workflows/second-opinion-gate.yml"

it "ワークフロー定義が存在する"
if [[ -f "$WORKFLOW" ]]; then
  pass
else
  fail "見つからない: $WORKFLOW"
fi

command -v jq >/dev/null 2>&1 || { echo "error: jq がありません" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/so-gate-wf.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# run: | の本文を取り出す（ステップは 1 つだけで、本文は 10 桁の字下げ）。
awk '/^        run: \|/{f=1;next} f{ if ($0 ~ /^[^ ]/) exit; sub(/^          /,""); print }' \
  "$WORKFLOW" > "$WORK/run.sh"

it "run の本文を取り出せる（judge / is_exempt を含む）"
if grep -q '^judge() {' "$WORK/run.sh" && grep -q '^is_exempt() {' "$WORK/run.sh"; then
  pass
else
  fail "run の本文を取り出せなかった（case ラベルや run: | の書式が変わった可能性）"
fi

mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
# 偽の gh。FIXTURES の JSON に --jq の式を当てて返す。
set -euo pipefail
path="" expr="" method="GET" state=""
while [ $# -gt 0 ]; do
  case "$1" in
    api|--paginate) ;;
    --jq) expr="$2"; shift ;;
    --method) method="$2"; shift ;;
    -f) case "$2" in state=*) state="${2#state=}" ;; esac; shift ;;
    repos/*) path="$1" ;;
  esac
  shift
done
if [ "$method" = "POST" ]; then
  echo "$state" >> "$FIXTURES/statuses"
  exit 0
fi
case "$path" in
  */pulls\?*) file=pulls.json ;;
  */commits/*/check-runs) file=checkruns.json ;;
  */pulls/*/commits) file=commits.json ;;
  */pulls/*) file=pr.json ;;
  */issues/*/comments) file=comments.json ;;
  *) echo "gh stub: 知らない path: $path" >&2; exit 1 ;;
esac
[ -f "$FIXTURES/$file" ] || exit 1
jq -r "$expr" "$FIXTURES/$file"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/sleep"
chmod +x "$WORK/bin/gh" "$WORK/bin/sleep"

SHA=0123456789abcdef0123456789abcdef01234567

# commit <author> <committer> <verified>
commit() { printf '{"author":{"login":"%s"},"committer":{"login":"%s"},"commit":{"verification":{"verified":%s}}}' "$1" "$2" "$3"; }

# record_comment <login> <author_association> [sha]
# 記録のコメントは本物の API と同じく、書き手の login と author_association を持つ（#370）。
record_comment() { printf '{"user":{"login":"%s"},"author_association":"%s","body":"<!-- second-opinion sha=%s -->\\nLGTM"}' "$1" "$2" "${3:-$SHA}"; }

# case <名前> <期待する status（無しは none）> <PR の著者> <記録があるか> <コミットの JSON...>
#
# <記録があるか> は次のいずれか:
#   no           … 記録が無い
#   yes          … PR の作者自身の記録がある
#   stranger     … 無関係な人（author_association=NONE）の印つきコメントだけがある
#   collaborator … PR の作者ではない協力者（author_association=COLLABORATOR）の
#                  印つきコメントだけがある（#370: 数えるのは作者自身の記録だけ）
#   both         … stranger の印つきコメントと、作者自身の記録が混在する
case_() {
  local name="$1" want="$2" author="$3" recorded="$4"; shift 4
  local fx="$WORK/fx" got
  rm -rf "$fx"; mkdir -p "$fx"
  printf '{"user":{"login":"%s"},"draft":false,"head":{"sha":"%s"}}' "$author" "$SHA" > "$fx/pr.json"
  local IFS=,; printf '[%s]' "$*" > "$fx/commits.json"; unset IFS
  case "$recorded" in
    yes) printf '[%s]' "$(record_comment "$author" OWNER)" > "$fx/comments.json" ;;
    stranger) printf '[%s]' "$(record_comment mallory NONE)" > "$fx/comments.json" ;;
    collaborator) printf '[%s]' "$(record_comment helper COLLABORATOR)" > "$fx/comments.json" ;;
    both) printf '[%s,%s]' "$(record_comment mallory NONE)" "$(record_comment "$author" OWNER)" > "$fx/comments.json" ;;
    *) printf '[{"user":{"login":"%s"},"author_association":"OWNER","body":"関係ないコメント"}]' "$author" > "$fx/comments.json" ;;
  esac
  ( cd "$REPO_ROOT" && PATH="$WORK/bin:$PATH" FIXTURES="$fx" GH_TOKEN=x REPO=o/r EVENT=pull_request \
      PR_NUMBER=1 TRIGGER_SHA="$SHA" RUN_URL=u bash "$WORK/run.sh" ) >"$fx/out" 2>&1 || true
  got="$(cat "$fx/statuses" 2>/dev/null || echo none)"
  it "$name"
  if [[ "$got" == "$want" ]]; then
    pass
  else
    fail "want=$want got=$(echo "$got" | tr '\n' ' ')"
  fi
  # 作者以外が書いた印つきコメントがあるときは、判定が変わらなくても ::warning:: が出る
  # （#370。stranger / collaborator / both のいずれも、数えない印が存在する）。
  local want_warn=no got_warn=no
  case "$recorded" in stranger|collaborator|both) want_warn=yes ;; esac
  grep -q '以外が書いたもの、または書き手の立場が COLLABORATOR 未満' "$fx/out" && got_warn=yes
  it "$name（作者以外の印の警告）"
  if [[ "$got_warn" == "$want_warn" ]]; then
    pass
  else
    fail "警告 want=$want_warn got=$got_warn"
  fi
}

DEP='dependabot[bot]'
case_ "Dependabot の PR は記録が無くても success" success "$DEP" no \
  "$(commit "$DEP" web-flow true)"
case_ "人の PR で記録が無ければ failure" failure someone no \
  "$(commit someone someone false)"
case_ "人の PR で記録があれば success" success someone yes \
  "$(commit someone someone false)"
case_ "Dependabot の PR に人のコミットが混ざり記録が無ければ failure" failure "$DEP" no \
  "$(commit "$DEP" web-flow true)" "$(commit someone someone false)"
# author は作る側が書ける。GitHub の署名が無ければ Dependabot 名義でも信じない。
case_ "Dependabot 名義でも署名が無ければ failure" failure "$DEP" no \
  "$(commit "$DEP" web-flow true)" "$(commit "$DEP" someone false)"
case_ "Dependabot 名義で committer が web-flow でも未検証なら failure" failure "$DEP" no \
  "$(commit "$DEP" web-flow false)"

# 記録の書き手（#370）。public なので誰でも印つきのコメントを書ける。数えるのは
# PR の作者自身の記録だけである。
case_ "PR の作者以外（無関係な人）が書いた印だけなら failure" failure someone stranger \
  "$(commit someone someone false)"
case_ "PR の作者以外の協力者が書いた印だけでも failure（作者自身の記録だけを数える）" failure someone collaborator \
  "$(commit someone someone false)"
case_ "作者自身の記録があれば、他人の印が混ざっていても success" success someone both \
  "$(commit someone someone false)"

# SHA が変わったら古いコメントで通らないこと（#361 の受け入れ条件）。記録の印は
# 直前の head（OLD_SHA）に紐づいており、いまの head（SHA）とは一致しない。
OLD_SHA=fedcba9876543210fedcba9876543210fedcba9
it "SHA が変わった PR は古いコメントでは success にならない"
fx="$WORK/fx"
rm -rf "$fx"; mkdir -p "$fx"
printf '{"user":{"login":"someone"},"draft":false,"head":{"sha":"%s"}}' "$SHA" > "$fx/pr.json"
printf '[%s]' "$(commit someone someone false)" > "$fx/commits.json"
# 書き手は PR の作者自身（someone/OWNER）にする。ここで見たいのは SHA の不一致だけで、
# 作者の条件（#370）に引っかけて意図とは別の理由で failure にしない。
printf '[%s]' "$(record_comment someone OWNER "$OLD_SHA")" > "$fx/comments.json"
( cd "$REPO_ROOT" && PATH="$WORK/bin:$PATH" FIXTURES="$fx" GH_TOKEN=x REPO=o/r EVENT=pull_request \
    PR_NUMBER=1 TRIGGER_SHA="$SHA" RUN_URL=u bash "$WORK/run.sh" ) >/dev/null 2>&1 || true
got="$(cat "$fx/statuses" 2>/dev/null || echo none)"
if [[ "$got" == failure ]]; then
  pass
else
  fail "want=failure got=$(echo "$got" | tr '\n' ' ')"
fi

# ── 掃き寄せ（schedule）──────────────────────────────────────────────────────
# sweep_case <名前> <期待する status> <check-run の開始時刻（無しは空）> <PR の更新時刻>
# 記録は付けない。判定されれば failure、見送られれば none になる。
sweep_case() {
  local name="$1" want="$2" started="$3" updated="$4" fx="$WORK/fx" got
  rm -rf "$fx"; mkdir -p "$fx"
  printf '[{"number":1,"draft":false,"updated_at":"%s","head":{"sha":"%s","repo":{"full_name":"o/r"}}}]' \
    "$updated" "$SHA" > "$fx/pulls.json"
  if [[ -n "$started" ]]; then
    printf '{"check_runs":[{"started_at":"%s"}]}' "$started" > "$fx/checkruns.json"
  else
    printf '{"check_runs":[]}' > "$fx/checkruns.json"
  fi
  printf '{"user":{"login":"someone"},"draft":false,"head":{"sha":"%s"}}' "$SHA" > "$fx/pr.json"
  printf '[%s]' "$(commit someone someone false)" > "$fx/commits.json"
  printf '[{"body":"関係ないコメント"}]' > "$fx/comments.json"
  ( cd "$REPO_ROOT" && PATH="$WORK/bin:$PATH" FIXTURES="$fx" GH_TOKEN=x REPO=o/r EVENT=schedule \
      PR_NUMBER= TRIGGER_SHA= RUN_URL=u bash "$WORK/run.sh" ) >/dev/null 2>&1 || true
  got="$(cat "$fx/statuses" 2>/dev/null || echo none)"
  it "$name"
  if [[ "$got" == "$want" ]]; then
    pass
  else
    fail "want=$want got=$(echo "$got" | tr '\n' ' ')"
  fi
}

OLD_TIME="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
NOW_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sweep_case "掃き寄せ: check-run が猶予より前に始まっていれば判定する" failure "$OLD_TIME" "$OLD_TIME"
# CI の無いプロジェクトや [skip ci] の push では check-run が 1 つも付かない。飛ばし続けると、
# 掃き寄せが永久に判定しない（PR #365 の Copilot の指摘）。
sweep_case "掃き寄せ: check-run が無くても、PR の更新が猶予より前なら判定する" failure "" "$OLD_TIME"
sweep_case "掃き寄せ: check-run が無く、PR の更新が直近なら見送る" none "" "$NOW_TIME"

exit_with_result
