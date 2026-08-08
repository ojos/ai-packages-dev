#!/usr/bin/env bash
# 生成される scripts/loop-gate.sh の「第二意見へ渡す範囲」の決め方を検証する。
#
# 背景:
#   範囲は @{upstream}..HEAD を既定とするが、これは 2 点間の比較なので、
#   ベースブランチ（既定ブランチ）を取り込んだ直後は取り込んだ側のコミットが
#   まるごと差分へ入る。それは既にレビューを通った他ブランチの成果であって、
#   このブランチが加えた変更ではない。範囲が既定ブランチへ到達可能なコミットを
#   含むときは分岐点（merge-base）まで戻す。
#
#   判定は「マージコミットを含むか」ではなく到達可能性で行う。取り込み方によって
#   現れる形が違い（merge / fast-forward / rebase）、形ごとに書き分けるほど
#   取りこぼすため。fast-forward の取り込みはマージコミットを作らないので、
#   形で判定する実装なら素通りする（下の該当ケースが回帰として押さえている）。
#
# 検証の仕方:
#   loop-gate.sh は source ガードを持ち、読み込まれただけならゲート本体を実行
#   しない。ここでは使い捨ての git リポジトリへ cd してから resolve_review_range
#   を単体で呼び、決まった範囲・理由を読み取る。verify も第二意見も動かさないので
#   ネットワークにも外部 CLI にも依存しない。
#
#   source ガードは取り違えると「何も検証しないまま終了コード 0」という偽の緑を
#   作る。ガードが効いていること（source では走らない）と、効きすぎていないこと
#   （実行すればゲートが走り、合否がそのまま出る）を両方向で検査する。
#
# 配布方針:
#   このテストは生成先へ配らない。生成先の scripts/ はプロジェクトが所有する
#   運用スクリプトの置き場で、配布物の内部実装に対する回帰テストを持たせる場所
#   ではない。範囲選択の正しさはここで担保する（bootstrap.sh の該当箇所にも
#   同じ判断を記録している）。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-loop-gate-range"

# 検証対象は生成物。正本（bootstrap.sh のヒアドキュメント）との一致は
# test-loop-support.sh と tests/test-template-mirror.sh が別途担保している。
GEN="$(new_workdir)/p"
run_bootstrap "$GEN" >/dev/null 2>&1
GATE="$GEN/scripts/loop-gate.sh"

it "検証対象の loop-gate.sh が生成されている"
assert_file_exists "$GATE"

# コミット時の identity は明示する。実行者の global 設定に依存させない。
GIT_AUTHOR='-c user.name=T -c user.email=t@example.com'

# 使い捨ての git リポジトリと bare の origin を作り、既定ブランチ名 $3 を
# push 済みにする。origin/HEAD は clone 以外では自動で作られないため、
# 必要なケースだけ呼び出し側が set-head する。
mk_repo() {
  local repo="$1" origin="$2" trunk="$3"
  git init -q --bare "$origin" >/dev/null 2>&1
  mkdir -p "$repo"
  (
    cd "$repo" || exit 1
    git init -q
    # 既定ブランチ名は git のバージョン・設定で変わるため明示する。
    git symbolic-ref HEAD "refs/heads/$trunk"
    printf 'a\n' > base.txt
    git add base.txt
    # shellcheck disable=SC2086
    git $GIT_AUTHOR commit -q -m a
    git remote add origin "$origin"
    git push -q -u origin "$trunk"
  ) >/dev/null 2>&1
}

# リポジトリ内でコマンド列を静かに実行する。
in_repo() {
  local repo="$1" cmd="$2"
  ( cd "$repo" && eval "$cmd" ) >/dev/null 2>&1
}

