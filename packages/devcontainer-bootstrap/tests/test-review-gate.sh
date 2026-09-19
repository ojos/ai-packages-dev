#!/usr/bin/env bash
# test-review-gate.sh — リモート最終ゲート「確認側」雛形の条件配置を検証する。
#
# 要求側（copilot-review.yml）は test-copilot-review.sh が見る。こちらは確認側で、
# 役割が違う 2 本を 1 つのテストへ混ぜると、片方が落ちたときにどちらの機構が壊れた
# のか出力から読めなくなるため、ファイルを分ける。
#
# 配置の契機は 2 本とも --with-copilot-review で、ローカル装備の --with-copilot では
# 置かない（issue #230）。要求側だけを移すと 2 本の配置条件がずれ、片方だけが置かれる
# 状態を作れてしまうため、確認側でも同じ条件を検査する。
#
# 確認側が守る不変条件は「要求しないこと」と「別の契機を持つこと」の 2 つ。前者は
# 要求が 2 か所から出ると規範の「1 回だけ」が壊れるため、後者は届かないイベントを
# 同じ契機から見ても起動しないため（規範 review-workflow.md「要求されたことを別の
# 契機で確認する」）。どちらも生成された YAML の内容として検査する。
#
# 確認側はもう 1 つ、「読まれたか」も見る（規範 review-workflow.md「要求された ≠
# 読まれた」）。この判定は review-gate.yml へ書き写さず scripts/review-usable.sh へ
# 切り出してあるため、配置される本数は 2 本から 4 本へ増える。判定を書き写していない
# ことは、生成された YAML に判定文字列（定型文の一致パターンや判定関数）が現れない
# ことで確かめる。判定そのものの正しさ（表駆動の受け入れ条件）は
# check-review-usable.sh が別に持つ。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-review-gate"

TPL="$PLAYBOOK_SRC/templates"
WF_REL=".github/workflows/review-gate.yml"
USABLE_REL="scripts/review-usable.sh"
CHECK_USABLE_REL="scripts/check-review-usable.sh"

# ── 規範パッケージ側に雛形が揃っているか ─────────────────────────────────────

it "規範パッケージがリモート最終ゲート（確認側）の雛形を持つ"
assert_file_exists "$TPL/review-gate.yml"

it "規範パッケージが確認側の判定スクリプト 2 本を持つ"
assert_file_exists "$TPL/review-usable.sh"
assert_file_exists "$TPL/check-review-usable.sh"

# ── 選択時のみ配置する ────────────────────────────────────────────────────────

it "--with-copilot-review --with-playbook で review-gate.yml が配置される"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot-review --with-playbook >/dev/null 2>&1
assert_file_exists "$out/$WF_REL"

it "配置された review-gate.yml は雛形と完全一致する（コピーであって再生成でない）"
if diff -q "$out/$WF_REL" "$TPL/review-gate.yml" >/dev/null 2>&1; then pass; else fail "雛形と一致しない"; fi

it "要求側と確認側は 2 本そろって配置される"
# 片方だけの配置は、この機構が塞ごうとしている穴（要求されないまま通る）を残す。
assert_file_exists "$out/.github/workflows/copilot-review.yml"

it "--with-copilot-review --with-playbook で確認側の判定スクリプト 2 本（scripts/review-usable.sh / scripts/check-review-usable.sh）が配置される"
# review-gate.yml が判定を委ねる先。片方だけ欠けると確認側が起動時に読めず、
# 「確かめられなかった」側へ倒れて status が付かないまま止まる。
assert_file_exists "$out/$USABLE_REL"
assert_file_exists "$out/$CHECK_USABLE_REL"

it "配置された scripts/review-usable.sh は雛形と完全一致する（コピーであって再生成でない）"
if diff -q "$out/$USABLE_REL" "$TPL/review-usable.sh" >/dev/null 2>&1; then pass; else fail "雛形と一致しない"; fi

it "配置された scripts/check-review-usable.sh は雛形と完全一致する（コピーであって再生成でない）"
if diff -q "$out/$CHECK_USABLE_REL" "$TPL/check-review-usable.sh" >/dev/null 2>&1; then pass; else fail "雛形と一致しない"; fi

