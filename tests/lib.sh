#!/usr/bin/env bash
# lib.sh — プロジェクト層テストの共通アサーション
#
# ここは「この開発リポジトリ自身の規律」を検査する層で、配布パッケージの検査
# （packages/devcontainer-bootstrap/tests/）とは別の層になる。パッケージ層の
# tests/lib.sh を共有せず最小の複製を持つのは、あちらの大半が run_bootstrap や
# ローカル HTTP サーバといったパッケージ層固有のフィクスチャで、共有すると
# 「開発リポジトリの規律検査が配布パッケージのテスト基盤に依存する」層の逆転が
# 起きるため。複製されるのはアサーション数個で、乖離しても検出対象（文書と実装の
# 一覧）には影響しない。
#
# bash 3.2 互換を維持する（連想配列・mapfile を使わない）。

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"

it() {
  CURRENT_TEST="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
}

pass() {
  printf '  ok   %s\n' "$CURRENT_TEST"
}

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL %s\n' "$CURRENT_TEST" >&2
  printf '       %s\n' "$1" >&2
}

assert_eq() {
  local actual="$1" expected="$2" what="${3:-value}"
  if [[ "$actual" == "$expected" ]]; then
    pass
  else
    fail "$what: expected '$expected', got '$actual'"
  fi
}

# 2 つの改行区切りリストを両方向で突き合わせる。
#
# 片方向だけでは「文書にあるが実装に無い」か「実装にあるが文書に無い」の
# 一方しか検出できない。後者は「実装を足したのに文書へ書き忘れた」という、
# この層で最も起きやすい乖離そのものなので、両方向を必須にする。
assert_same_set() {
  local left="$1" right="$2" left_label="$3" right_label="$4"
  local only_left only_right msg=""
  only_left="$(comm -23 <(printf '%s\n' "$left" | sort -u) <(printf '%s\n' "$right" | sort -u) | tr '\n' ' ')"
  only_right="$(comm -13 <(printf '%s\n' "$left" | sort -u) <(printf '%s\n' "$right" | sort -u) | tr '\n' ' ')"
  only_left="${only_left% }"
  only_right="${only_right% }"
  [[ -n "$only_left" ]] && msg="${left_label}にしかない: $only_left"
  if [[ -n "$only_right" ]]; then
    [[ -n "$msg" ]] && msg="$msg / "
    msg="${msg}${right_label}にしかない: $only_right"
  fi
  if [[ -z "$msg" ]]; then
    pass
  else
    fail "$msg"
  fi
}

exit_with_result() {
  printf '  %s 件中 %s 件失敗\n\n' "$TESTS_RUN" "$TESTS_FAILED"
  [[ "$TESTS_FAILED" -eq 0 ]]
}
