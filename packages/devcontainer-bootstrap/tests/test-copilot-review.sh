#!/usr/bin/env bash
# test-copilot-review.sh — リモート最終ゲート（Copilot）雛形の条件配置を検証する。
#
# 規範（review-workflow.md）はベンダー中立で「1 回に限定される機構なら自動要求でよい」
# とだけ述べ、具体機構は --with-copilot-review を選んだ場合のみ雛形として配置する。
# ここではその分離（選択時のみ配置・未選択では不在）と、生成される YAML が「1 回だけ」を
# 機構で保証する不変条件（types: [opened] 限定・フォーク PR スキップ）を担保する。
#
# 配置の契機は --with-copilot ではない（issue #230 の破壊的変更）。ローカルの開発ツール
# （CLI・拡張・永続 volume）とリモートのレビュー機構は効く場所が違い、片方だけ欲しい
# 構成が実在する。両者が同じフラグへ戻っていないことを、ローカル配線の不在まで含めて
# 検査する。「配置される」だけを見ると、束ね直しても緑のまま通る。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-copilot-review"

TPL="$PLAYBOOK_SRC/templates"
WF_REL=".github/workflows/copilot-review.yml"

# ── 規範パッケージ側に雛形が揃っているか ─────────────────────────────────────

it "規範パッケージがリモート最終ゲート（Copilot）の雛形を持つ"
assert_file_exists "$TPL/copilot-review.yml"

# ── 選択時のみ配置する ────────────────────────────────────────────────────────

it "--with-copilot-review --with-playbook で copilot-review.yml が配置される"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot-review --with-playbook >/dev/null 2>&1
assert_file_exists "$out/$WF_REL"

it "配置された copilot-review.yml は雛形と完全一致する（コピーであって再生成でない）"
if diff -q "$out/$WF_REL" "$TPL/copilot-review.yml" >/dev/null 2>&1; then pass; else fail "雛形と一致しない"; fi

it "--with-copilot 単独（+規範）ではワークフローを配置しない"
# issue #230 の破壊的変更の本体。ローカル装備のフラグでリモート機構が付いてくる形へ
# 戻ると、「ローカルだけ欲しい」構成をふたたび機構で表現できなくなる。
out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot --with-playbook >/dev/null 2>&1
assert_file_absent "$out/$WF_REL"

it "--with-copilot-review はローカル配線（拡張・CLI 導入行・volume）を入れない"
# 逆向きの束ね直しも見る。リモートのフラグでローカル装備が付いてくると、レビュー
# ゲートだけが欲しい構成に不要な CLI と volume が混ざる。
out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot-review --with-playbook >/dev/null 2>&1
leaked=""
grep -q 'github.copilot' "$out/.devcontainer/devcontainer.json" 2>/dev/null && leaked="$leaked 拡張"
grep -qE '^install_if_missing copilot ' "$out/scripts/install-ai-tools.sh" 2>/dev/null && leaked="$leaked CLI導入行"
grep -q 'copilot-storage' "$out/.devcontainer/compose.yaml" 2>/dev/null && leaked="$leaked volume"
if [[ -z "$leaked" ]]; then pass; else fail "ローカル配線が漏れて入っている:$leaked"; fi

it "両方指定ならローカル配線もワークフローも入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot --with-copilot-review --with-playbook >/dev/null 2>&1
missing=""
[[ -f "$out/$WF_REL" ]] || missing="$missing ワークフロー"
grep -q 'github.copilot' "$out/.devcontainer/devcontainer.json" 2>/dev/null || missing="$missing 拡張"
grep -qE '^install_if_missing copilot ' "$out/scripts/install-ai-tools.sh" 2>/dev/null || missing="$missing CLI導入行"
grep -q 'copilot-storage' "$out/.devcontainer/compose.yaml" 2>/dev/null || missing="$missing volume"
if [[ -z "$missing" ]]; then pass; else fail "両方指定なのに欠けている:$missing"; fi