# 使い捨てリポジトリの中で resolve_review_range を呼び、決定結果を返す。
#
#   RANGE:<範囲>      … 第二意見へ渡す範囲（空なら reviewer の既定へ委ねる）
#   NO_TARGET:<0|1>   … レビューできる差分が無い
#   REASON:<理由>     … 上流以外を起点に採った理由（空なら上流をそのまま採用）
#   CWD_MOVED:<0|1>   … source が呼び出し元の作業ディレクトリを動かしたか
#
# $0 は "_" になるため source ガードが効き、ゲート本体は走らない。
run_resolve() {
  local repo="$1"
  bash -c '
    cd "$1" || exit 1
    before="$PWD"
    . "$2"
    printf "RANGE:%s\n" "$REVIEW_RANGE"
    printf "NO_TARGET:%s\n" "$REVIEW_NO_TARGET"
    if [ "$PWD" = "$before" ]; then printf "CWD_MOVED:0\n"; else printf "CWD_MOVED:1\n"; fi
    resolve_review_range
    printf "RANGE:%s\n" "$REVIEW_RANGE"
    printf "NO_TARGET:%s\n" "$REVIEW_NO_TARGET"
    printf "REASON:%s\n" "$REVIEW_RANGE_REASON"
  ' _ "$repo" "$GATE" 2>&1
}

# run_resolve の出力から最後の値を取る（source 直後の初期値も同じ鍵で出るため）。
field() {
  printf '%s\n' "$1" | sed -n "s/^$2://p" | tail -1
}

# ── 上流あり・汚染なし ────────────────────────────────────────────────────────

it "上流あり・既定ブランチを取り込んでいなければ upstream..HEAD を使う"
repo="$(new_workdir)/clean"
mk_repo "$repo" "$(new_workdir)/origin.git" main
in_repo "$repo" "git remote set-head origin main"
in_repo "$repo" "git checkout -q -b feat && printf 'c1\n' > f1.txt && git add f1.txt && git $GIT_AUTHOR commit -q -m c1 && git push -q -u origin feat"
in_repo "$repo" "printf 'c2\n' > f2.txt && git add f2.txt && git $GIT_AUTHOR commit -q -m c2"
out_txt="$(run_resolve "$repo")"
assert_eq "$(field "$out_txt" RANGE)" "origin/feat..HEAD" "汚染なしの範囲"

it "汚染なしのときは範囲変更の理由を出さない"
# 理由は「上流以外を起点に採った」ことの説明。既定どおりなら出さない。
assert_eq "$(field "$out_txt" REASON)" "" "汚染なしの理由"

# ── 上流あり・既定ブランチをマージ済み ────────────────────────────────────────

it "既定ブランチをマージした範囲は分岐点起点へ落とす"
repo="$(new_workdir)/merged"
mk_repo "$repo" "$(new_workdir)/origin.git" main
in_repo "$repo" "git remote set-head origin main"
in_repo "$repo" "git checkout -q -b feat && printf 'c1\n' > f1.txt && git add f1.txt && git $GIT_AUTHOR commit -q -m c1 && git push -q -u origin feat"
# 既定ブランチが進む（他ブランチの成果が main へ入った状態）。
in_repo "$repo" "git checkout -q main && printf 'b\n' > main-only.txt && git add main-only.txt && git $GIT_AUTHOR commit -q -m b && git push -q origin main"
in_repo "$repo" "git checkout -q feat && git $GIT_AUTHOR merge -q --no-edit origin/main"
out_txt="$(run_resolve "$repo")"
mb="$(cd "$repo" && git merge-base origin/HEAD HEAD)"
assert_eq "$(field "$out_txt" RANGE)" "$mb..HEAD" "マージ済みブランチの範囲"

it "分岐点起点にした理由を出力する"
# 黙って範囲を変えると、なぜその差分がレビュー対象なのかを読み手が追えない。
assert_contains "$(field "$out_txt" REASON)" "already reachable from" "範囲変更の理由"

it "分岐点起点にすると、取り込んだ他ブランチの成果が範囲から外れる"
# これが目的。origin/feat..HEAD のままだと main 側の main-only.txt が差分に入る。
names="$(cd "$repo" && git diff --name-only "$(field "$out_txt" RANGE)" | tr '\n' ',')"
if printf '%s' "$names" | grep -q 'main-only.txt'; then
  fail "他ブランチの成果が範囲へ残っている: $names"
