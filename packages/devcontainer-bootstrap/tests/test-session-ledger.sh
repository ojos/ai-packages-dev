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
#   ほか: 種類ごとの止める強さ、作業ツリーをまたぐ共有、追記のみ、セッションごとの別ファイル、
#         更新（refresh）
#
# セッションは SESSION_LEDGER_ID と SESSION_LEDGER_PID で模擬する。bash 3.2 互換。

set -uo pipefail

# run-tests.sh を介さず直接実行されたときは、自前で一時領域を作って後で消す
# （受け入れ条件は `bash tests/test-session-ledger.sh` が 0 で終わること）。
OWN_TMP_ROOT=""
if [[ -z "${TEST_TMP_ROOT:-}" ]]; then
  TEST_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dcb-session-ledger-test.XXXXXX")"
  export TEST_TMP_ROOT
  OWN_TMP_ROOT="$TEST_TMP_ROOT"
fi
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
cleanup() {
  kill "$PID_A" "$PID_B" "${PID_C:-}" "${ODD_PID:-}" 2>/dev/null || true
  [[ -z "$OWN_TMP_ROOT" ]] || rm -rf "$OWN_TMP_ROOT"
}
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

TAB_CHAR="$(printf '\t')"

# 台帳とは別に求めた、持ち主の開始時刻のキー（試験の期待値）。/proc があれば stat の
# 22 列目（プロセス名の後ろの ") " から数えて 20 番目）、無ければ TZ と言語を固定した
# lstart の cksum。
start_key() { # pid
  if [[ -r "/proc/$1/stat" ]]; then
    sed 's/.*) //' "/proc/$1/stat" | awk '{ print $20 }'
  else
    # 台帳と同じく、コマンド置換で末尾の改行を落としてから cksum へ渡す。
    local lstart
    lstart="$(TZ=UTC LC_ALL=C ps -o lstart= -p "$1")"
    printf '%s' "$lstart" | cksum | cut -d" " -f1
  fi
}

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
if [[ "$RC" -eq 0 ]] && printf '%s' "$OUT" | grep 'WARN' >/dev/null && printf '%s' "$OUT" | grep 'LEDGER_SKIP' >/dev/null; then pass; else fail "rc=$RC out=$OUT"; fi

it "(h) claim も、置き場所を作れないときは警告を出して通す"
OUT="$(cd "$repo" && SESSION_LEDGER_DIR="$blocker/ledger" SESSION_LEDGER_ID=s-a SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" claim merge 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]] && printf '%s' "$OUT" | grep 'LEDGER_SKIP' >/dev/null; then pass; else fail "rc=$RC out=$OUT"; fi

it "(h) git リポジトリの外では、警告を出して通す"
nogit="$(new_workdir)"
OUT="$(cd "$nogit" && GIT_CEILING_DIRECTORIES="$nogit/.." SESSION_LEDGER_ID=s-a SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" check merge 2>&1)"
RC=$?
if [[ "$RC" -eq 0 ]] && printf '%s' "$OUT" | grep 'LEDGER_SKIP' >/dev/null; then pass; else fail "rc=$RC out=$OUT"; fi

# ── 更新（長いセッションの失効を避ける）──────────────────────────────────────

