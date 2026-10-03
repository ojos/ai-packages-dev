#!/usr/bin/env bash
# 並行セッションの共有台帳（scripts/session-ledger.sh）を、模擬のセッション 2 本で検証する。
#
# 検証するのは台帳そのもの（登録・解放・失効・衝突の判定と出力）で、フックの判定ではない。
# フック（scripts/session-coord-hook.sh）は、この台帳の check の出力を読んで拒否・警告を
# 決める。ここで固めるのは、フックが読む出力の形である。
#
#   (a) 同じ issue を claim すると、2 本目は警告を出して通る
#   (f) 持ち主の PID が消えた登録は失効し、通る
#   (g) 自分のセッションの登録では止まらない
#   (h) 台帳が壊れていても、警告を出して通る
#   (i) 拒否・警告の出力に、相手セッションの識別子・登録の種類・調整の手順が含まれる
#   (k) 相手が release した後は、同じ操作が通る
#   ほか: 種類ごとの止める強さ、作業ツリーをまたぐ共有、追記のみ、セッションごとの別ファイル
#
# セッションは SESSION_LEDGER_ID と SESSION_LEDGER_PID で模擬する。bash 3.2 互換。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-session-ledger"

# ── 生成物として独立していること ──────────────────────────────────────────────

out="$(new_workdir)/out"
run_bootstrap "$out" >/dev/null 2>&1
LEDGER="$out/scripts/session-ledger.sh"

it "session-ledger.sh が装備フラグ無しでも生成され、実行可能である"
if [[ -f "$LEDGER" ]]; then assert_mode "$LEDGER" "755"; else fail "生成されていない: $LEDGER"; fi

it "構文が正しい"
if bash -n "$LEDGER" 2>/dev/null; then pass; else fail "syntax error"; fi

# ── フィクスチャ: 共通ディレクトリを共有する 2 つの作業ツリー ─────────────────

repo="$(new_workdir)/repo"
wt2="$(dirname "$repo")/wt2"
mkdir -p "$repo"
(
  cd "$repo" || exit 1
  git init -q . 2>/dev/null
  git config user.name test
  git config user.email test@example.com
  git config commit.gpgsign false
  echo x > f.txt
  git add f.txt
  git commit -q -m init
  git worktree add -q "$wt2" -b other 2>/dev/null
) >/dev/null 2>&1

# 生きている持ち主の代わりになるプロセス（模擬セッション 2 本ぶん）。
sleep 600 &
PID_A=$!
sleep 600 &
PID_B=$!
cleanup() { kill "$PID_A" "$PID_B" "${PID_C:-}" 2>/dev/null || true; }
trap cleanup EXIT

# run <セッション> <作業ツリー> <引数...>。標準出力・標準エラーをまとめ、終了コードは RC へ。
RC=0
run() {
  local sid="$1" dir="$2" pid; shift 2
  case "$sid" in
    s-a) pid="$PID_A" ;;
    s-b) pid="$PID_B" ;;
    *) pid="${PID_C:-$PID_B}" ;;
  esac
  OUT="$(cd "$dir" && SESSION_LEDGER_ID="$sid" SESSION_LEDGER_PID="$pid" bash "$LEDGER" "$@" 2>&1)"
  RC=$?
}

first_line() { printf '%s\n' "$OUT" | sed -n 1p; }

# 台帳の置き場所（共通ディレクトリの配下）
COMMON="$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd)"
DIR="$COMMON/session-ledger"

# ── (a) 同じ issue ───────────────────────────────────────────────────────────

it "(a) 先に claim したセッションは LEDGER_OK で登録できる"
run s-a "$repo" claim issue 395
assert_eq "$(first_line)" "LEDGER_OK" "判定"

it "(a) 2 本目が同じ issue を claim すると、警告を出して通る（終了コード 0）"
run s-b "$repo" claim issue '#395'
if [[ "$RC" -eq 0 && "$(first_line)" == "LEDGER_WARN" ]]; then pass; else fail "rc=$RC out=$OUT"; fi

it "(a) 警告の種類が違えば（別の issue）衝突しない"
run s-b "$repo" check issue 396
assert_eq "$(first_line)" "LEDGER_OK" "判定"

# ── (i) 出力の中身 ───────────────────────────────────────────────────────────

run s-b "$repo" check issue 395
it "(i) 警告の出力に相手セッションの識別子が含まれる"
assert_contains "$OUT" "session=s-a" "出力"
it "(i) 警告の出力に登録の種類が含まれる"
assert_contains "$OUT" "kind=issue" "出力"
it "(i) 警告の出力に対象と持ち主の PID・作業ツリーが含まれる"
case "$OUT" in
  *"target=395"*"pid=$PID_A"*"worktree="*) pass ;;
  *) fail "出力: $OUT" ;;
esac
it "(i) 調整の手順（Claude Code の手段と、それ以外の実行環境の手段）が含まれる"
case "$OUT" in
  *"coordinate"*"ListAgents"*"SendMessage"*"利用者"*) pass ;;
  *) fail "出力: $OUT" ;;