it "--with-copilot-review なし（--with-playbook のみ）では配置しない"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-playbook >/dev/null 2>&1
assert_file_absent "$out/$WF_REL"

# ── 規範を配置しない構成では書き込み前に停止する ──────────────────────────────
#
# 雛形の供給元は規範パッケージなので、規範を配置しない構成では配置しようがない。
# require_playbook_template へ委ねると規範や入口ファイルを書いたあとで停止し、
# 中途半端な生成物が残る。取得元が解決できなければ 1 つも書かない（v0.4.2）に揃える。

it "--with-copilot-review を規範なしで指定するとエラー終了する"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --with-copilot-review 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]]; then pass; else fail "規範なしなのに成功した（exit $rc）"; fi

it "そのエラーは移行先（規範を配置する指定）を示す"
assert_contains "$output" "--with-playbook" "エラー出力"

it "そのとき生成物を 1 つも書かない（出力先が作られない）"
# 「ワークフローだけ無い」ではなく「何も書いていない」ことを見る。出力先ディレクトリ
# ごと存在しないことが、書き込み前に落ちたことの証拠になる。
assert_file_absent "$out"

it "--without-playbook との併用も書き込み前に停止する"
# 明示オプトアウトは最優先で尊重される。ソース指定があっても規範は配置されないので、
# 雛形の供給元は無い。
out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot-review --without-playbook --playbook-from "$PLAYBOOK_SRC" >/dev/null 2>&1
rc=$?
if [[ "$rc" -ne 0 && ! -e "$out" ]]; then pass; else fail "停止しないか生成物が残る（exit $rc）"; fi

it "--playbook-from でのソース指定だけでも配置は成立する"
# 配置判定は should_install_playbook が持つ。--with-playbook の有無で条件を書き写すと、
# ソース指定だけで配置する経路（README「AI 共通ルールの配置」）を誤って弾く。
out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot-review --playbook-from "$PLAYBOOK_SRC" >/dev/null 2>&1
assert_file_exists "$out/$WF_REL"

it "dry-run は copilot-review 選択時に copilot-review.yml を計画へ含める"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --with-copilot-review --with-playbook --dry-run 2>&1)"
assert_contains "$output" "$WF_REL" "dry-run 計画"

it "dry-run は copilot-review 未選択なら copilot-review.yml を計画へ含めない"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --with-copilot --with-playbook --dry-run 2>&1)"
case "$output" in
  *"$WF_REL"*) fail "未選択なのに計画へ現れた" ;;
  *) pass ;;
esac

# ── 「1 回だけ」を機構で保証する不変条件 ──────────────────────────────────────

out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot-review --with-playbook >/dev/null 2>&1
wf="$out/$WF_REL"

it "生成ワークフローは types: [opened] に限定される（synchronize で再要求しない）"
# opened のみを契機とし、synchronize（PR 更新）を含めないこと。これが「1 回だけ」の実体。
# 判定は設定行（types:）に限定する。コメント文言に synchronize が出ても誤検知しない。
types_line="$(grep -E '^[[:space:]]*types:' "$wf" || true)"
if printf '%s' "$types_line" | grep -Eq '\[[[:space:]]*opened[[:space:]]*\]' \
   && ! printf '%s' "$types_line" | grep -q 'synchronize'; then
  pass
else
  fail "types が opened 限定でない、または synchronize を含む: '$types_line'"
fi

it "生成ワークフローはフォーク PR をスキップする"
if grep -qF 'github.event.pull_request.head.repo.full_name == github.repository' "$wf"; then
  pass
else
  fail "フォーク PR スキップの if 条件が無い"
fi

it "生成ワークフローはトークンをフォールバックさせる（PAT へ切替可）"
if grep -qF 'secrets.COPILOT_REVIEW_TOKEN || secrets.GITHUB_TOKEN' "$wf"; then
  pass
else
  fail "トークンフォールバックが無い"
fi

it "生成ワークフローは前提（422 の条件）をコメントで明記する"
if grep -q '422' "$wf"; then pass; else fail "前提の明記（422）が無い"; fi

