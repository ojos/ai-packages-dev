#!/usr/bin/env bash
# shellcheck の検査対象が、ci.yml と acceptance.sh で一致し、配布する .sh を
# すべて含んでいることを検査する（#589）。
#
# 新設の理由: 検査対象を bootstrap.sh / doctor.sh の 2 本のファイル名で並べていたため、
# 配布物が増えても（templates の .sh、devcontainer-host の 3 本）検査に入らず、
# 既定の重大度の shellcheck を通らない .sh が配られていた。対象を git ls-files の
# 決まった形で書き、その形が 2 か所で同じであることと、配布物の全体を覆うことを
# 機械で担保する。
#
# 配布する .sh の定義: .ai-playbook/ と packages/ の配下の .sh（サブディレクトリを含む。
# リリースは .ai-playbook/ を丸ごと、devcontainer-host を git ls-files の全体で配る）。
# packages/*/tests/ は配布しないので含めない。この定義は、照合する相手（対象指定）の
# pathspec を使わずに求める。同じ指定で求めると、指定どうしを比べるだけになるため。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-shellcheck-targets"

CI="$REPO_ROOT/.github/workflows/ci.yml"
ACCEPTANCE="$REPO_ROOT/scripts/acceptance.sh"

# git ls-files に渡す pathspec を、shellcheck へ渡す配列を作る mapfile の行だけから
# 取り出す（同じファイルの別の git ls-files を拾わないため）。引用符つきの ':(...)...' を
# 集合として比べる。
extract_specs() {
  grep -E 'mapfile -t (targets|shellcheck_targets) < <\(git ls-files ' "$1" \
    | grep -o "':([^)]*)[^']*'" | tr -d "'" | sort -u
}

CI_SPECS="$(extract_specs "$CI")"
ACC_SPECS="$(extract_specs "$ACCEPTANCE")"

it "ci.yml から shellcheck の対象指定を抽出できる"
if [[ -n "$CI_SPECS" ]]; then pass; else fail "ci.yml に git ls-files の :(glob) 指定が無い"; fi

it "acceptance.sh から shellcheck の対象指定を抽出できる"
if [[ -n "$ACC_SPECS" ]]; then pass; else fail "acceptance.sh に git ls-files の :(glob) 指定が無い"; fi

it "shellcheck の対象指定が ci.yml と acceptance.sh で一致する"
assert_same_set "$CI_SPECS" "$ACC_SPECS" "ci.yml" "acceptance.sh"

# shellcheck を呼ぶ行が、対象の配列を渡している（ファイル名の直書きへ戻っていない）こと。
it "ci.yml の shellcheck は、一覧で決めた対象を渡している"
if grep -E '^[[:space:]]*(run: )?shellcheck -x -f gcc "\$\{targets\[@\]\}"$' "$CI" >/dev/null; then
  pass
else
  fail 'ci.yml に shellcheck -x -f gcc "${targets[@]}" の行が無い（-x -f gcc の維持も兼ねる）'
fi

it "acceptance.sh の shellcheck は、一覧で決めた対象を渡している"
if grep -E '^shellcheck -x -f gcc "\$\{shellcheck_targets\[@\]\}"$' "$ACCEPTANCE" >/dev/null; then
  pass
else
  fail 'acceptance.sh に shellcheck -x -f gcc "${shellcheck_targets[@]}" の行が無い'
fi

# 配布する .sh（定義は冒頭）を実際に列挙し、対象指定が覆っていることを確かめる。
# 指定の解釈は git 本体に任せる（自前でパターンを再実装しない）。
mapfile -t DISTRIBUTED < <(
  cd "$REPO_ROOT" && git ls-files -- .ai-playbook packages \
    | grep -E '\.sh$' | grep -Ev '^packages/[^/]+/tests/'
)
mapfile -t SPEC_ARGS <<<"$CI_SPECS"
mapfile -t COVERED < <(cd "$REPO_ROOT" && git ls-files "${SPEC_ARGS[@]}")

it "配布する .sh が 1 本以上見つかる"
if [[ "${#DISTRIBUTED[@]}" -gt 0 ]]; then pass; else fail "配布する .sh を列挙できなかった"; fi

it "配布する .sh がすべて shellcheck の対象に入っている"
assert_same_set "$(printf '%s\n' "${DISTRIBUTED[@]}")" "$(printf '%s\n' "${COVERED[@]}")" "配布物の定義" "対象指定"

it "配布しない packages/*/tests/ が対象に混ざっていない"
if printf '%s\n' "${COVERED[@]}" | grep -E '/tests/' >/dev/null; then
  fail "対象に tests/ 配下が入っている"
else
  pass
fi

exit_with_result
