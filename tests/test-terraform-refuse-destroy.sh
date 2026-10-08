#!/usr/bin/env bash
# scripts/terraform-refuse-destroy.sh が、公開リポジトリを消す・作り直す plan だけを落とすことを、
# 偽物の terraform（show -json で用意した JSON を返す）で確かめる（#487）。
#
# 本物の plan では消す変更は普段現れない（prevent_destroy が先に止める）ため、落とすべき形は
# 仕込みでしか確かめられない。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-terraform-refuse-destroy"

SCRIPT="$REPO_ROOT/scripts/terraform-refuse-destroy.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# 偽物の terraform。show -json のときだけ、PLAN_JSON のファイルの中身を返す。
cat > "$WORK/bin/terraform" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ "$a" == "show" ]]; then
    [[ -n "${FAKE_SHOW_FAIL:-}" ]] && exit 1
    cat "$PLAN_JSON"
    exit 0
  fi
done
exit 0
FAKE
chmod +x "$WORK/bin/terraform"

run() {
  PATH="$WORK/bin:$PATH" PLAN_JSON="$WORK/plan.json" bash "$SCRIPT" infra/github tfplan >"$WORK/out" 2>&1
  echo $?
}

plan_with() {
  printf '{"resource_changes":[%s]}\n' "$1" > "$WORK/plan.json"
}

it "変更が無ければ 0"
plan_with ''
assert_eq "$(run)" "0" "終了コード"

it "リポジトリの作成・更新・import だけなら 0"
plan_with '{"address":"github_repository.public[\"a\"]","type":"github_repository","change":{"actions":["create"]}},
{"address":"github_repository.public[\"b\"]","type":"github_repository","change":{"actions":["update"]}},
{"address":"github_repository.public[\"c\"]","type":"github_repository","change":{"actions":["no-op"]}}'
assert_eq "$(run)" "0" "終了コード"

it "terraform_data の作り直しは対象にしない"
plan_with '{"address":"terraform_data.pvr[\"a\"]","type":"terraform_data","change":{"actions":["delete","create"]}}'
assert_eq "$(run)" "0" "終了コード"

it "リポジトリの削除は 1"
plan_with '{"address":"github_repository.public[\"a\"]","type":"github_repository","change":{"actions":["delete"]}}'
assert_eq "$(run)" "1" "終了コード"

it "リポジトリの作り直し（create と delete）は 1"
plan_with '{"address":"github_repository.public[\"a\"]","type":"github_repository","change":{"actions":["create","delete"]}}'
assert_eq "$(run)" "1" "終了コード"

it "アドレスが変わっても型で見る"
plan_with '{"address":"module.repos.github_repository.this[\"x\"]","type":"github_repository","change":{"actions":["delete","create"]}}'
assert_eq "$(run)" "1" "終了コード"

it "落としたときは、消す資源のアドレスを出す"
if grep -F 'module.repos.github_repository.this["x"]' "$WORK/out" >/dev/null; then
  pass
else
  fail "出力: $(cat "$WORK/out")"
fi

it "plan を読めなければ 2（消す変更なしとは読まない）"
assert_eq "$(PATH="$WORK/bin:$PATH" PLAN_JSON="$WORK/plan.json" FAKE_SHOW_FAIL=1 bash "$SCRIPT" infra/github tfplan >/dev/null 2>&1; echo $?)" "2" "終了コード"

it "JSON として読めなければ 2"
echo 'not json' > "$WORK/plan.json"
assert_eq "$(run)" "2" "終了コード"

it "引数が足りなければ 2"
assert_eq "$(bash "$SCRIPT" infra/github >/dev/null 2>&1; echo $?)" "2" "終了コード"

exit_with_result