it "--with-copilot-review なし（--with-playbook のみ）では配置しない"
out="$(new_workdir)/p"
run_bootstrap "$out" --with-playbook >/dev/null 2>&1
assert_file_absent "$out/$WF_REL"
assert_file_absent "$out/$USABLE_REL"
assert_file_absent "$out/$CHECK_USABLE_REL"

it "--with-copilot 単独（+規範）では配置しない"
# 確認側も要求側と同じ契機で配置する。ローカル装備のフラグでリモート機構が付いて
# くる形へ戻っていないことを、2 本ともで見る（issue #230）。判定スクリプトも
# 同じ契機に従うことを 4 本まとめて見る。
out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot --with-playbook >/dev/null 2>&1
assert_file_absent "$out/$WF_REL"
assert_file_absent "$out/$USABLE_REL"
assert_file_absent "$out/$CHECK_USABLE_REL"

it "--with-copilot-review でも規範を配置しない構成ではエラー終了する"
# 雛形は規範パッケージが持つ。playbook を配置しないなら参照元が無いため、生成物を
# 1 つも書かずに落ちる（書き込み前に落ちることの検査は test-copilot-review.sh 側）。
out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot-review >/dev/null 2>&1
rc=$?
if [[ "$rc" -ne 0 ]]; then pass; else fail "規範なしなのに成功した（exit $rc）"; fi

it "その構成では review-gate.yml も置かれない"
assert_file_absent "$out/$WF_REL"

it "その構成では判定スクリプト 2 本も置かれない"
assert_file_absent "$out/$USABLE_REL"
assert_file_absent "$out/$CHECK_USABLE_REL"

it "dry-run は copilot-review 選択時に review-gate.yml を計画へ含める"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --with-copilot-review --with-playbook --dry-run 2>&1)"
assert_contains "$output" "$WF_REL" "dry-run 計画"

it "dry-run は copilot-review 選択時に判定スクリプト 2 本も計画へ含める"
assert_contains "$output" "$USABLE_REL" "dry-run 計画"
assert_contains "$output" "$CHECK_USABLE_REL" "dry-run 計画"

it "dry-run は copilot-review 未選択なら review-gate.yml を計画へ含めない"
out="$(new_workdir)/p"
output="$(run_bootstrap "$out" --with-copilot --with-playbook --dry-run 2>&1)"
case "$output" in
  *"$WF_REL"*) fail "未選択なのに計画へ現れた" ;;
  *) pass ;;
esac

it "dry-run は copilot-review 未選択なら判定スクリプト 2 本も計画へ含めない"
case "$output" in
  *"$USABLE_REL"*|*"$CHECK_USABLE_REL"*) fail "未選択なのに計画へ現れた" ;;
  *) pass ;;
esac

# ── 確認側が守る不変条件 ──────────────────────────────────────────────────────

out="$(new_workdir)/p"
run_bootstrap "$out" --with-copilot-review --with-playbook >/dev/null 2>&1
wf="$out/$WF_REL"

it "確認側は要求できる権限を持たない（pull-requests は read）"
# 確認側も要求すると、規範の「1 回だけ要求する」が 2 か所から壊れる。コードを
# 読んで「要求していない」ことを確かめるより、**要求できないこと**を権限で押さえる
# ほうが、後から要求を書き足しても崩れない。
if grep -Eq '^[[:space:]]*pull-requests: read' "$wf" \
   && ! grep -Eq '^[[:space:]]*pull-requests: write' "$wf"; then
  pass
else
  fail "permissions の pull-requests が read でない"
fi

it "確認側は reviewers を POST しない"
# 読み取り（GET）は正当なので、エンドポイント名の出現だけでは落とさない。
# 手で要求する手順を案内する echo 行も除く（あれは実行ではなく文言）。
#
# **最終段は `-q` を外し `>/dev/null` で EOF まで読ませる。** 3 段のパイプで
# 最終段が早期終了（`grep -q`）すると、途中の `grep -v` を経由して先頭の
# `grep` まで SIGPIPE が伝播しうる（`set -uo pipefail` の下ではパイプライン
# 全体が非 0 になる）。EOF まで読ませれば、途中の各段が最後まで生産側の
# 出力を受け取り切り、この経路が起きない。
if grep -- '--method POST' "$wf" | grep -v 'echo' | grep 'requested_reviewers' >/dev/null; then
  fail "確認側が requested_reviewers へ POST している（要求してしまっている）"
else
  pass
fi