# ── 再試行の機構（要求は間欠的に失敗する。ojos/ai-packages-dev#306）────────────
#
# 規範（review-workflow.md）の「1 回だけ要求する」が禁じるのは要求が別のイベント
# から重ねて出て二重要求になることで、同じジョブの中で成功するまで試すことは
# 対象外である（外から見える要求はこのワークフロー 1 本のまま）。ここではその
# 再試行が実際に置かれていること、成功したら即座に抜けること、尽きたら黙って
# 緑にしないことを、生成された YAML のテキストで固定する。
#
# 「間欠故障が実際に救われるか」はここでは検証できない（再現条件が分かっていない
# ため）。検査できるのは機構が置かれていることと、失敗を握り潰さないことまで。

while_line="$(grep -nE '^[[:space:]]*while ' "$wf" | head -n 1 | cut -d: -f1)"
done_line="$(grep -n '^[[:space:]]*done$' "$wf" | head -n 1 | cut -d: -f1)"

it "生成ワークフローは要求の失敗時に再試行するループを持つ"
if [[ -n "$while_line" && -n "$done_line" && "$while_line" -lt "$done_line" ]]; then
  pass
else
  fail "while ... done の再試行ループが見つからない"
fi

# ループ本体を切り出す。以降の判定はループ内で完結しているかまで見るため、
# ファイル全体への grep ではなく本体だけを対象にする。
loop_body=""
if [[ -n "$while_line" && -n "$done_line" ]]; then
  loop_body="$(sed -n "${while_line},${done_line}p" "$wf")"
fi

it "再試行ループは要求呼び出しと試行回数の上限判定を両方含む"
has_gh=0; has_limit=0
case "$loop_body" in *"gh api --method POST"*) has_gh=1 ;; esac
case "$loop_body" in *"max_attempts"*) has_limit=1 ;; esac
if [[ "$has_gh" -eq 1 && "$has_limit" -eq 1 ]]; then
  pass
else
  fail "ループ本体に要求呼び出し(has_gh=$has_gh)または上限判定(has_limit=$has_limit)が無い"
fi

it "再試行は間隔を空ける（sleep がループ内にある）"
case "$loop_body" in
  *"sleep "*) pass ;;
  *) fail "ループ内に sleep が無い（間隔を空けない再試行になっている）" ;;
esac

it "生成ワークフローは成功したらその場で抜ける（成功後に再試行しない）"
# 成功時の exit 0 がループ本体の中にあり、かつループ内で最初に現れる sleep より
# 前にあることを見る。逆順や不在だと、成功してもなお待機・再試行のコードを
# 通ってしまう構造になっている。
exit0_line="$(grep -n 'exit 0' "$wf" | head -n 1 | cut -d: -f1)"
sleep_line="$(grep -nE '^[[:space:]]*sleep ' "$wf" | head -n 1 | cut -d: -f1)"
if [[ -n "$exit0_line" && -n "$sleep_line" && -n "$while_line" && -n "$done_line" \
      && "$while_line" -lt "$exit0_line" && "$exit0_line" -lt "$done_line" \
      && "$exit0_line" -lt "$sleep_line" ]]; then
  pass
else
  fail "成功時の exit 0 がループ内・sleep より前にない（exit0=$exit0_line sleep=$sleep_line while=$while_line done=$done_line）"
fi

it "生成ワークフローは再試行を尽くしても失敗したら非 0 で終える（黙って緑にしない）"
# ループを抜けた後（done の後）に exit 1 があることを見る。ループの中にも
# 別の exit 1（timeline を確認できなかったときの安全側停止）があるため、
# 「最初の exit 1」ではなく「done より後にある exit 1」を探す。ループの中だけに
# あると、尽きる前の 1 回の失敗で即座に終わってしまい「再試行」の体をなさない。
# ループの外にあって初めて「尽きたら」の判定になる。
exit1_after_loop=""
if [[ -n "$done_line" ]]; then
  exit1_lines="$(grep -n 'exit 1' "$wf" | cut -d: -f1)"
  for n in $exit1_lines; do
    if [[ "$n" -gt "$done_line" ]]; then
      exit1_after_loop="$n"
      break
    fi
  done