it "refresh: 最後の更新から一定時間たっていれば、生きている登録を claim し直して更新時刻を新しくする"
old=$(( $(date +%s) - 1000 ))
printf '%s\tclaim\tissue\t900\t%s\t%s\n' "$old" "$PID_A" "$repo" > "$DIR/s-r.tsv"
before="$(grep -c . "$DIR/s-r.tsv")"
(cd "$repo" && SESSION_LEDGER_ID=s-r SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" refresh >/dev/null 2>&1)
after="$(grep -c . "$DIR/s-r.tsv")"
run s-b "$repo" list
age="$(printf '%s\n' "$OUT" | sed -n 's/.*session=s-r.*age=\([0-9]*\)s.*/\1/p' | sed -n 1p)"
if [[ "$before" -eq 1 && "$after" -eq 2 && -n "$age" && "$age" -lt 100 ]]; then pass; else fail "行数 $before -> $after age=$age"; fi

it "refresh: 更新したばかりなら何も足さない（台帳が膨らまない）"
(cd "$repo" && SESSION_LEDGER_ID=s-r SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" refresh >/dev/null 2>&1)
assert_eq "$(grep -c . "$DIR/s-r.tsv")" "2" "行数"

it "refresh: 解放した登録は更新しない（生きている登録が無ければ何も足さない）"
(cd "$repo" && SESSION_LEDGER_ID=s-r SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" release >/dev/null 2>&1)
printf '%s\trelease\t*\t*\t%s\t%s\n' "$old" "$PID_A" "$repo" >> "$DIR/s-r.tsv"
n1="$(grep -c . "$DIR/s-r.tsv")"
(cd "$repo" && SESSION_LEDGER_ID=s-r SESSION_LEDGER_PID="$PID_A" SESSION_LEDGER_REFRESH_MIN=0 bash "$LEDGER" refresh >/dev/null 2>&1)
assert_eq "$(grep -c . "$DIR/s-r.tsv")" "$n1" "行数"
rm -f "$DIR/s-r.tsv"

it "refresh: 台帳の置き場所を作れなくても、警告を出して終了コード 0"
OUT="$(cd "$repo" && SESSION_LEDGER_DIR="$blocker/ledger" SESSION_LEDGER_ID=s-a SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" refresh 2>&1)"
RC=$?
if [[ "$RC" -eq 0 && "$OUT" == *WARN* ]]; then pass; else fail "rc=$RC out=$OUT"; fi

# ── 識別子と使い方 ────────────────────────────────────────────────────────────

it "識別子を渡さないときは pid-<持ち主の PID> になる"
OUT="$(cd "$repo" && SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" claim issue 777 2>&1)"
assert_contains "$OUT" "session=pid-$PID_A" "出力"
OUT="$(cd "$repo" && SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" release 2>&1)"

it "識別子に使えない文字は _ になる（ファイル名として安全）"
run "a/b c" "$repo" claim issue 778
# 置き換えが起きたので、元の識別子の cksum が付く（別の識別子と同じファイルにならないように）。
if ls "$DIR"/a_b_c-*.tsv >/dev/null 2>&1; then pass; else fail "$(ls "$DIR")"; fi
run "a/b c" "$repo" release

# (f) で PID_C を消したので、生きている持ち主を用意し直す。
sleep 600 &
PID_C=$!

it "識別子の置き換えで別の識別子が同じファイルにならない（a/b と a_b）"
run "a/b" "$repo" claim doc docs/slash.md
run "a_b" "$repo" check doc docs/slash.md
slash_out="$OUT"
run "a/b" "$repo" release
run "a_b" "$repo" release
if [[ "$(printf '%s\n' "$slash_out" | head -1)" == "LEDGER_WARN" ]]; then
  pass
else
  fail "a/b の登録が a_b と同じファイルに混ざった: $slash_out"
fi

it "先頭が . の識別子でも、登録が隠しファイルにならず、別のセッションから見える"
run ".agent" "$repo" claim merge
dot_out_check() { run s-b "$repo" check merge; }
dot_out_check
dot_out="$OUT"
run ".agent" "$repo" release
dot_hidden=0
for f in "$DIR"/.agent*; do [[ -e "$f" ]] && dot_hidden=1; done
if [[ "$(printf '%s\n' "$dot_out" | sed -n 1p)" == "LEDGER_DENY" && "$dot_hidden" == 0 ]]; then
  pass
else
  fail "先頭が . の識別子の登録を、別のセッションが見つけられない: $dot_out / $(ls -a "$DIR")"
fi

it "置き換えが起きない識別子のファイル名は変わらない"
run "plain-id.1" "$repo" claim issue 779
if [[ -f "$DIR/plain-id.1.tsv" ]]; then pass; else fail "$(ls "$DIR")"; fi
run "plain-id.1" "$repo" release

it "doc: 先に個別ファイルが登録されていても、別のセッションの配下ディレクトリの確認が衝突になる"
run s-a "$repo" claim doc docs/sym/a.md
run s-b "$repo" check doc docs/sym/
sym1="$(first_line)"
run s-a "$repo" release
run s-a "$repo" claim doc docs/sym/
run s-b "$repo" check doc docs/sym/a.md
sym2="$(first_line)"
run s-a "$repo" release
if [[ "$sym1" == "LEDGER_WARN" && "$sym2" == "LEDGER_WARN" ]]; then pass; else fail "個別→配下=$sym1 配下→個別=$sym2"; fi