it "確認側は要求側と別の契機（定期実行）を持つ"
# 同じ契機を見る 2 本目では塞げない。届いていないのはイベントそのものだからである。
if grep -Eq '^[[:space:]]*schedule:' "$wf" && grep -q 'cron:' "$wf"; then
  pass
else
  fail "schedule / cron の契機が無い"
fi

it "schedule 契機は、起動した PR だけでなく open な PR を全件判定し直す"
# schedule が「起動した 1 本だけ」を見る構造だと、この機構が信頼できる根拠
# （規範 review-workflow.md「この機構が保証すること／しないこと」）が崩れる。
# pull_request 契機で捏造された status を上書きできるのは、schedule が
# 「既定ブランチの版で、開いている PR を全件、見落としなく判定し直す」ときだけ
# である。1 本しか見ない、または件数で打ち切る構造では、捏造された緑が次の
# schedule でも上書きされない PR が残りうる。
#
# 「全件」を件数上限の欠如として検査する: open な PR 一覧を取得する**その同じ
# 行**が `gh api --paginate ... pulls?state=open` の形であることを見る
# （`--paginate` と `pulls?state=open` を別々の行に存在すればよいと判定すると、
# たとえば timeline 側の別の `--paginate` 呼び出しにつられて、一覧取得側だけが
# ページングを落としても検出できない）。取得した一覧を `while read` でループ
# しながら 1 本ずつ判定している構造もあわせて見る。
#
# コメント行（`#` で始まる行）は先に除く。このワークフローは「`gh pr list
# --limit N` ではなく `gh api --paginate` を使う」という設計判断を、まさにその
# 語をコメントへ書いて説明している。除かずに検査すると、説明コメントの存在
# そのものに誤って落ちる。
# **`printf ... | grep -q` にしない。** `set -uo pipefail` の下で、$executable_lines
# がパイプバッファに収まりきらない場合、grep が一致直後に読み終えてパイプを閉じ、
# printf が SIGPIPE（141）で落ちて `if` 全体が失敗しうる（同型: #285）。ここでは
# パイプそのものを使わず、herestring（`<<<`）で渡す。herestring は bash が一時
# ファイル経由で読ませる実装のため、消費側の早期終了が生産側の SIGPIPE を引き起こす
# 経路が無い。
executable_lines="$(grep -v '^[[:space:]]*#' "$wf")"
if grep -qE -- '--paginate.*pulls\?state=open' <<< "$executable_lines" \
   && grep -qF 'while read -r pr sha created' "$wf" \
   && ! grep -qF 'gh pr list --limit' <<< "$executable_lines"; then
  pass
else
  fail "schedule 側が open な PR を全件（打ち切りなしで）判定し直す構造になっていない"
fi

it "確認側は PR 更新の契機も持つ（synchronize / reopened / ready_for_review）"
types_line="$(grep -E '^[[:space:]]*types:' "$wf" || true)"
missing=""
for t in opened synchronize reopened ready_for_review; do
  printf '%s' "$types_line" | grep -q "$t" || missing="$missing $t"
done
if [[ -z "$missing" ]]; then pass; else fail "types に不足:$missing"; fi

it "timeline（起きたことの記録）を判定材料に持つ"
# 要求一覧と投稿済み一覧はどちらも「いまの状態」で、レビューが始まってから投稿
# されるまでの間、両方が空になる窓がある。状態しか見ない確認側は、その窓の中で
# 「要求されていない」と誤判定する（規範 review-workflow.md「要求されたことを
# 別の契機で確認する」）。
if grep -qF 'issues/${pr}/timeline' "$wf"; then
  pass
else
  fail "timeline エンドポイントを参照していない"
fi

it "timeline を読む権限を宣言している（issues: read）"
# 隣接する系統の権限でたまたま読めても、宣言を省くと提供側の扱いが変わった日に
# 判定が全 PR で出なくなる。
if grep -Eq '^[[:space:]]*issues: read' "$wf"; then
  pass
else
  fail "permissions に issues: read が無い"
fi

it "確認側は issues への書き込み権限を持たない"
# 確認側は確かめるだけで、PR へ何かを書き足す役ではない。
if grep -Eq '^[[:space:]]*issues: write' "$wf"; then
  fail "permissions に issues: write がある（確認側に書き込みは要らない）"
else
  pass
fi