elif printf '%s' "$names" | grep -q 'f1.txt'; then
  pass
else
  fail "このブランチ自身の変更が範囲から落ちている: $names"
fi

it "上流のままなら他ブランチの成果を巻き込むことを、同じ状態で確認する"
# 修正前の挙動を回帰の対照として明示しておく。ここが巻き込まないなら、
# 上のケースは「たまたま」通っていることになる。
names="$(cd "$repo" && git diff --name-only origin/feat..HEAD | tr '\n' ',')"
assert_contains "$names" "main-only.txt" "上流起点の差分"

# ── 上流あり・fast-forward で取り込み済み（マージコミットが無い） ─────────────

it "fast-forward で取り込んだ場合も汚染として扱う"
# マージコミットが 1 つも作られない取り込み方。「マージコミットを含むか」で
# 判定する実装はここを素通りし、他ブランチの成果をレビュー対象にしてしまう。
# 到達可能性で見れば取り込み方に依らない。
repo="$(new_workdir)/ff"
mk_repo "$repo" "$(new_workdir)/origin.git" main
in_repo "$repo" "git remote set-head origin main"
in_repo "$repo" "git checkout -q -b follow && git push -q -u origin follow"
in_repo "$repo" "git checkout -q main && printf 'b\n' > main-only.txt && git add main-only.txt && git $GIT_AUTHOR commit -q -m b && git push -q origin main"
in_repo "$repo" "git checkout -q follow && git merge -q --ff-only origin/main"
out_txt="$(run_resolve "$repo")"
# 取り込みしかしていないブランチなので、分岐点は既定ブランチの先端まで進み、
# このブランチ自身の変更は 1 行も残らない。
if [[ "$(field "$out_txt" RANGE)" == "" && "$(field "$out_txt" NO_TARGET)" == "1" ]]; then
  pass
else
  fail "fast-forward 取り込みで他ブランチの成果を対象にしている: $out_txt"
fi

# ── 上流あり・squash で取り込み済み ───────────────────────────────────────────

it "squash で取り込んだ後も分岐点起点になる"
# squash 取り込みは新しいコミットを 1 つ作るだけで、既定ブランチへの到達可能性を
# 生まない。したがって到達可能性の判定では汚染として検出できない。ここで分岐点
# 起点になるのは、取り込み後に push して上流との差分が空になる経路による。
#
# 取り込んだ内容自体は分岐点起点の範囲にも残る（squash は履歴上の繋がりを残さない
# ため、どの起点を選んでも差分から外れない）。範囲の選び方だけでは解けない制約で、
# 検出したい場合は取り込みを merge / rebase で行う必要がある。
repo="$(new_workdir)/squash"
mk_repo "$repo" "$(new_workdir)/origin.git" main
in_repo "$repo" "git remote set-head origin main"
in_repo "$repo" "git checkout -q -b feat && printf 'c1\n' > f1.txt && git add f1.txt && git $GIT_AUTHOR commit -q -m c1 && git push -q -u origin feat"
in_repo "$repo" "git checkout -q main && printf 'b\n' > main-only.txt && git add main-only.txt && git $GIT_AUTHOR commit -q -m b && git push -q origin main"
in_repo "$repo" "git checkout -q feat && git merge -q --squash origin/main && git $GIT_AUTHOR commit -q -m squash-import && git push -q origin feat"
out_txt="$(run_resolve "$repo")"
mb="$(cd "$repo" && git merge-base origin/HEAD HEAD)"
assert_eq "$(field "$out_txt" RANGE)" "$mb..HEAD" "squash 取り込み後の範囲"

# ── 上流あり・上流との差分が空（push 済み） ───────────────────────────────────