fi
if [[ -n "$exit1_after_loop" ]]; then
  pass
else
  fail "再試行ループの後（done 行 $done_line より後）に exit 1 が無い"
fi

it "::error:: の切り分け手順は空レスポンスの実測（unexpected end of JSON input）を 422 より先に挙げる"
# 現行の書き方の逆転を検出する: 従来は 422（所有者側で無効）を第一候補に挙げて
# いたが、実際に踏んだのは空のレスポンスだった。順序まで見ないと、両方の語が
# 入っているだけの状態（切り分け手順が実測と逆順のまま）を見逃す。
#
# 目印は固有の文言（「次の順に切り分けてください」）で取る。単に「::error::」の
# 最初の行を拾うと、再試行の途中にある別の ::error::（timeline 確認不可時の
# 安全停止）を誤って掴む。
error_line="$(grep -F '次の順に切り分けてください' "$wf" | head -n 1)"
pos_empty="$(awk -v s="$error_line" 'BEGIN{print index(s, "unexpected end of JSON input")}')"
pos_422="$(awk -v s="$error_line" 'BEGIN{print index(s, "422")}')"
if [[ -n "$error_line" && "$pos_empty" -gt 0 && "$pos_422" -gt 0 && "$pos_empty" -lt "$pos_422" ]]; then
  pass
else
  fail "空レスポンスの言及が無いか、422 より後になっている（empty=$pos_empty 422=$pos_422）"
fi

# ── 再送前の成立確認（PR #310 の Copilot 指摘: 空レスポンス ≠ 要求未成立）─────────
#
# `gh` が失敗を返しても、それは応答の解析に失敗しただけで、POST 自体はサーバ側に
# 届いて成立している可能性がある。その状態で無条件に再送すると、1 回のつもりの
# 要求が複数回記録され、「1 回だけ要求する」を再試行自身が壊しうる
# （.ai-playbook/review-workflow.md「リモート最終ゲート」の追記を参照）。
#
# **requested_reviewers の GET 応答（.users[]）は使えない。** 要求が成立した
# 直後からこのフィールドが空になることが実測されている。空だから未成立と読むと、
# この確認は存在しても一度も効かない最悪の形になる。判定には timeline の
# review_requested イベントを使う。

it "生成ワークフローは再送する前に timeline を確認する（POST 失敗 → timeline 確認 → sleep の順）"
# 要求呼び出し・timeline 確認・待機（sleep）の 3 つが、この順でループ内に
# 現れることを見る。timeline 確認が sleep より後ろにあると、確かめる前に
# 再送してしまう構造になる。
gh_post_line="$(grep -n 'gh api --method POST' "$wf" | head -n 1 | cut -d: -f1)"
# 'issues/${PR_NUMBER}/timeline' は生成物の中に現れるリテラル文字列を探しており、
# ここでの $ は展開させない意図的な単一引用符。
# shellcheck disable=SC2016
timeline_line="$(grep -nF 'issues/${PR_NUMBER}/timeline' "$wf" | head -n 1 | cut -d: -f1)"
if [[ -n "$while_line" && -n "$gh_post_line" && -n "$timeline_line" && -n "$sleep_line" && -n "$done_line" \
      && "$while_line" -lt "$gh_post_line" \
      && "$gh_post_line" -lt "$timeline_line" \
      && "$timeline_line" -lt "$sleep_line" \
      && "$sleep_line" -lt "$done_line" ]]; then
  pass
else
  fail "順序が崩れている（while=$while_line post=$gh_post_line timeline=$timeline_line sleep=$sleep_line done=$done_line）"
fi

