#!/usr/bin/env bash
# second-opinion-review.sh の extract_acceptance が、issue 本文から acceptance の節を
# 2 つの形（intake の YAML / Markdown の見出し）で取り出すことを確かめる（#562）。
# 雛形と写しの両方に同じ試験を当てる。関数だけを取り出して実行する（非対話・ネットワーク不要）。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-second-opinion-acceptance"

for target in ".ai-playbook/templates/second-opinion-review.sh" "scripts/second-opinion-review.sh"; do
  echo " [$target]"
  # shellcheck disable=SC1090
  eval "$(awk '/^extract_acceptance\(\) \{/ { on = 1 } on { print } on && /^}/ { exit }' "$REPO_ROOT/$target")"

  it "YAML の acceptance: から、次のキーの手前までが取れる"
  out="$(printf 'goal: x\nacceptance:\n  - a\n  - b\npriority: 低\n' | extract_acceptance)"
  assert_eq "$out" $'acceptance:\n  - a\n  - b' "yaml"

  it "「## acceptance」から、次の ## の手前までが取れる"
  out="$(printf '# t\n## acceptance\n- a\n- b\n## 関連\n- c\n' | extract_acceptance)"
  assert_eq "$out" $'## acceptance\n- a\n- b' "h2"

  it "「### acceptance」の中の「#### 補足」で切らず、次の ### の手前までが取れる"
  out="$(printf '### acceptance\n- a\n#### 補足\n- b\n### 関連\n- c\n' | extract_acceptance)"
  assert_eq "$out" $'### acceptance\n- a\n#### 補足\n- b' "h3"

  it "「## Acceptance」（大文字）でも取れる"
  out="$(printf '## Acceptance\n- a\n## x\n' | extract_acceptance)"
  assert_eq "$out" $'## Acceptance\n- a' "case"

  it "コードのフェンスの中の「# acceptance」は見出しとして扱わない"
  out="$(printf '```\n# acceptance\n- no\n```\ntext\n' | extract_acceptance)"
  assert_eq "$out" "" "fence"

  it "節の中のフェンスの「#」は、節を切らない"
  out="$(printf '## acceptance\n```\n# comment\n```\n- a\n## x\n' | extract_acceptance)"
  assert_eq "$out" $'## acceptance\n```\n# comment\n```\n- a' "fence in section"

  it "YAML が先に現れたら YAML を取る"
  out="$(printf 'acceptance:\n  - y\npriority: 低\n## acceptance\n- h\n' | extract_acceptance)"
  assert_eq "$out" $'acceptance:\n  - y' "yaml first"

  it "見出しが先に現れたら見出しを取る"
  out="$(printf '## acceptance\n- h\n## x\nacceptance:\n  - y\n' | extract_acceptance)"
  assert_eq "$out" $'## acceptance\n- h' "heading first"

  it "acceptance の節が無ければ何も出さない"
  out="$(printf '## 概要\ntext\n## 関連\n' | extract_acceptance)"
  assert_eq "$out" "" "none"

  it "空白 1〜3 個のフェンスの中の「# acceptance」は見出しとしない"
  out="$(printf '   ```\n# acceptance\n- no\n   ```\ntext\n' | extract_acceptance)"
  assert_eq "$out" "" "indented fence"

  it "~~~ のフェンスの中の「# acceptance」も見出しとしない"
  out="$(printf '~~~\n# acceptance\n- no\n~~~\ntext\n' | extract_acceptance)"
  assert_eq "$out" "" "tilde fence"

  it "~~~ のフェンスの中にバッククォート 3 つが出ても閉じない"
  out="$(printf '~~~\n```\n# acceptance\n~~~\n' | extract_acceptance)"
  assert_eq "$out" "" "mixed fence"

  it "空白付きの「  ## acceptance」から取れる"
  out="$(printf '  ## acceptance\n- a\n## x\n' | extract_acceptance)"
  assert_eq "$out" $'  ## acceptance\n- a' "indented heading"

  it "「## acceptance ##」から取れる"
  out="$(printf '## acceptance ##\n- a\n## x\n' | extract_acceptance)"
  assert_eq "$out" $'## acceptance ##\n- a' "closing hashes"

  it "空白付きの次の見出しで節が終わる"
  out="$(printf '## acceptance\n- a\n  ## x\n- b\n' | extract_acceptance)"
  assert_eq "$out" $'## acceptance\n- a' "indented end"

  it "4 個のバッククォートで開いたフェンスの中の 3 個の行で閉じず、続く「# acceptance」を見出しとしない"
  out="$(printf '````\n```\n# acceptance\n- no\n````\ntext\n' | extract_acceptance)"
  assert_eq "$out" "" "long backtick fence"

  it "~~~~ で開いたフェンスでも同じ"
  out="$(printf '~~~~\n~~~\n# acceptance\n- no\n~~~~\ntext\n' | extract_acceptance)"
  assert_eq "$out" "" "long tilde fence"

  it "同じ長さの並びで閉じる"
  out="$(printf '````\nx\n````\n## acceptance\n- a\n## y\n' | extract_acceptance)"
  assert_eq "$out" $'## acceptance\n- a' "close same length"

  it "より長い並びでも閉じる"
  out="$(printf '```\nx\n`````\n## acceptance\n- a\n## y\n' | extract_acceptance)"
  assert_eq "$out" $'## acceptance\n- a' "close longer"

  it "節の中の長いフェンスの内側にある 3 個の行では閉じず、その中の見出しで節を切らない"
  out="$(printf '## acceptance\n````\n```\n## x\n````\n- a\n## y\n' | extract_acceptance)"
  assert_eq "$out" $'## acceptance\n````\n```\n## x\n````\n- a' "long fence in section"
  it "goal: の無いフェンス（コード例）の中の acceptance: を採らず、後ろの本物の見出しを採る (#597)"
  out="$(printf '例:\n```yaml\nacceptance:\n  - 例の中身\n```\n\n## acceptance\n- 本物\n## x\n' | extract_acceptance)"
  assert_eq "$out" $'## acceptance\n- 本物' "example fence then heading"

  it "goal: の無いフェンスの後ろの、goal: を含む intake の票を採る (#597)"
  out="$(printf '```yaml\nacceptance:\n  - 例\n```\n```yaml\ngoal: g\nacceptance:\n  - 本物\npriority: 低\n```\n' | extract_acceptance)"
  assert_eq "$out" $'acceptance:\n  - 本物' "example fence then ticket"

  it "intake の票だけのフェンスから採る (#597)"
  out="$(printf '## 票\n```yaml\ngoal: g\nscope.in:\n  - s\nacceptance:\n  - a\npriority: 低\n```\n' | extract_acceptance)"
  assert_eq "$out" $'acceptance:\n  - a' "ticket only"

  it "フェンスの外の acceptance: は goal: が無くても採る (#597)"
  out="$(printf 'text\nacceptance:\n  - a\n\nnext: 1\n' | extract_acceptance)"
  assert_eq "$out" $'acceptance:\n  - a' "outside fence"
done

exit_with_result