it "上流との差分が空なら分岐点起点へ落とす"
repo="$(new_workdir)/pushed"
mk_repo "$repo" "$(new_workdir)/origin.git" main
in_repo "$repo" "git remote set-head origin main"
in_repo "$repo" "git checkout -q -b feat && printf 'c1\n' > f1.txt && git add f1.txt && git $GIT_AUTHOR commit -q -m c1 && git push -q -u origin feat"
out_txt="$(run_resolve "$repo")"
mb="$(cd "$repo" && git merge-base origin/HEAD HEAD)"
assert_eq "$(field "$out_txt" RANGE)" "$mb..HEAD" "push 済みブランチの範囲"

it "上流との差分が空だったことを理由として出力する"
assert_contains "$(field "$out_txt" REASON)" "no diff" "push 済みの理由"

# ── 上流なし ──────────────────────────────────────────────────────────────────

it "上流が無ければ分岐点起点にする"
repo="$(new_workdir)/no-upstream"
mk_repo "$repo" "$(new_workdir)/origin.git" main
in_repo "$repo" "git remote set-head origin main"
in_repo "$repo" "git checkout -q -b feat && printf 'c1\n' > f1.txt && git add f1.txt && git $GIT_AUTHOR commit -q -m c1"
out_txt="$(run_resolve "$repo")"
mb="$(cd "$repo" && git merge-base origin/HEAD HEAD)"
assert_eq "$(field "$out_txt" RANGE)" "$mb..HEAD" "上流なしの範囲"

it "上流が無いことを理由として出力する"
assert_contains "$(field "$out_txt" REASON)" "no upstream" "上流なしの理由"

# ── 既定ブランチの追跡枝が無い ────────────────────────────────────────────────

it "既定ブランチを解決できない環境では従来どおり上流を使う"
# 汚染判定の起点が無いので判定できない。ここで汚染ありと扱うと、分岐点も取れない
# まま範囲を失う。判定不能は「汚染なし」へ倒す。
repo="$(new_workdir)/no-base"
mk_repo "$repo" "$(new_workdir)/origin.git" trunk
in_repo "$repo" "printf 'c1\n' > f1.txt && git add f1.txt && git $GIT_AUTHOR commit -q -m c1"
out_txt="$(run_resolve "$repo")"
assert_eq "$(field "$out_txt" RANGE)" "origin/trunk..HEAD" "既定ブランチ無しの範囲"

it "既定ブランチを解決できない環境で origin/HEAD 等が実在しないことを確かめる"
# 上のケースが「たまたま上流を採った」のではなく、前提どおり既定ブランチの
# 追跡枝が無い状態であることを固定する。
found=""
for b in origin/HEAD origin/main origin/master; do
  ( cd "$repo" && git rev-parse --verify --quiet "$b" >/dev/null ) && found="$found $b"
done
assert_eq "$found" "" "解決できてしまった既定ブランチ"

# ── source ガード ─────────────────────────────────────────────────────────────

it "source しただけではゲート本体が走らない"
# ガードが無いと、テストが読み込んだだけで verify と第二意見が走り出す。
# 上の各ケースの出力にゲートの痕跡が混じっていないことで確認する。
src_txt="$(run_resolve "$repo")"
if printf '%s' "$src_txt" | grep -q '\[loop-gate\]\|GATE_PASS\|GATE_FAIL'; then
  fail "source だけでゲート本体が走っている: $src_txt"
else
  pass
fi

it "source は呼び出し元の作業ディレクトリを動かさない"
# cd をゲート本体側へ置いていないと、使い捨てリポジトリへ cd してから関数を
# 呼ぶ検証ができない（範囲が生成物のルート基準で解決されてしまう）。
assert_eq "$(field "$src_txt" CWD_MOVED)" "0" "source 後の作業ディレクトリ"

it "source すると範囲解決の関数が定義される"
fn_txt="$(bash -c '. "$1" && declare -F resolve_review_range resolve_integration_base range_includes_base_commits >/dev/null && echo DEFINED' _ "$GATE" 2>&1)"
assert_contains "$fn_txt" "DEFINED" "関数定義"