esac

# ── (g) 自分の登録では止まらない ──────────────────────────────────────────────

it "(g) 自分のセッションの登録は衝突として扱わない（拒否の種類でも止まらない）"
run s-a "$repo" claim merge
run s-a "$repo" check merge
mine="$(first_line)"
run s-a "$repo" claim issue 500
run s-a "$repo" check issue 500
if [[ "$mine" == "LEDGER_OK" && "$RC" -eq 0 && "$(first_line)" == "LEDGER_OK" ]]; then pass; else fail "merge=$mine issue=$OUT"; fi
run s-a "$repo" release merge

# ── 種類ごとの止める強さ ──────────────────────────────────────────────────────

it "merge: 相手が登録している間、check は LEDGER_DENY・終了コード 3"
run s-a "$repo" claim merge
run s-b "$repo" check merge
if [[ "$RC" -eq 3 && "$(first_line)" == "LEDGER_DENY" ]]; then pass; else fail "rc=$RC out=$OUT"; fi

it "merge: 拒否の出力に相手の識別子・種類・調整の手順が含まれる（(i)）"
case "$OUT" in
  *"session=s-a"*"kind=merge"*"coordinate"*) pass ;;
  *) fail "出力: $OUT" ;;
esac

it "merge: 拒否される間は claim できず、登録も作らない"
run s-b "$repo" claim merge
before="$(grep -c . "$DIR/s-b.tsv" 2>/dev/null || echo 0)"
if [[ "$RC" -eq 3 && "$(first_line)" == "LEDGER_DENY" ]] && ! grep -q "$(printf '\tmerge\t')" "$DIR/s-b.tsv"; then
  pass
else
  fail "rc=$RC before=$before out=$OUT"
fi

it "gate: 重いゲートも相手が登録している間は拒否される"
run s-a "$repo" claim gate
run s-b "$repo" check gate
assert_eq "$RC" "3" "終了コード"

it "doc: 相手が登録している文書は警告して通る。作業ツリーの絶対パスは相対へ直して照合する"
run s-a "$repo" claim doc docs/design.md
run s-b "$repo" check doc "$repo/docs/design.md"
if [[ "$RC" -eq 0 && "$(first_line)" == "LEDGER_WARN" ]]; then pass; else fail "rc=$RC out=$OUT"; fi

it "doc: 末尾が / の登録は配下の文書に効く"
run s-a "$repo" claim doc docs/guide/
run s-b "$repo" check doc docs/guide/intro.md
assert_eq "$(first_line)" "LEDGER_WARN" "判定"

it "doc: 別の文書は衝突しない"
run s-b "$repo" check doc docs/other.md
assert_eq "$(first_line)" "LEDGER_OK" "判定"

# ── 作業ツリーの扱い ──────────────────────────────────────────────────────────

it "git: 同じ作業ツリーでの git 操作は拒否される（対象を省くと現在の作業ツリー）"
run s-a "$repo" claim git
run s-b "$repo" check git
if [[ "$RC" -eq 3 && "$(first_line)" == "LEDGER_DENY" ]]; then pass; else fail "rc=$RC out=$OUT"; fi

it "git: 別の作業ツリーでの git 操作は衝突しない"
run s-b "$wt2" check git
assert_eq "$(first_line)" "LEDGER_OK" "判定"

it "作業ツリーをまたいで台帳を共有する（別の作業ツリーから相手の登録が見える）"
run s-b "$wt2" check merge
assert_eq "$(first_line)" "LEDGER_DENY" "判定"

it "台帳は共通ディレクトリの配下にあり、セッションごとに別のファイルである"
if [[ -f "$DIR/s-a.tsv" && -f "$DIR/s-b.tsv" ]]; then pass; else fail "$(ls "$DIR" 2>&1)"; fi

# ── list ──────────────────────────────────────────────────────────────────────

it "list --others は自分以外の登録だけを出す"
run s-b "$repo" list --others
case "$OUT" in
  *"session=s-a"*) if [[ "$OUT" == *"session=s-b"* ]]; then fail "自分の登録が混ざる: $OUT"; else pass; fi ;;
  *) fail "出力: $OUT" ;;
esac

# ── (k) release 後は通る ─────────────────────────────────────────────────────

it "追記のみ: release は既存の行を書き換えず、解放の行を足す"
head_before="$(cat "$DIR/s-a.tsv")"
lines_before="$(grep -c . "$DIR/s-a.tsv")"
run s-a "$repo" release merge
lines_after="$(grep -c . "$DIR/s-a.tsv")"
case "$(cat "$DIR/s-a.tsv")" in
  "$head_before"*) [[ "$lines_after" -eq $((lines_before + 1)) ]] && pass || fail "行数 $lines_before -> $lines_after" ;;
  *) fail "既存の行が変わった" ;;
esac

it "(k) 相手が merge を release した後は、同じ操作が通る"
run s-b "$repo" check merge
assert_eq "$(first_line)" "LEDGER_OK" "判定"

