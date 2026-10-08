#!/usr/bin/env bash
# terraform の版を書いている 3 か所が一致していることを照合する（#487）。
#
#   - .github/workflows/terraform.yml の TF_VERSION（plan / apply）
#   - .github/workflows/ci.yml の terraform ジョブの terraform_version（fmt / validate）
#   - .devcontainer/devcontainer.json の terraform feature の version（手元の検査）
#
# 版が食い違うと、CI が検査した版と apply する版が別になり、手元のゲートもどちらとも
# 揃わなくなる。コメントの「揃える」だけでは片方の更新で静かにずれるので、機械で照合する
# （.ai-playbook/shared-ai-rules.md 12 章「一覧の複製は機械照合で担保する」）。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-terraform-version"

TF_WF="$REPO_ROOT/.github/workflows/terraform.yml"
CI="$REPO_ROOT/.github/workflows/ci.yml"
DC="$REPO_ROOT/.devcontainer/devcontainer.json"

wf_version="$(sed -nE 's/^  TF_VERSION: *"?([0-9][0-9.]*)"? *$/\1/p' "$TF_WF")"
# ci.yml の terraform_version は terraform ジョブにしか無い（他のジョブは terraform を使わない）。
ci_versions="$(sed -nE 's/^ *terraform_version: *"?([0-9][0-9.]*)"? *$/\1/p' "$CI")"
dc_version="$(jq -r '.features | to_entries[] | select(.key | startswith("ghcr.io/devcontainers/features/terraform:")) | .value.version' "$DC")"

it "terraform.yml から版を読める"
if [[ -n "$wf_version" ]]; then pass; else fail "TF_VERSION が見つからない"; fi

it "ci.yml の terraform_version は 1 か所だけ"
assert_eq "$(printf '%s\n' "$ci_versions" | sed '/^$/d' | wc -l | tr -d ' ')" "1" "terraform_version の数"

it "ci.yml の版が terraform.yml と一致する"
assert_eq "$ci_versions" "$wf_version" "ci.yml の terraform_version"

it "devcontainer.json の版が terraform.yml と一致する"
assert_eq "$dc_version" "$wf_version" "devcontainer.json の terraform feature の version"

exit_with_result
