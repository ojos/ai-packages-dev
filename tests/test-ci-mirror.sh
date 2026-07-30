#!/usr/bin/env bash
# CI のジョブ構成と、それを写している 2 か所が食い違っていないことを検査する。
#
#   1. scripts/acceptance.sh — CI を完全ミラーするローカル事前ゲート
#   2. .github/project-ai-rules.md — ミラー対象のジョブ数を規範として記述している箇所
#
# acceptance.sh 自身が冒頭で「ci.yml とここが食い違うと、ローカルゲートは『CI の
# 予行演習』ではなくなり、通っても意味を持たなくなる」「追随漏れを機械で検知する
# 仕組みは今のところ無い」と認めていた箇所で、実際に漏れた。#211 で CI へジョブを
# 1 つ足したとき、追随が必要な 2 か所のうち規範側を落とし、レビューで拾われている。
#
# 照合のアンカーは acceptance.sh の節見出し `# ── CI: <ジョブ名> ─────` とする。
# ジョブ名を突き合わせるのは、数だけを見るとジョブの入れ替え（数が変わらない変更）を
# 素通りさせるため。
#
# 抽出は文字クラスではなくリテラルで書く。この環境の locale は未設定（C）で、
# 罫線（U+2500）は 3 バイトとして扱われる。`─+` のような量指定子は最終バイトにしか
# かからず、locale 次第で挙動が変わる。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-ci-mirror"

CI="$REPO_ROOT/.github/workflows/ci.yml"
ACCEPTANCE="$REPO_ROOT/scripts/acceptance.sh"
RULES="$REPO_ROOT/.github/project-ai-rules.md"

# ── 抽出 ──────────────────────────────────────────────────────────────────────

# jobs: 配下のジョブ id（インデント 2 のキー）。
#
# ジョブ id は大文字とアンダースコアを許す（GitHub Actions の仕様）。小文字とハイフン
# だけを見ると build_and_test のようなジョブを数え落とし、name: の数と食い違って
# 誤検出で落ちる。
#
# jobs: 以外のトップレベルキーに入ったら抜ける。jobs: の後ろに concurrency: などが
# 置かれた場合、その配下のインデント 2 のキーをジョブ id と誤認するため。
CI_JOB_IDS="$(awk '
  /^jobs:/ { inside = 1; next }
  /^[A-Za-z_]/ { inside = 0 }
  inside && /^  [A-Za-z_][A-Za-z0-9_-]*:$/ { gsub(/[ :]/, ""); print }
' "$CI")"

# ジョブの表示名（インデント 4 の name:）。ステップの name: はインデント 6 なので入らない。
# YAML では name: "X" と書けるため、囲みのクォートは落としてから突き合わせる。
# 表示文字列が同じなのにクォートの有無だけで不一致になるのを防ぐ。
CI_JOB_NAMES="$(grep -E '^    name: ' "$CI" \
  | sed 's/^    name: //' \
  | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")"

# acceptance.sh の節見出し。
#
# identity-guard 節は照合対象から外す。あれがミラーしているのは ci.yml ではなく
# identity-guard.yml で、そちらのジョブは name: を持たないため、同じ規則で対応
# づけられない（#212 の scope.out）。**除外はこの 1 つに留める。** 例外が増えるほど
# 「照合しているつもりで何も見ていない」状態へ近づく。
ACCEPTANCE_SECTIONS="$(sed -n '/^# ── CI: /{s/^# ── CI: //; s/ ─.*$//; p}' "$ACCEPTANCE" \
  | grep -v '^identity-guard$')"

# 規範が記述するジョブ数。
RULES_COUNT="$(sed -nE 's/.*ci\.yml` の ([0-9]+) ジョブ.*/\1/p' "$RULES" | head -n 1)"

CI_JOB_COUNT="$(printf '%s\n' "$CI_JOB_IDS" | grep -c .)"
CI_NAME_COUNT="$(printf '%s\n' "$CI_JOB_NAMES" | grep -c .)"

# ── 照合 ──────────────────────────────────────────────────────────────────────

it "ci.yml からジョブを抽出できる"
if [[ "$CI_JOB_COUNT" -gt 0 ]]; then
  pass
else
  fail "ci.yml から jobs: 配下のジョブを抽出できなかった"
fi

it "ci.yml のすべてのジョブが name: を持つ"
# 以降の照合はジョブ名をキーにする。name: を持たないジョブがあると、そのジョブは
# 照合の対象から静かに外れる。アンカーそのものを先に守る。
assert_eq "$CI_NAME_COUNT" "$CI_JOB_COUNT" "name: を持つジョブ数"

it "ci.yml のジョブと acceptance.sh のミラーが一致する"
assert_same_set "$CI_JOB_NAMES" "$ACCEPTANCE_SECTIONS" "ci.yml" "acceptance.sh"

it "project-ai-rules が記述するジョブ数が ci.yml と一致する"
if [[ -z "$RULES_COUNT" ]]; then
  fail "project-ai-rules から「ci.yml の N ジョブ」を抽出できなかった"
else
  assert_eq "$RULES_COUNT" "$CI_JOB_COUNT" "project-ai-rules が記述するジョブ数"
fi

exit_with_result