it "持ち主を特定できないときは、識別子を共有せず、警告を出して LEDGER_SKIP で通す"
# 持ち主を特定できない状況（PID 1 へ落ちる場合など）を、読み込んだあとで識別子を空にして作る。
lines_before="$(cat "$DIR"/*.tsv | grep -c .)"
# shellcheck disable=SC1090,SC2034  # 生成物を読み込み、SELF_ID は読み込んだ関数が使う
OUT="$(cd "$repo" && . "$LEDGER" && SELF_ID="" && { cmd_claim merge; echo "rc=$?"; cmd_check merge; echo "rc=$?"; cmd_release; echo "rc=$?"; } 2>&1)"
skip_n="$(printf '%s\n' "$OUT" | grep -c '^LEDGER_SKIP$')"
if [[ "$skip_n" -eq 2 ]] && printf '%s' "$OUT" | grep 'WARN' >/dev/null && ! printf '%s' "$OUT" | grep 'rc=[1-9]' >/dev/null \
   && [[ "$(cat "$DIR"/*.tsv | grep -c .)" -eq "$lines_before" ]]; then
  pass
else
  fail "出力: $OUT"
fi

it "git: 明示した作業ツリーのパスを実体の絶対パスへ揃える（. や末尾の / や symlink 経由でも同じ作業ツリー）"
run s-a "$repo" claim git
run s-b "$repo" check git .
n1="$(first_line)"
run s-b "$repo" check git "$repo/./"
n2="$(first_line)"
ln -s "$repo" "$(dirname "$repo")/repo-link"
run s-b "$repo" check git "$(dirname "$repo")/repo-link"
n3="$(first_line)"
run s-b "$wt2" check git "$repo/../repo"
n4="$(first_line)"
run s-a "$repo" release
if [[ "$n1" == "LEDGER_DENY" && "$n2" == "LEDGER_DENY" && "$n3" == "LEDGER_DENY" && "$n4" == "LEDGER_DENY" ]]; then pass; else fail ". =$n1 /./=$n2 symlink=$n3 ..=$n4"; fi

it "git: 作業ツリーの下の階層を対象にしても、作業ツリーのルートへ揃えて照合する"
mkdir -p "$repo/sub/deeper"
run s-a "$repo" claim git
run s-b "$repo/sub" check git .
g1="$(first_line)"
run s-b "$repo" check git "$repo/sub/deeper"
g2="$(first_line)"
run s-a "$repo" release
run s-a "$repo/sub" claim git .
run s-b "$repo" check git
g3="$(first_line)"
run s-a "$repo" release
if [[ "$g1" == "LEDGER_DENY" && "$g2" == "LEDGER_DENY" && "$g3" == "LEDGER_DENY" ]]; then pass; else fail "sub=$g1 deeper=$g2 逆=$g3"; fi

it "doc: . と .. を含む表記を正規化して照合する（存在しないファイルでも）"
run s-a "$repo" claim doc docs/norm.md
run s-b "$repo" check doc docs/sub/../norm.md
d1="$(first_line)"
run s-b "$repo" check doc ./docs/./norm.md
d2="$(first_line)"
run s-b "$repo" check doc "$repo/docs/../docs/norm.md"
d3="$(first_line)"
run s-b "$repo" check doc docs/other.md
d4="$(first_line)"
run s-a "$repo" release
if [[ "$d1" == "LEDGER_WARN" && "$d2" == "LEDGER_WARN" && "$d3" == "LEDGER_WARN" && "$d4" == "LEDGER_OK" ]]; then pass; else fail "$d1 $d2 $d3 $d4"; fi

it "release: 解放の行を書けなかったときは警告し、解放済みと表示せず、残っていることを示す"
mkdir "$DIR/s-rel.tsv"
run s-rel "$repo" release
rel_out="$OUT"
rel_rc="$RC"
rmdir "$DIR/s-rel.tsv"
if [[ "$rel_rc" -eq 0 ]] && printf '%s' "$rel_out" | grep 'WARN' >/dev/null && printf '%s' "$rel_out" | grep 'release-failed' >/dev/null \
   && ! printf '%s' "$rel_out" | grep 'released:' >/dev/null; then
  pass
else
  fail "rc=$rel_rc out=$rel_out"
fi