it "要求の取り消しを勘定に入れる"
# 出来事が残っていることだけを見ると、要求してすぐ取り消しても「要求された」に
# なり、要求を出して消すだけでゲートが外れる。
if grep -qF 'review_request_removed' "$wf"; then
  pass
else
  fail "review_request_removed を見ていない（取り消しを勘定に入れていない）"
fi

it "timeline を読めなかったことを「要求されていない」と混ぜない"
# 3 本目にも、既存の 2 本と同じ第 3 の戻り値（判定保留）が要る。読めなかったことを
# 1（＝落とす）へ落とすと、上の 2 本で避けている偽の赤を 3 本目から作り直す。
if awk '/issues\/\$\{pr\}\/timeline/ { found = 1 }
        found && /return 2/ { hit = 1 }
        found && /^ *fi$/ { exit }
        END { exit !hit }' "$wf"; then
  pass
else
  fail "timeline の取得失敗が return 2（判定保留）へ落ちていない"
fi

it "判定を commit status として書ける権限を持つ"
# ジョブの成否だけでは、定期実行から見た PR に何も現れない。status が出力先である。
if grep -Eq '^[[:space:]]*statuses: write' "$wf"; then
  pass
else
  fail "permissions に statuses: write が無い"
fi

it "判定を head SHA への status として出す"
if grep -qF 'repos/${REPO}/statuses/' "$wf"; then
  pass
else
  fail "statuses エンドポイントへの書き込みが無い"
fi

it "確認側はフォーク PR をスキップする"
# 要求側が対象外にしているものを「要求されていない」と落とすと、恒常的に赤くなる。
if grep -qF 'github.event.pull_request.head.repo.full_name == github.repository' "$wf"; then
  pass
else
  fail "フォーク PR スキップの if 条件が無い"
fi

it "レビュアー名を部分一致で判定しない"
# `*copilot*` で見ると、無関係な利用者がレビュアーに付いただけで緑になる。
if grep -qF 'copilot|"copilot-pull-request-reviewer[bot]") return 0' "$wf"; then
  pass
else
  fail "レビュアー名の完全一致判定が無い"
fi

# ── 2 段目: 「読まれたか」の判定はスクリプトへ委ねている ─────────────────────────

it "既定ブランチから判定コードを取得する（PR のブランチではない）"
# ref を指定しない checkout は pull_request イベントで PR のマージ結果を取得する。
# 判定コードを被検査対象と同じ木から取ると、PR の投稿者が判定スクリプトを書き換える
# だけでゲートを常に緑にできてしまう。
if grep -qF 'ref: ${{ github.event.repository.default_branch }}' "$wf"; then
  pass
else
  fail "checkout が既定ブランチへ固定されていない"
fi

it "判定は scripts/review-usable.sh へ委ねている"
if grep -qF 'scripts/review-usable.sh' "$wf"; then
  pass
else
  fail "scripts/review-usable.sh を呼んでいない"
fi

# ── 導入初回フォールバック ────────────────────────────────────────────────────
#
# 判定コードを既定ブランチから取る設計にしたため、review-gate.yml と
# scripts/review-usable.sh を初めて導入する PR の時点では、既定ブランチにまだ
# 判定コードが無い。resolve_usable_script はこのときだけ PR 自身の写しへ
# フォールバックする（規範 review-workflow.md「要求された ≠ 読まれた」の例外）。
#
# **ここで検査できるのはワークフローの「形」だけである。** 実際の checkout・
# 実際の `gh api` 呼び出し・実際に既定ブランチへ scripts/review-usable.sh が
# 無い状態は、このテストスイート（bootstrap の生成結果を静的に見る）では再現
# できない。以下は「フォールバックの分岐が生成物に存在するか」「既定ブランチを
# 無条件に優先しているか」「フォールバックしたことを黙らせていないか」を文字列と
# 構造で確かめるに留まる。**PR が実際に既定ブランチ側へ再フォールバックせず、
# 既定ブランチにある版を上書きできないことまでは検証していない**（実地の GitHub
# Actions 環境でしか確かめられない）。

it "既定ブランチに判定コードが無いときへの分岐（resolve_usable_script）を持つ"
if grep -qF 'resolve_usable_script()' "$wf"; then
  pass
else
  fail "resolve_usable_script が無い（導入初回フォールバックが実装されていない）"
fi