it "(k) 引数なしの release は自分の登録をすべて解放する"
run s-a "$repo" release
run s-b "$repo" check git
first="$(first_line)"
run s-b "$repo" check gate
if [[ "$first" == "LEDGER_OK" && "$(first_line)" == "LEDGER_OK" ]]; then pass; else fail "git=$first gate=$(first_line)"; fi

it "(k) 解放した後に再度 claim できる"
run s-a "$repo" claim merge
assert_eq "$(first_line)" "LEDGER_OK" "判定"
run s-a "$repo" release merge

# ── (f) 失効 ─────────────────────────────────────────────────────────────────

it "(f) 持ち主の PID が消えた登録は失効し、通る"
sleep 600 &
PID_C=$!
run s-c "$repo" claim merge
run s-b "$repo" check merge
denied="$(first_line)"
kill "$PID_C" 2>/dev/null
wait "$PID_C" 2>/dev/null
run s-b "$repo" check merge
if [[ "$denied" == "LEDGER_DENY" && "$(first_line)" == "LEDGER_OK" ]]; then pass; else fail "消える前=$denied 消えた後=$OUT"; fi

it "(f) 失効した登録は list に出ず、list --all では expired と示される"
run s-b "$repo" list
plain="$OUT"
run s-b "$repo" list --all
if [[ "$plain" != *"session=s-c"* ]] && printf '%s\n' "$OUT" | grep 'session=s-c' | grep -c 'state=expired' >/dev/null; then
  pass
else
  fail "list=$plain all=$OUT"
fi

it "(f) PID が生きていても、最後の更新から TTL を超えた登録は失効する"
old=$(( $(date +%s) - 100000 ))
printf '%s\tclaim\tmerge\t-\t%s\t%s\n' "$old" "$PID_A" "$repo" > "$DIR/s-old.tsv"
run s-b "$repo" check merge
assert_eq "$(first_line)" "LEDGER_OK" "判定"
rm -f "$DIR/s-old.tsv"

# ── (h) 台帳が壊れていても通る ────────────────────────────────────────────────

it "(h) 壊れた行は警告して読み飛ばし、判定は続ける"
printf 'これは台帳の行ではない\n\001\002 garbage\n' > "$DIR/s-broken.tsv"
run s-a "$repo" claim doc docs/x.md
run s-b "$repo" check doc docs/x.md
case "$OUT" in
  *WARN*壊れた行*) pass ;;
  *) fail "警告が無い: $OUT" ;;
esac
it "(h) 壊れた行があっても、他セッションの正しい登録は効く"
assert_contains "$OUT" "LEDGER_WARN" "判定"
rm -f "$DIR/s-broken.tsv"

it "(h) 台帳の置き場所を作れないときは、警告を出して通す（LEDGER_SKIP・終了コード 0）"
blocker="$(new_workdir)/not-a-dir"
: > "$blocker"
OUT="$(cd "$repo" && SESSION_LEDGER_DIR="$blocker/ledger" SESSION_LEDGER_ID=s-a SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" check merge 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]] && printf '%s' "$OUT" | grep -q 'WARN' && printf '%s' "$OUT" | grep -q 'LEDGER_SKIP'; then pass; else fail "rc=$RC out=$OUT"; fi

it "(h) claim も、置き場所を作れないときは警告を出して通す"
OUT="$(cd "$repo" && SESSION_LEDGER_DIR="$blocker/ledger" SESSION_LEDGER_ID=s-a SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" claim merge 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]] && printf '%s' "$OUT" | grep -q 'LEDGER_SKIP'; then pass; else fail "rc=$RC out=$OUT"; fi

it "(h) git リポジトリの外では、警告を出して通す"
nogit="$(new_workdir)"
OUT="$(cd "$nogit" && GIT_CEILING_DIRECTORIES="$nogit/.." SESSION_LEDGER_ID=s-a SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" check merge 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]] && printf '%s' "$OUT" | grep -q 'LEDGER_SKIP'; then pass; else fail "rc=$RC out=$OUT"; fi

# ── 識別子と使い方 ────────────────────────────────────────────────────────────

it "識別子を渡さないときは pid-<持ち主の PID> になる"
OUT="$(cd "$repo" && SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" claim issue 777 2>&1)"
assert_contains "$OUT" "session=pid-$PID_A" "出力"
OUT="$(cd "$repo" && SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" release 2>&1)"

it "識別子に使えない文字は _ になる（ファイル名として安全）"
run "a/b c" "$repo" claim issue 778
if [[ -f "$DIR/a_b_c.tsv" ]]; then pass; else fail "$(ls "$DIR")"; fi
run "a/b c" "$repo" release

it "不明な種類と不明なサブコマンドは使い方の誤り（終了コード 2）"
run s-a "$repo" claim nothing
rc1="$RC"
run s-a "$repo" frobnicate
if [[ "$rc1" -eq 2 && "$RC" -eq 2 ]]; then pass; else fail "rc=$rc1,$RC"; fi

exit_with_result