it "PID の再利用: 同じ PID でも開始時刻が違う登録は失効する。一致する登録は生きている"
key_a="$(start_key "$PID_A")"
now_t="$(date +%s)"
printf '%s\tclaim\tmerge\t-\t%s\t%s\t%s\n' "$now_t" "$PID_A" "$repo" "$((key_a + 1))" > "$DIR/s-reuse.tsv"
run s-b "$repo" check merge
reuse_stale="$(first_line)"
printf '%s\tclaim\tmerge\t-\t%s\t%s\t%s\n' "$now_t" "$PID_A" "$repo" "$key_a" > "$DIR/s-reuse.tsv"
run s-b "$repo" check merge
reuse_live="$(first_line)"
rm -f "$DIR/s-reuse.tsv"
if [[ "$reuse_stale" == "LEDGER_OK" && "$reuse_live" == "LEDGER_DENY" ]]; then pass; else fail "違う開始時刻=$reuse_stale 一致=$reuse_live"; fi

it "既定の識別子に持ち主の開始時刻のキーが入る（pid-<PID>-<キー>）"
OUT="$(cd "$repo" && SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" claim issue 780 2>&1)"
assert_contains "$OUT" "session=pid-$PID_A-$key_a" "出力"
OUT="$(cd "$repo" && SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" release 2>&1)"

it "refresh: 持ち主を特定できないときは、台帳に書かず警告して通す"
lines_before="$(cat "$DIR"/*.tsv | grep -c .)"
# shellcheck disable=SC1090,SC2034  # 生成物を読み込み、SELF_ID は読み込んだ関数が使う
OUT="$(cd "$repo" && . "$LEDGER" && SELF_ID="" && SESSION_LEDGER_REFRESH_MIN=0 && { cmd_refresh; echo "rc=$?"; } 2>&1)"
if [[ "$OUT" == *WARN* && "$OUT" == *"rc=0"* && "$(cat "$DIR"/*.tsv | grep -c .)" -eq "$lines_before" ]]; then pass; else fail "出力: $OUT"; fi

it "不明な種類と不明なサブコマンドは使い方の誤り（終了コード 2）"
run s-a "$repo" claim nothing
rc1="$RC"
run s-a "$repo" frobnicate
if [[ "$rc1" -eq 2 && "$RC" -eq 2 ]]; then pass; else fail "rc=$rc1,$RC"; fi


# ── 呼び出しごとの解放（#425）──────────────────────────────────────────────────

run s-a "$repo" release >/dev/null
run s-b "$repo" release >/dev/null

it "(#425) 同じセッションの同じ種類の登録 2 本のうち 1 本目だけを解放しても、別セッションの check は LEDGER_DENY のまま"
run s-a "$repo" claim --call call-1 merge
run s-a "$repo" claim --call call-2 merge
run s-a "$repo" release --call call-1
run s-b "$repo" check merge
after_first="$(first_line)"
run s-a "$repo" release --call call-2
run s-b "$repo" check merge
after_second="$(first_line)"
if [[ "$after_first" == "LEDGER_DENY" && "$after_second" == "LEDGER_OK" ]]; then pass; else fail "1 本解放後=$after_first 2 本解放後=$after_second"; fi

it "(#425) git は作業ツリーの単位のまま。識別子違いの 2 本のうち 1 本目の解放では、同じ作業ツリーの check は拒否のまま"
run s-a "$repo" claim --call call-1 git "$repo"
run s-a "$repo" claim --call call-2 git "$repo"
run s-a "$repo" release --call call-1
run s-b "$repo" check git "$repo"
git_after_first="$(first_line)"
run s-b "$repo" check git "$wt2"
git_other_wt="$(first_line)"
run s-a "$repo" release --call call-2
run s-b "$repo" check git "$repo"
if [[ "$git_after_first" == "LEDGER_DENY" && "$git_other_wt" == "LEDGER_OK" && "$(first_line)" == "LEDGER_OK" ]]; then pass; else fail "$git_after_first / $git_other_wt / $(first_line)"; fi

it "(#425) 衝突の出力は識別子の違う 2 本でも 1 件にまとまる"
run s-a "$repo" claim --call call-1 merge
run s-a "$repo" claim --call call-2 merge
run s-b "$repo" check merge
conflicts="$(printf '%s\n' "$OUT" | grep -c '^conflict:')"
run s-a "$repo" release >/dev/null
assert_eq "$conflicts" "1" "conflict 行の数"

it "(#425) 識別子付きの解放は、識別子の無い登録を外さない"
run s-a "$repo" claim merge
run s-a "$repo" release --call call-9
run s-b "$repo" check merge
nocall_kept="$(first_line)"
run s-a "$repo" release
assert_eq "$nocall_kept" "LEDGER_DENY" "判定"