it "既定ブランチの有無を先に確かめてから分岐している（HAS_MAIN_USABLE）"
# 「既定ブランチにある場合は絶対にフォールバックしない」という制約を、変数 1 つの
# 真偽で判定していることを確かめる。判定条件が PR 側の内容に依存していないことが
# 大事で、それをコード上で表しているのがこの変数の存在である。
if grep -qF 'HAS_MAIN_USABLE=1' "$wf" && grep -qF 'HAS_MAIN_USABLE=0' "$wf"; then
  pass
else
  fail "HAS_MAIN_USABLE の設定が無い（既定ブランチの有無を判定していない）"
fi

it "resolve_usable_script は既定ブランチ優先を先頭で判定している（フォールバックが先に来ない）"
# resolve_usable_script() の**定義そのもの**（呼び出しや、定義に言及するコメントでは
# ない）から、対応する閉じ括弧までの本体だけを、字下げの対応で切り出す。本体の中で
# HAS_MAIN_USABLE の判定が gh api 呼び出し（フォールバック側）より先に現れることを
# 確かめる。順序が逆だと、既定ブランチに判定コードがあってもフォールバックを試みる
# 余地が生まれる。
body="$(awk '
  /^[[:space:]]*resolve_usable_script\(\) \{[[:space:]]*$/ {
    match($0, /^[[:space:]]*/); indent = RLENGTH
    watching = 1; next
  }
  watching && $0 ~ ("^" sprintf("%" indent "s", "") "\\}[[:space:]]*$") { exit }
  watching { print }
' "$wf")"
main_line="$(printf '%s\n' "$body" | grep -n 'HAS_MAIN_USABLE' | head -n1 | cut -d: -f1)"
api_line="$(printf '%s\n' "$body" | grep -n 'gh api' | head -n1 | cut -d: -f1)"
if [ -n "$body" ] && [ -n "$main_line" ] && [ -n "$api_line" ] && [ "$main_line" -lt "$api_line" ]; then
  pass
else
  fail "既定ブランチの判定（HAS_MAIN_USABLE）が gh api 呼び出しより先に来ていない（本体を抽出できなかった可能性もある）"
fi

it "PR 側の写しを取得する API 呼び出しが sha（PR の head）を参照している"
# 既定ブランチ全体を checkout し直すのではなく、判定対象の PR の head から
# scripts/review-usable.sh 1 本だけを取る。掃き寄せ（複数 PR）でも、判定される
# PR ごとに正しい版を引けるようにするため。
if grep -qF 'contents/scripts/review-usable.sh?ref=${sha}' "$wf"; then
  pass
else
  fail "PR の head sha を参照した取得になっていない"
fi

it "フォールバックしたことを ::notice:: で明示している"
if grep -q '::notice::.*review-usable\.sh' "$wf"; then
  pass
else
  fail "フォールバック時の ::notice:: が無い（黙って PR 側のコードで判定してしまう）"
fi

it "フォールバックしたことを commit status の description にも残す"
# ::notice:: はジョブのログにしか残らない。PR の checks 欄だけを見た人にも
# 分かるように、report() へ渡す description にも印を付ける。
if grep -qF 'usable_desc=' "$wf" && grep -q 'report "\$sha" success "Copilot code review is requested or posted\${usable_desc}"' "$wf"; then
  pass
else
  fail "description にフォールバックの印（usable_desc）が乗っていない"
fi

it "定型文の一致判定（1 行も読めなかったレビューの検出）が YAML に書き写されていない"
# review-usable.sh が持つべき判定。YAML に埋め戻すと、手元と CI から機械的に
# 確かめる手段が無くなる（この文字列は review-usable.sh 側の case パターンにだけ
# あるべきで、YAML には無い）。
if grep -qF 't able to review any files"*' "$wf"; then
  fail "定型文の一致判定が YAML に埋め込まれている（review-usable.sh へ委ねるべき）"
else
  pass
fi

it "判定関数（reviewable_patches / posted_review_is_empty）を YAML 内に持たない"
if grep -Eq '(reviewable_patches|posted_review_is_empty)\(\)' "$wf"; then
  fail "判定ロジックが YAML 内の関数として残っている"
else
  pass
fi

it "変更ファイルとレビュー本文の一覧を集めて渡すだけである（判定はしない）"
# gather_files / gather_reviews は「一覧を集めて渡す」役に徹し、patch の有無や
# 定型文かどうかを判定しない。中で is_copilot（発言者の絞り込み）だけを使うのは、
# 「誰の発言か」を狭めるのが呼び出し側の役割だからで、「読めるか」の判定ではない。
if grep -qF 'gather_files()' "$wf" && grep -qF 'gather_reviews()' "$wf"; then
  pass
else
  fail "gather_files / gather_reviews が無い（一覧を集める役割が確認できない）"
fi

it "\$? を \`if !\` の否定越しに拾っていない（2 段目の判定が黙って常に成功する形になっていない）"
# `if ! var=\"\$(cmd)\"; then` の then に入った時点の \$? は `! ...` 自体の評価結果
# （常に 0）で、cmd が返した値ではない（実測: bash で
# `f(){ return 3; }; if ! out=\"\$(f)\"; then rc=\$?; fi` は rc=0 になる）。
#
# **shellcheck（この検査を書いた時点で手元にあった 0.11.0）はこの形を検出しない**
# ことを、既知の誤検出パターンと修正後の形の両方に対して実行して確かめた。SC2319
# （\"This \$? refers to a condition, not a command.\"）が謳い文句どおりに働くなら
# 検出できてよいはずの形だが、この版では複数のバリエーション（単純コマンド／
# コマンド置換代入／while／case、いずれも試した）のどれでも指摘が出なかった。
# この静的解析ツールに頼ると「検査を足したのに検出できない」を積むことになるため、
# ここで直接パターンを検査する。
#
# 判定は「`if ! ` を含む行から、同じ字下げの \`fi\` が現れるまでの範囲に \`=\$?\` が
# あるか」。この形の bash はこのリポジトリの流儀で `if` と対応する `fi` が同じ字下げに
# 揃う（本ファイル・review-usable.sh とも一貫している）ため、字下げの対応で block を
# 区切れば足りる。汎用の bash パーサではないため、字下げが崩れた入力までは保証しない。
#
# コメント行（\`#\` で始まる行）は先に読み飛ばす。このアンチパターンを説明する
# コメント自体が \`if ! ... then rc=\$?\` を例として書くため、読み飛ばさないと
# 説明文を実装だと誤認して自分自身に落ちる（実際にこの検査を書く過程で踏んだ）。
#
# **\`if ! \` にマッチした行そのものは、マッチした直後に \`next\` していたため
# \`=\$?\` の検査にかからなかった。** \`if ! out=\"\$(cmd)\"; then rc=\$?; fi\` の
# ように 1 行に収めた形（複数行に分けた形と意味は同じ）がこの穴を素通りする
# ことを実測した（このバグを含む検査自体を最初に書いたときに実際に踏んだ）。
# **1 行の中で先に \`=\$?\` を見てから\`next\`する**よう直し、同一行・複数行の
# 両方で検出できることを確かめてある。あわせて、1 行内で \`; fi\` まで閉じている
# 形（監視すべき後続行が無い）では \`watching\` を立てない——立てたままにすると、
# 対応する \`fi\` が見つからず監視状態が漏れ、無関係な後続の正しい \`|| var=\$?\`
# まで誤検出しうる。
if awk '
  /^[[:space:]]*#/ { next }
  /if ! / {
    if ($0 ~ /=\$\?/) { hit = 1 }
    if ($0 ~ /;[[:space:]]*fi[[:space:]]*$/) { next }
    match($0, /^[[:space:]]*/)
    indent = RLENGTH
    watching = 1
    next
  }
  watching && $0 ~ ("^" sprintf("%" indent "s", "") "fi[[:space:]]*$") {
    watching = 0
    next
  }
  watching && /=\$\?/ {
    hit = 1
  }
  END { exit !hit }
' "$wf"; then
  fail "\`if !\` の否定越しに \$? を拾っている箇所がある（\`|| var=\$?\` の形へ直す）"
else
  pass
fi

# ── 文書が書く再判定の間隔と cron の一致 ──────────────────────────────────────
#
# 規範 review-workflow.md「この機構が保証すること／しないこと: run: ブロック
# そのものの書き換え」は、「捏造された status は次の schedule で上書きされる」
# 「ただし上書きまで最大 20 分は捏造された緑が見える」という、schedule の間隔に
# 依存した記述を持つ。この間隔は review-gate.yml の cron が決めており、文書は
# それを書き写した数値である。片方だけを変えると、記述と実装が黙ってずれる
# ——このテストはそれを機械で照合する。
#
# ここに置く理由: この照合は .ai-playbook 配布物の内部（雛形のコメントと規範
# 文書）だけで完結し、bootstrap.sh の生成結果や tests/test-workflow-mirror.sh が
# 見ている「開発リポジトリの写しとの一致」とは対象が異なる。tests/ 配下の
# 各テストは repo 内の写し（.github/workflows/ 等）と .ai-playbook の一致を見る
# 役割で揃っており、そこへ足すと「雛形と写しの一致」と「雛形と文書の一致」という
# 別種の照合が 1 ファイルへ混ざる。本ファイル（test-review-gate.sh）は既に
# $TPL/review-gate.yml（雛形そのもの）を対象に構造を検査しているため、同じ
# 雛形を対象にする以上の照合はここへ集める方が、落ちたときに直す先が
# 「review-gate.yml 周りの雛形」で一貫する。
#
# 照合の方法: 文書と雛形の双方から `cron: '*/N * * * *'` の形をそのまま抜き出し、
# 文字列として比較する。分の数値だけを Japanese の「N 分ごと」表現から抜き出す
# より、cron の記法そのものを文書に引用させて突き合わせるほうが、表現の揺れ
# （「20 分ごと」「20分間隔」等）に頼らず機械的に一致を強制できる。
#
# **雛形側は、実際の `on.schedule` の YAML sequence entry（`- cron: '...'` の形で
# 行頭からその形に始まる行）だけを対象にする。** 雛形はコメント中でも同じ cron 値を
# 引用しており（信頼境界の説明）、その部分文字列も無条件に拾うと、`on.schedule` の
# `- cron:` 行そのものを消してもコメント側の言及が残っているだけで一致してしまい、
# schedule が消えたことを検出できない。行頭アンカー（`^[[:space:]]*- cron: `）で
# 実際の定義行だけに絞ってから値を取り出す。
#
# 文書側（review-workflow.md）は Markdown の地の文への引用であり、YAML の
# sequence entry という構造を持たない。そのため文書側は従来どおり、値の部分文字列
# が現れる行であれば拾う（＝コメント相当の扱いで構わない、という判断は指摘のとおり）。
it "文書（review-workflow.md）が書く schedule の cron と、雛形（review-gate.yml）の cron が一致する"
DOC_CRON="$(grep -oE "cron: '\*/[0-9]+ \* \* \* \*'" "$PLAYBOOK_SRC/review-workflow.md" | sort -u)"
TPL_CRON="$(grep -E "^[[:space:]]*- cron: '\*/[0-9]+ \* \* \* \*'" "$TPL/review-gate.yml" \
  | grep -oE "cron: '\*/[0-9]+ \* \* \* \*'" | sort -u)"
doc_count="$(printf '%s\n' "$DOC_CRON" | grep -c .)"
tpl_count="$(printf '%s\n' "$TPL_CRON" | grep -c .)"
if [[ "$doc_count" -eq 0 ]]; then
  fail "review-workflow.md に cron: '*/N * * * *' の形の記述が無い（文書が具体的な間隔を引用していない）"
elif [[ "$tpl_count" -eq 0 ]]; then
  fail "$TPL/review-gate.yml に cron: '*/N * * * *' の形の記述が無い"
elif [[ "$doc_count" -ne 1 ]]; then
  fail "review-workflow.md に cron 表記が複数の異なる値で現れる（1 つに揃っていない）: $(printf '%s' "$DOC_CRON" | tr '\n' ' ')"
elif [[ "$tpl_count" -ne 1 ]]; then
  fail "$TPL/review-gate.yml に cron 表記が複数ある（on: の cron と一致しているか確認）: $(printf '%s' "$TPL_CRON" | tr '\n' ' ')"
elif [[ "$DOC_CRON" == "$TPL_CRON" ]]; then
  pass
else
  fail "文書と雛形で cron の値がずれている（文書: ${DOC_CRON} / 雛形: ${TPL_CRON}）"
fi

# ── YAML として妥当である ─────────────────────────────────────────────────────
# actionlint があれば通す。無ければ PyYAML、それも無ければ最低限の構造検査で代替する
# （沈黙スキップはしない）。test-copilot-review.sh と同じ段構え。

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