# ── ガードが効きすぎていないこと（偽の緑の検出） ──────────────────────────────
#
# source ガードの入れ方を誤ると、実行してもゲート本体が呼ばれず、何も検証しない
# まま終了コード 0 になる。「出力が無く exit 0」は緑と見分けが付かないため、
# 実行時に合否がそのまま現れることを両方向で確認する。

it "実行するとゲート本体が走り、合格なら GATE_PASS を出して 0 で終わる"
acc_pass="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc_pass"
if out_txt="$(cd "$GEN" && VERIFY_ACCEPTANCE="$acc_pass" LOOP_GATE_REVIEW_CMD='' bash scripts/loop-gate.sh 2>&1)"; then
  if printf '%s' "$out_txt" | grep -q '\[loop-gate\] step 1' \
     && printf '%s' "$out_txt" | grep -q 'GATE_PASS'; then
    pass
  else
    fail "実行してもゲート本体が走っていない（偽の緑）: $out_txt"
  fi
else
  fail "合格条件なのに exit 非 0: $out_txt"
fi

it "実行して不合格なら GATE_FAIL を出して非 0 で終わる"
acc_fail="$(new_workdir)/acc-fail.sh"; printf '#!/usr/bin/env bash\nexit 1\n' > "$acc_fail"
if out_txt="$(cd "$GEN" && VERIFY_ACCEPTANCE="$acc_fail" LOOP_GATE_REVIEW_CMD='' bash scripts/loop-gate.sh 2>&1)"; then
  fail "不合格なのに exit 0（偽の緑）: $out_txt"
else
  assert_contains "$out_txt" "GATE_FAIL" "不合格時の出力"
fi

# ── 理由がゲートの出力へ実際に現れること ──────────────────────────────────────

it "ゲートを実行すると、分岐点起点にした理由が出力へ現れる"
# 変数へ入っているだけでは読み手に届かない。第二意見へ渡す範囲と並べて 1 行出す。
e2e="$(new_workdir)/p"
run_bootstrap "$e2e" >/dev/null 2>&1
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
cat > "$e2e/scripts/gemini-review.sh" <<'STUB'
#!/usr/bin/env bash
echo "REVIEW_ARGV:$*"
if [[ "${1-}" == "--range" ]]; then
  echo "REVIEW_DIFF_NAMES:$(git diff --name-only "$2" | tr '\n' ',')"
fi
exit 0
STUB
chmod +x "$e2e/scripts/gemini-review.sh"
origin="$(new_workdir)/origin.git"
git init -q --bare "$origin" >/dev/null 2>&1
in_repo "$e2e" "git init -q && git symbolic-ref HEAD refs/heads/main && git add -A && git $GIT_AUTHOR commit -q -m c1 && git remote add origin '$origin' && git push -q -u origin main && git remote set-head origin main"
in_repo "$e2e" "git checkout -q -b feat && printf 'feature\n' > FEATURE.txt && git add FEATURE.txt && git $GIT_AUTHOR commit -q -m c2 && git push -q -u origin feat"
in_repo "$e2e" "git checkout -q main && printf 'other\n' > OTHER.txt && git add OTHER.txt && git $GIT_AUTHOR commit -q -m c3 && git push -q origin main"
in_repo "$e2e" "git checkout -q feat && git $GIT_AUTHOR merge -q --no-edit origin/main"
if out_txt="$(cd "$e2e" && VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  names="$(printf '%s' "$out_txt" | sed -n 's/^REVIEW_DIFF_NAMES://p')"
  if ! printf '%s' "$out_txt" | grep -q '\[loop-gate\].*already reachable from'; then
    fail "範囲を変えた理由が出力されない: $out_txt"
  elif printf '%s' "$names" | grep -q 'OTHER.txt'; then
    fail "他ブランチの成果が第二意見へ渡っている: $names"
  elif printf '%s' "$names" | grep -q 'FEATURE.txt' && printf '%s' "$out_txt" | grep -q 'GATE_PASS'; then
    pass
  else
    fail "このブランチの変更が第二意見へ渡っていない: $out_txt"
  fi
else
  fail "全段合格なのに exit 非 0: $out_txt"
fi

exit_with_result