it "(#425) 識別子の無い解放は、従来どおり種類と対象の単位で、識別子付きの登録もすべて外す"
run s-a "$repo" claim --call call-1 merge
run s-a "$repo" claim --call call-2 merge
run s-a "$repo" release merge
run s-b "$repo" check merge
assert_eq "$(first_line)" "LEDGER_OK" "判定"

it "(#425) --call と kind を併せて渡すと、その識別子の中で kind / target を絞って解放する"
run s-a "$repo" claim --call call-1 merge
run s-a "$repo" claim --call call-1 gate
run s-a "$repo" release --call call-1 merge
run s-b "$repo" check merge
k_merge="$(first_line)"
run s-b "$repo" check gate
k_gate="$(first_line)"
run s-a "$repo" release
if [[ "$k_merge" == "LEDGER_OK" && "$k_gate" == "LEDGER_DENY" ]]; then pass; else fail "merge=$k_merge gate=$k_gate"; fi

it "(#425) --call のみの解放は、その識別子の登録すべて（種類をまたいで）を外す"
run s-a "$repo" claim --call call-1 merge
run s-a "$repo" claim --call call-1 gate
run s-a "$repo" claim --call call-2 gate
run s-a "$repo" release --call call-1
run s-b "$repo" check merge
c_merge="$(first_line)"
run s-b "$repo" check gate
c_gate="$(first_line)"
run s-a "$repo" release
if [[ "$c_merge" == "LEDGER_OK" && "$c_gate" == "LEDGER_DENY" ]]; then pass; else fail "merge=$c_merge gate=$c_gate"; fi

it "(#425) 識別子付きの台帳の行は 8 列目に識別子を持つ。識別子の無い行は 8 列目が - である"
run s-a "$repo" claim --call call-7 merge
run s-a "$repo" release --call call-7
run s-a "$repo" claim gate
cols="$(awk -F'\t' '{print NF ":" $8}' "$DIR/s-a.tsv" | tail -3 | tr '\n' ' ')"
run s-a "$repo" release
assert_eq "$cols" "8:call-7 8:call-7 8:- " "列数:識別子"

it "(#425) --call の値が欠けている使い方は使い方の誤り（終了コード 2）"
run s-a "$repo" claim --call
rc1="$RC"
run s-a "$repo" release --call
if [[ "$rc1" -eq 2 && "$RC" -eq 2 ]]; then pass; else fail "rc=$rc1,$RC"; fi

it "(#425/#433) 識別子付きの gate の登録は refresh で claim し直さない。識別子付きの解放が効く"
run s-a "$repo" claim --call call-1 gate
n_before="$(grep -c . "$DIR/s-a.tsv")"
SESSION_LEDGER_REFRESH_MIN=0 run s-a "$repo" refresh
n_after="$(grep -c . "$DIR/s-a.tsv")"
run s-a "$repo" release --call call-1
run s-b "$repo" check gate
if [[ "$n_before" -eq "$n_after" && "$(first_line)" == "LEDGER_OK" ]]; then pass; else fail "行数 $n_before -> $n_after 判定=$(first_line)"; fi

it "(#425) 7 列・6 列の古い台帳ファイルを読める。識別子なしの解放で外れる"
now_t="$(date +%s)"
key_a="$(start_key "$PID_A")"
printf '%s\tclaim\tmerge\t-\t%s\t%s\t%s\n' "$now_t" "$PID_A" "$repo" "$key_a" > "$DIR/s-old.tsv"
run s-b "$repo" check merge
old_deny="$(first_line)"
printf '%s\trelease\tmerge\t-\t%s\t%s\t%s\n' "$now_t" "$PID_A" "$repo" "$key_a" >> "$DIR/s-old.tsv"
run s-b "$repo" check merge
old_ok="$(first_line)"
printf '%s\tclaim\tgate\t-\t%s\t%s\n' "$now_t" "$PID_A" "$repo" > "$DIR/s-old.tsv"
run s-b "$repo" check gate
old6="$(first_line)"
rm -f "$DIR/s-old.tsv"
if [[ "$old_deny" == "LEDGER_DENY" && "$old_ok" == "LEDGER_OK" && "$old6" == "LEDGER_DENY" ]]; then pass; else fail "7列=$old_deny→$old_ok 6列=$old6"; fi