it "生成ワークフローは判定に requested_reviewers の GET 応答（.users[]）を使わない"
# 要求済みかどうかの判定を requested_reviewers の読み取りへ書き換えると、成立
# 直後から空を返す実測のとおり必ず「未成立」と誤読し、再送し続ける（=この確認が
# 一度も効かない）。書き換えを静かに通さないよう、GET 応答特有のアクセサ
# （.users[]）が現れないことを固定する。POST 呼び出し自体（write 側）の URL に
# requested_reviewers という語が出ることは許容する（判定には使っていないため）。
case "$(cat "$wf")" in
  *".users["*) fail "requested_reviewers の GET 応答（.users[]）で判定している" ;;
  *) pass ;;
esac

it "生成ワークフローの timeline 確認は review-gate.yml と同じ表記ゆれ吸収（is_copilot）を使う"
if grep -qF 'copilot|"copilot-pull-request-reviewer[bot]") return 0 ;;' "$wf"; then
  pass
else
  fail "is_copilot の判定（Copilot / copilot-pull-request-reviewer[bot] の両対応）が見つからない"
fi

it "生成ワークフローは timeline で review_requested の成立を確認できたら再送せず抜ける"
# timeline 確認の「成功」分岐（if [ \"\$last\" = \"review_requested\" ]）の直後に
# exit 0 があることを見る。無いと、成立を確認できても再送してしまう。
# 同じく生成物中のリテラル文字列探索。$ を展開させない意図的な単一引用符。
# shellcheck disable=SC2016
last_check_line="$(grep -nF '"$last" = "review_requested"' "$wf" | head -n 1 | cut -d: -f1)"
ctx=""
if [[ -n "$last_check_line" ]]; then
  ctx="$(sed -n "${last_check_line},$((last_check_line + 3))p" "$wf")"
fi
case "$ctx" in
  *"exit 0"*) pass ;;
  *) fail "review_requested 確認済みの分岐に exit 0 が無い（行 $last_check_line 付近）" ;;
esac

it "生成ワークフローは timeline を確認できなかった場合、再送せずに終了する（読めなかった ≠ 要求されていない）"
# 「timeline を確認できず」という趣旨の分岐（else 側）を目印に取り、その直後の
# 数行に exit 1 があり、sleep が無いことを見る。sleep が混ざっていると、
# 確かめられないまま再送する経路が残っていることになる。
unreadable_line="$(grep -nF 'timeline を確認できず' "$wf" | head -n 1 | cut -d: -f1)"
ctx=""
if [[ -n "$unreadable_line" ]]; then
  ctx="$(sed -n "${unreadable_line},$((unreadable_line + 3))p" "$wf")"
fi
has_exit1=0; has_sleep=0
case "$ctx" in *"exit 1"*) has_exit1=1 ;; esac
case "$ctx" in *"sleep "*) has_sleep=1 ;; esac
ctx_status="found"
[[ -n "$ctx" ]] || ctx_status="missing"
if [[ -n "$ctx" && "$has_exit1" -eq 1 && "$has_sleep" -eq 0 ]]; then
  pass
else
  fail "timeline 未確認時の分岐が期待の形でない（ctx=$ctx_status exit1=$has_exit1 sleep=$has_sleep）"
fi

# ── YAML として妥当である ─────────────────────────────────────────────────────
# actionlint があれば通す。無ければ PyYAML、それも無ければ最低限の構造検査で代替する
# （沈黙スキップはしない）。

it "生成ワークフローが YAML/Actions として妥当である"
if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$wf" >/dev/null 2>&1; then pass; else fail "actionlint 検査に失敗"; fi
elif python3 -c 'import yaml' >/dev/null 2>&1; then
  if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$wf" >/dev/null 2>&1; then
    pass
  else
    fail "PyYAML の safe_load に失敗"
  fi
else
  # 最低限の構造検査: 必須トップキーが存在し、行頭タブインデントが無いこと。
  tab="$(printf '\t')"
  if grep -Eq '^on:' "$wf" \
     && grep -Eq '^jobs:' "$wf" \
     && grep -Eq '^permissions:' "$wf" \
     && ! grep -q "^${tab}" "$wf"; then
    pass
  else
    fail "必須トップキー欠落またはタブインデント混入"
  fi
fi

exit_with_result
