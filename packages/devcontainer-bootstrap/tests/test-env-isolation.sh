#!/usr/bin/env bash
# テストが実行環境の環境変数から隔離されていることを検証する。
#
# 規範: 生成物のスクリプトは実行時に環境変数を読む。テストは生成物を起動して挙動を
# 検査するため、実行者の環境にそれらが設定されていると、テストが設定したつもりの無い
# 値を生成物が拾って判定が変わる。lib.sh がその隔離を一括で担う（issue #179）。
#
# CI はこれらの変数を持たないため、隔離が外れても CI では気づけない。だからこの検証は
# 「現在の環境で変数が空か」ではなく「変数が設定された環境で lib.sh を読み込んだら空に
# なるか」を見る。前者はクリーンな環境では隔離を外しても通ってしまい、回帰を検知できない。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-env-isolation"

# 汚染値。空文字や 0 を使わないのは、隔離漏れと「元から空」を区別するため。
POLLUTE_VALUE="polluted-by-test-env-isolation"

# 汚染した環境で lib.sh を読み込み、各変数の状態を "NAME=<値>" で 1 行ずつ返す。
# lib.sh は TEST_TMP_ROOT を要求するため、それだけは引き継ぐ。
probe_after_lib() {
  local assignments="" v
  for v in $TEST_ISOLATED_ENV_VARS; do
    assignments="$assignments $v=$POLLUTE_VALUE"
  done
  # 値の取り出しは eval で行う。間接展開 ${!v-} でも同じ結果になるが、この
  # スイートは macOS の bash 3.2 でも動く必要があり、手元で 3.2 を実行して
  # 確かめられない。eval 版は展開の仕様差に依存しない。
  # shellcheck disable=SC2086
  env $assignments TEST_TMP_ROOT="$TEST_TMP_ROOT" \
    bash -c '. "$1"/lib.sh; for v in $TEST_ISOLATED_ENV_VARS; do eval "val=\${$v-}"; printf "%s=%s\n" "$v" "$val"; done' \
    _ "$TESTS_DIR"
}

it "隔離対象が 1 つ以上定義されている"
# 空リストなら以降の検査が素通りする。リストごと消える回帰を先に塞ぐ。
n="$(printf '%s\n' $TEST_ISOLATED_ENV_VARS | grep -c .)"
if [[ "$n" -ge 1 ]]; then pass; else fail "TEST_ISOLATED_ENV_VARS が空"; fi

it "probe が全変数分の結果を返す"
# probe が何らかの理由で出力を返さないと、次のケースは「漏れ 0 件」として通る。
# 検証していないものを緑として報告する形なので、行数が変数の数と一致することを
# 先に確かめる。probe 側の故障（構文エラー、lib.sh の読み込み失敗など）を
# 隔離の成功と取り違えないための番人。
probe="$(probe_after_lib)"
got_lines="$(printf '%s\n' "$probe" | grep -c '=')"
assert_eq "$got_lines" "$n" "probe の出力行数"

it "汚染された環境でも lib.sh 読み込み後は全て空になる"
# lib.sh の unset を外すとこのケースが落ちる。回帰検知の本体。
leaked=""
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  case "$line" in
    *"=$POLLUTE_VALUE") leaked="$leaked ${line%%=*}" ;;
  esac
done <<EOF
$probe
EOF
if [[ -z "$leaked" ]]; then pass; else fail "実行環境から漏れている:$leaked"; fi

it "隔離対象は全て生成物が実際に読む変数である"
# 使われなくなった変数がリストに残ると、隔離しているつもりの範囲と実態がずれる。
# 生成物の供給元は bootstrap.sh と、規範パッケージが持つ gemini-review.sh の雛形。
#
# -w で単語として照合する。部分一致だと、廃止された変数がリストに残っていても
# 名前を接頭辞に持つ別の変数へ一致して「使われている」と誤判定する
# （例: GIT_IDENTITY は GIT_IDENTITY_NAME に一致してしまう）。
unused=""
for v in $TEST_ISOLATED_ENV_VARS; do
  if grep -qw "$v" "$BOOTSTRAP" 2>/dev/null; then continue; fi
  if grep -qw "$v" "$PLAYBOOK_SRC/templates/gemini-review.sh" 2>/dev/null; then continue; fi
  unused="$unused $v"
done
if [[ -z "$unused" ]]; then pass; else fail "生成物が読まない変数がリストにある:$unused"; fi

it "テストが子プロセスへ明示的に渡す値は隔離に潰されない"
# 隔離はテストプロセスの環境を空にするだけで、テストが env / サブシェルで渡す値には
# 干渉しない。ここが壊れると、値を設定して挙動を確かめる既存テストが全て無意味になる。
got="$(env GEMINI_REVIEW_RUNS=7 bash -c 'printf %s "${GEMINI_REVIEW_RUNS-}"')"
assert_eq "$got" "7" "明示指定した値"

exit_with_result