it "(#425) 7 列の古い登録と識別子付きの登録が混ざっても、識別子の解放は後者だけを、識別子なしの解放は両方を外す"
printf '%s\tclaim\tmerge\t-\t%s\t%s\t%s\n' "$now_t" "$PID_A" "$repo" "$key_a" > "$DIR/s-old.tsv"
printf '%s\tclaim\tmerge\t-\t%s\t%s\t%s\tcall-1\n' "$now_t" "$PID_A" "$repo" "$key_a" >> "$DIR/s-old.tsv"
printf '%s\trelease\tmerge\t-\t%s\t%s\t%s\tcall-1\n' "$now_t" "$PID_A" "$repo" "$key_a" >> "$DIR/s-old.tsv"
run s-b "$repo" check merge
mixed_after_call="$(first_line)"
printf '%s\trelease\tmerge\t-\t%s\t%s\t%s\n' "$now_t" "$PID_A" "$repo" "$key_a" >> "$DIR/s-old.tsv"
run s-b "$repo" check merge
mixed_after_plain="$(first_line)"
rm -f "$DIR/s-old.tsv"
if [[ "$mixed_after_call" == "LEDGER_DENY" && "$mixed_after_plain" == "LEDGER_OK" ]]; then pass; else fail "識別子の解放後=$mixed_after_call 識別子なしの解放後=$mixed_after_plain"; fi



it "(#425) --call の値が置き換わっても別の識別子になる（a/b の解放で a_b の登録は外れない）"
run s-a "$repo" claim --call 'a/b' merge
run s-a "$repo" claim --call 'a_b' merge
run s-a "$repo" release --call 'a/b'
run s-b "$repo" check merge
slash_kept="$(first_line)"
run s-a "$repo" release --call 'a_b'
run s-b "$repo" check merge
if [[ "$slash_kept" == "LEDGER_DENY" && "$(first_line)" == "LEDGER_OK" ]]; then pass; else fail "a/b の解放後=$slash_kept"; fi
run s-a "$repo" release

it "(#425) --call の値が空文字や - なら使い方の誤り（終了コード 2）で、登録も解放もしない"
run s-a "$repo" claim merge
run s-a "$repo" release --call -
rc_dash="$RC"
run s-a "$repo" release --call ''
rc_empty="$RC"
run s-a "$repo" claim --call - gate
rc_claim="$RC"
run s-b "$repo" check merge
merge_kept="$(first_line)"
run s-b "$repo" check gate
gate_none="$(first_line)"
run s-a "$repo" release
if [[ "$rc_dash" -eq 2 && "$rc_empty" -eq 2 && "$rc_claim" -eq 2 && "$merge_kept" == "LEDGER_DENY" && "$gate_none" == "LEDGER_OK" ]]; then pass; else fail "rc=$rc_dash,$rc_empty,$rc_claim merge=$merge_kept gate=$gate_none"; fi

# ── (#433) 開始時刻のキーと、実行のあいだだけ持つ登録の失効 ──────────────────

if [[ -r "/proc/$PID_A/stat" ]]; then
  it "(#433) /proc を使う経路では、TZ を変えても開始時刻のキー（既定の識別子）が変わらない"
  OUT="$(cd "$repo" && TZ=UTC SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" claim issue 781 2>&1)"
  sid_utc="$(printf '%s\n' "$OUT" | sed -n 's/.*claimed: session=\([^ ]*\).*/\1/p')"
  OUT="$(cd "$repo" && TZ=Asia/Tokyo SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" claim issue 781 2>&1)"
  sid_jst="$(printf '%s\n' "$OUT" | sed -n 's/.*claimed: session=\([^ ]*\).*/\1/p')"
  OUT="$(cd "$repo" && TZ=America/Los_Angeles SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" release 2>&1)"
  if [[ -n "$sid_utc" && "$sid_utc" == "$sid_jst" && "$sid_utc" == "pid-$PID_A-$key_a" ]]; then pass; else fail "UTC=$sid_utc JST=$sid_jst 期待=pid-$PID_A-$key_a"; fi

  it "(#433) プロセス名に空白や括弧があっても、/proc の stat の列を取り違えない"
  odd_dir="$(new_workdir)"
  odd_bin="$odd_dir/a) (b c"
  cp "$(command -v sleep)" "$odd_bin"
  "$odd_bin" 600 >/dev/null 2>&1 &
  ODD_PID=$!
  # shellcheck disable=SC1090  # 生成物を読み込み、関数 proc_start_key を直接呼ぶ
  odd_key="$(cd "$repo" && . "$LEDGER" >/dev/null 2>&1 && proc_start_key "$ODD_PID")"
  case "$(cat "/proc/$ODD_PID/stat")" in
    *"(a) (b c)"*) assert_eq "$odd_key" "$(start_key "$ODD_PID")" "キー" ;;
    *) pass ;;
  esac
  kill "$ODD_PID" 2>/dev/null || true

  it "(#433) 旧版のキー（lstart の cksum）で書かれた生きている持ち主の登録は、失効として扱う"
  # 旧版と同じ求め方（lstart を変数に受けて末尾の改行を落とし、printf '%s' で cksum へ渡す）。
  old_lstart="$(ps -o lstart= -p "$PID_A")"
  old_key="$(printf '%s' "$old_lstart" | cksum | cut -d" " -f1)"
  printf '%s\tclaim\tmerge\t-\t%s\t%s\t%s\n' "$(date +%s)" "$PID_A" "$repo" "$old_key" > "$DIR/s-oldkey.tsv"
  run s-b "$repo" check merge
  rm -f "$DIR/s-oldkey.tsv"
  assert_eq "$(first_line)" "LEDGER_OK" "判定"
