#!/usr/bin/env bash
# README の「受け入れ検証の CI ワークフロー」節が、verify.sh を回す CI を自前で持つ
# 利用側向けの手順（verify.yml を消さずに中身を移して --accept する）を載せていることを検査する。
#
# 消すと doctor が FAIL になる事実と、その回避手順が README に無いと、利用側は
# verify.yml を消して詰まる。手順の記述が節から落ちたら検出する。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-readme-verify-workflow"

README="$PKG_DIR/README.md"

# 「### 受け入れ検証の CI ワークフロー」から次の見出しまで
section() {
  awk '
    /^### 受け入れ検証の CI ワークフロー/ { inside = 1; next }
    /^#{1,3} / { inside = 0 }
    inside { print }
  ' "$README"
}

SECTION="$(section)"

it "節を抽出できる"
if [[ -n "$SECTION" ]]; then pass; else fail "節を抽出できなかった"; fi

check() {
  local label="$1" pattern="$2"
  it "$label"
  if printf '%s\n' "$SECTION" | command grep -E -- "$pattern" >/dev/null; then pass; else fail "節に見つからない: $pattern"; fi
}

check "verify.yml を消すと doctor が FAIL になると書いてある" 'verify\.yml.*消すと.*doctor.*FAIL'
check "--accept でも消せないと書いてある" '`--accept` でも消せません'
check "--accept .github/workflows/verify.yml の手順がある" '--accept \.github/workflows/verify\.yml'
check "前提ツールを足す位置への移し替えが書いてある" 'プロジェクトの前提はここへ足す'
check "required check の名前変更とブランチ保護・ruleset に触れている" 'required check.*ruleset'
check "--upgrade の .dcb-new を取り込んで --accept し直すと書いてある" '\.dcb-new.*--accept'

exit_with_result
