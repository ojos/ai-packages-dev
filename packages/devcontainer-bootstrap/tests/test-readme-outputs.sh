#!/usr/bin/env bash
# README の生成物一覧が bootstrap.sh の実出力と一致することを検査する。
#
# 一覧は利用者が「何が自分のリポジトリへ書き込まれるか」を事前に知る唯一の手段で、
# レビュー時の差分の当たりもここから付ける。載っていない生成物（install-ai-tools.sh /
# gemini-review.sh / .ai-playbook/VERSION が実際にこの状態だった）は不意打ちになり、
# 生成しないものの記載（「README のセットアップ節更新」）は「書き換えられた」という
# 誤解を生む。
#
# 突き合わせの相手は --dry-run の出力にする。テスト側に期待一覧を書き写すと、
# 実装とテストの両方が README から独立して古くなる。--dry-run は実際の生成経路と
# 同じ template_rel_paths / install_playbook_rules を通るため、実出力の代理になる。
#
# 差集合は両方向で見る。片方向だけでは「生成しないのに載っている」記載を検出できない。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# 一覧は `.ai-playbook/**` を要素として持つ。パス名展開が効いていると、この要素が
# 実在ディレクトリの一覧へ化けて比較そのものが成立しない。
set -f

echo "test-readme-outputs"

README="$PKG_DIR/README.md"

# ── README 側の一覧 ──────────────────────────────────────────────────────────

# 「## 期待される出力」直下の 2 つの箇条書き（常時生成ぶんと規範配置時ぶん）だけを
# 対象にする。後続の小見出し（リモート最終ゲート / .gitignore 連携）は解説であって
# 一覧ではなく、そこまで含めると解説中のパス言及を「一覧の項目」と誤認する。
readme_outputs_section() {
  awk '
    /^## 期待される出力/ { inside = 1; next }
    inside && /^#/ { exit }
    inside { print }
  ' "$README"
}

# 箇条書きの先頭に置かれたバッククォート付きトークン（` / ` 区切りの連続を含む）だけを
# 一覧の項目とみなす。括弧内の解説にも生成物以外のパスが現れるため、行のどこからでも
# 拾うと「一覧として列挙されているか」を判定できない。
readme_outputs() {
  readme_outputs_section \
    | awk '
        /^- / {
          s = substr($0, 3)
          while (match(s, /^`[^`]+`/)) {
            print substr(s, RSTART + 1, RLENGTH - 2)
            s = substr(s, RSTART + RLENGTH)
            if (substr(s, 1, 3) == " / ") { s = substr(s, 4) } else { break }
          }
        }
      ' \
    | normalize_paths \
    | sort -u
}

# ── 実装側の一覧（--dry-run） ────────────────────────────────────────────────

# 規範ファイルは 1 つ 1 つが README の一覧に並ぶ性質のものではない（内容の正本は
# ai-playbook 側で、DCB は木ごと配置する）。README の `.ai-playbook/**` と対応付ける。
# VERSION だけは DCB 自身が書く記録なので個別に残す。
normalize_paths() {
  sed -e 's|^\.ai-playbook/VERSION$|@KEEP@.ai-playbook/VERSION|' \
      -e 's|^\.ai-playbook/.*$|.ai-playbook/**|' \
      -e 's|^@KEEP@||'
}

impl_outputs() {
  local out_root="$1"
  bash "$BOOTSTRAP" \
    --project-name outcheck \
    --languages node,go,python,php,rust,ruby \
    --with-aws --with-gcp --with-claude --with-gemini --with-copilot \
    --with-playbook \
    --output-dir "$out_root" \
    --dry-run 2>/dev/null \
    | sed -n 's|^plan: ||p' \
    | grep -v '^github/gitignore templates' \
    | grep -v '^shared AI rules from' \
    | sed -e "s|^$out_root/||" -e 's| (managed section update)$||' \
    | normalize_paths \
    | sort -u
}

out_root="$(new_workdir)/outcheck"
impl_list="$(impl_outputs "$out_root")"
readme_list="$(readme_outputs)"

it "--dry-run から生成物一覧を取得できる"
if [[ -n "$impl_list" ]]; then pass; else fail "--dry-run の plan 行を取得できなかった"; fi

it "README の「期待される出力」から一覧を取得できる"
if [[ -n "$readme_list" ]]; then pass; else fail "README の一覧を抽出できなかった"; fi

it "--dry-run が示す生成物がすべて README に載っている"
missing_in_readme=""
for p in $impl_list; do
  case "
$readme_list
" in
    *"
$p
"*) ;;
    *) missing_in_readme="$missing_in_readme $p" ;;
  esac
done
if [[ -z "$missing_in_readme" ]]; then
  pass
else
  fail "README の一覧に無い生成物:$missing_in_readme"
fi

it "README が載せる生成物はすべて --dry-run に現れる"
not_generated=""
for p in $readme_list; do
  case "
$impl_list
" in
    *"
$p
"*) ;;
    *) not_generated="$not_generated $p" ;;
  esac
done
if [[ -z "$not_generated" ]]; then
  pass
else
  fail "README に載っているが生成されないもの:$not_generated"
fi

it "生成先の README を書き換えないことが明示されている"
if grep -q 'bootstrap.sh は生成先の README' "$README"; then
  pass
else
  fail "README を生成物として扱わない旨の記載が無い"
fi

# ── 個別の実値照合 ────────────────────────────────────────────────────────────

it "README の postCreateCommand が生成物の実値と一致する"
# テンプレートが持つ実値を読み取って照合する。README 側に文字列を書き写すだけでは、
# テンプレートを変えたときに気づけない。
actual_pcc="$(grep -oE '"postCreateCommand": "[^"]*"' "$BOOTSTRAP" | head -1 | sed 's/.*: "//; s/"$//')"
if [[ -z "$actual_pcc" ]]; then
  fail "bootstrap.sh から postCreateCommand の実値を読めなかった"
elif grep -Fq -- "$actual_pcc" "$README"; then
  pass
else
  fail "README に実値が無い: $actual_pcc"
fi

exit_with_result