fi

it "(#433) refresh は issue の登録を claim し直す。merge / git / gate の登録は claim し直さない"
old=$(( $(date +%s) - 1000 ))
printf '%s\tclaim\tgit\t%s\t%s\t%s\t%s\t-\n' "$old" "$repo" "$PID_A" "$repo" "$key_a" > "$DIR/s-x.tsv"
printf '%s\tclaim\tissue\t433\t%s\t%s\t%s\t-\n' "$old" "$PID_A" "$repo" "$key_a" >> "$DIR/s-x.tsv"
(cd "$repo" && SESSION_LEDGER_ID=s-x SESSION_LEDGER_PID="$PID_A" bash "$LEDGER" refresh >/dev/null 2>&1)
added="$(tail -1 "$DIR/s-x.tsv" | cut -f2,3,4)"
assert_eq "$added" "claim${TAB_CHAR}issue${TAB_CHAR}433" "足した行"

it "(#433) 解放し損ねた git の登録は、refresh で更新が続いても、その登録の時刻から失効する"
SESSION_LEDGER_TTL=500 run s-b "$repo" check git "$repo"
git_verdict="$(first_line)"
SESSION_LEDGER_TTL=500 run s-b "$repo" check issue 433
issue_verdict="$(first_line)"
run s-b "$repo" check git "$repo"
git_default="$(first_line)"
rm -f "$DIR/s-x.tsv"
if [[ "$git_verdict" == "LEDGER_OK" && "$issue_verdict" == "LEDGER_WARN" && "$git_default" == "LEDGER_DENY" ]]; then
  pass
else
  fail "TTL 超えの git=$git_verdict 更新された issue=$issue_verdict TTL 内の git=$git_default"
fi

it "(#433) refresh: 生きている登録が merge / git / gate だけなら何も足さない"
printf '%s\tclaim\tgate\t-\t%s\t%s\t%s\tcall-9\n' "$old" "$PID_A" "$repo" "$key_a" > "$DIR/s-x.tsv"
(cd "$repo" && SESSION_LEDGER_ID=s-x SESSION_LEDGER_PID="$PID_A" SESSION_LEDGER_REFRESH_MIN=0 bash "$LEDGER" refresh >/dev/null 2>&1)
n_gate="$(grep -c . "$DIR/s-x.tsv")"
rm -f "$DIR/s-x.tsv"
assert_eq "$n_gate" "1" "行数"

it "(#433) 同じ git の登録を claim し直せば、その登録の時刻が新しくなる"
printf '%s\tclaim\tgit\t%s\t%s\t%s\t%s\t-\n' "$old" "$repo" "$PID_A" "$repo" "$key_a" > "$DIR/s-x.tsv"
printf '%s\tclaim\tgit\t%s\t%s\t%s\t%s\t-\n' "$(date +%s)" "$repo" "$PID_A" "$repo" "$key_a" >> "$DIR/s-x.tsv"
SESSION_LEDGER_TTL=500 run s-b "$repo" check git "$repo"
rm -f "$DIR/s-x.tsv"
assert_eq "$(first_line)" "LEDGER_DENY" "判定"

exit_with_result
