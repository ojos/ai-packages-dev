#!/usr/bin/env bash
# ループコーディング支援の実行体（verify / acceptance / loop-gate）を検証する。
#
# 規範（受け入れ検証の機械ゲート化・収束・verify ランナー契約）は ai-playbook の
# loop-workflow.md が正本であり、ここではその「実行側の機構」を検証する。
# 重要な不変条件は次の 2 点:
#   1. DCB 単体で動作する（外部規範パッケージの導入を前提にしない）。
#   2. 純粋な機構であり、規範文言・規範パッケージの内部パスを複製しない。
#
# ネットワークには出ない。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-loop-support"

# 生成直後のプロジェクトを git 管理下へ置き、生成物を 1 コミットする。
#
# 生成される verify.sh は受け入れ条件の手前で scripts/check-no-secrets.sh を呼び、
# あちらは「git の作業ツリーでない」「追跡ファイルが 1 件も無い」を検査が成立して
# いない状態として落とす（機密が無いことと、検査していないことは別であるため）。
# verify / loop-gate の通過を検証するケースは、まずこの前提を満たしてから回す。
# 機密混入検査そのものの挙動は test-check-no-secrets.sh が検証する。
make_tracked_repo() {
  local repo="$1"
  (
    cd "$repo" || exit 1
    git init -q
    # 既定ブランチ名は git のバージョン・設定で変わるため明示する。
    git symbolic-ref HEAD refs/heads/main
    git add -A
    git -c user.name=T -c user.email=t@example.com commit -q -m c1
  ) >/dev/null 2>&1
}

# make_tracked_repo / make_pushed_repo が固定するコミット author。loop-gate.sh の
# step 1（verify-commit-identity.sh）は fail-closed のため、この email を許可 email
# として渡さないと、identity 検査で必ず落ちて後続の段（verify / 第二意見）まで
# 進まない。GATE_PASS を期待するケースでは ALLOWED_AUTHOR_EMAILS="$ALLOWED_EMAIL" を
# 起動時に渡すこと。
ALLOWED_EMAIL="t@example.com"

# ── 生成物の存在（mode 非依存で常に生成） ─────────────────────────────────────

it "verify / acceptance / loop-gate が生成される"
missing=""
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
for s in verify.sh acceptance.sh loop-gate.sh; do
  [[ -f "$out/scripts/$s" ]] || missing="$missing $s"
done
if [[ -z "$missing" ]]; then pass; else fail "生成漏れ:$missing"; fi

it "生成スクリプトは有効な bash 構文"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
bad=""
for s in verify.sh acceptance.sh loop-gate.sh; do
  bash -n "$out/scripts/$s" 2>/dev/null || bad="$bad $s"
done
if [[ -z "$bad" ]]; then pass; else fail "構文エラー:$bad"; fi

it "生成スクリプトは実行可能（755）"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
assert_mode "$out/scripts/verify.sh" "755"

# ── acceptance の言語別既定 ───────────────────────────────────────────────────

it "node 選択時は acceptance に npm test が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
if grep -q 'npm test' "$out/scripts/acceptance.sh"; then pass; else fail "npm test が無い"; fi

it "rust 選択時は acceptance に cargo test が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages rust >/dev/null 2>&1
if grep -q 'cargo test' "$out/scripts/acceptance.sh"; then pass; else fail "cargo test が無い"; fi

it "go 選択時は acceptance に go test ./... が入る"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages go >/dev/null 2>&1
if grep -q 'go test ./\.\.\.' "$out/scripts/acceptance.sh"; then pass; else fail "go test 行が無い"; fi

it "非選択言語の検証行は acceptance に入らない（node のみ選択時）"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
if grep -qE 'cargo test|go test|pytest|composer test' "$out/scripts/acceptance.sh"; then
  fail "非選択言語の検証行が混入"
else
  pass
fi

it "acceptance にプレースホルダが残留しない"
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node,rust >/dev/null 2>&1
if grep -q '__ACCEPTANCE_CHECK_LINES__' "$out/scripts/acceptance.sh"; then fail "未置換プレースホルダが残留"; else pass; fi

# ── acceptance のマニフェスト検出ガード（存在する対象だけ検証・0 件なら失敗） ──

it "マニフェストの無い言語の検証はスキップし、その旨を出力する"
# node のみ選択・ルート直下に package.json 不在 → node は skip される（skip 自体は失敗ではない）。
# ただし対象が node だけで ran_any=0 のため、acceptance 全体は末尾で非 0 終了する。ここでは
# skip メッセージの出力のみを検証する目的なので、終了コードは `|| true` で意図的に無視する。
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
out_txt="$(cd "$out" && bash scripts/acceptance.sh 2>&1)" || true
assert_contains "$out_txt" "skip: package.json not found" "acceptance 出力"

it "1 つも検証を実行できなければ非 0 で終了し、受け入れ条件が未定義である旨を出力する"
# マニフェストを 1 つも置かない複数言語 → すべて skip → ran_any=0 → 非 0。
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node,go,python >/dev/null 2>&1
if out_txt="$(cd "$out" && bash scripts/acceptance.sh 2>&1)"; then
  fail "検証対象が無いのに合格した: $out_txt"
else
  assert_contains "$out_txt" "受け入れ条件が未定義" "acceptance 出力"
fi

it "マニフェストはあるがツールが無い場合は導入手順を添えて非 0 で終了する"
# ルートに package.json を置き、dirname だけを通す最小 PATH で npm を不在化する
# （script が使う外部コマンドは dirname のみ。cd/pwd/command/echo は組み込み）。
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
printf '{}\n' > "$out/package.json"
stub="$(new_workdir)/bin"; mkdir -p "$stub"
ln -s "$(command -v dirname)" "$stub/dirname"
bashbin="$(command -v bash)"
if out_txt="$(cd "$out" && PATH="$stub" "$bashbin" scripts/acceptance.sh 2>&1)"; then
  fail "ツール不在なのに合格した: $out_txt"
else
  if printf '%s' "$out_txt" | grep -q 'npm not found' && printf '%s' "$out_txt" | grep -qi 'install'; then
    pass
  else
    fail "導入手順付きのツール不在エラーが出ていない: $out_txt"
  fi
fi

it "acceptance は起動時 CWD に依存しない（サブディレクトリからルートのマニフェストを解決する）"
# 回帰: マニフェスト検出は cwd 相対ではなくスクリプト位置基準でルートへ cd すること。
out="$(new_workdir)/p"
run_bootstrap "$out" --languages node >/dev/null 2>&1
printf '{}\n' > "$out/package.json"   # ルート直下のマニフェスト
sub="$out/nested/dir"; mkdir -p "$sub"
out_txt="$(cd "$sub" && bash "$out/scripts/acceptance.sh" 2>&1)" || true
if printf '%s' "$out_txt" | grep -q 'skip: package.json not found' \
   || printf '%s' "$out_txt" | grep -q '受け入れ条件が未定義'; then
  fail "サブディレクトリ起動でルートのマニフェストを解決できていない: $out_txt"
else
  pass
fi

it "--languages の各組み合わせで生成 acceptance.sh が bash -n を通る"
bad=""
for c in node go python php rust ruby node,go node,go,python,php,rust,ruby python,rust ruby,node; do
  o="$(new_workdir)/p"
  run_bootstrap "$o" --languages "$c" >/dev/null 2>&1
  bash -n "$o/scripts/acceptance.sh" 2>/dev/null || bad="$bad $c"
done
if [[ -z "$bad" ]]; then pass; else fail "構文エラー:$bad"; fi

# ── 単体動作の不変条件（規範パッケージ非依存・機構のみ） ──────────────────────

it "verify / loop-gate / acceptance は規範パッケージの内部パス・文言を複製しない"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
leak=""
for s in verify.sh loop-gate.sh acceptance.sh; do
  if grep -qE '\.ai-playbook|role-contracts|task-playbooks|shared-ai-rules|致命バグ' "$out/scripts/$s"; then
    leak="$leak $s"
  fi
done
if [[ -z "$leak" ]]; then pass; else fail "規範の複製が混入:$leak"; fi

# ── verify の接地信号（機械ゲート） ───────────────────────────────────────────

it "acceptance 合格で verify は VERIFY_PASS / exit 0"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
make_tracked_repo "$out"
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
if out_txt="$(cd "$out" && VERIFY_ACCEPTANCE="$acc" bash scripts/verify.sh 2>&1)"; then
  assert_contains "$out_txt" "VERIFY_PASS" "verify 出力"
else
  fail "合格なのに exit 非 0: $out_txt"
fi

it "acceptance 未定義で verify は VERIFY_FAIL / exit 1"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
if out_txt="$(cd "$out" && VERIFY_ACCEPTANCE="/nonexistent/acc.sh" bash scripts/verify.sh 2>&1)"; then
  fail "未定義なのに通過してしまった: $out_txt"
else
  assert_contains "$out_txt" "VERIFY_FAIL" "verify 出力"
fi

# ── loop-gate の合成（単体 + 第二意見） ───────────────────────────────────────

it "単体（第二意見なし）: acceptance 合格で GATE_PASS / exit 0、第二意見は SKIP"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
make_tracked_repo "$out"
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
if out_txt="$(cd "$out" && ALLOWED_AUTHOR_EMAILS="$ALLOWED_EMAIL" VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  if printf '%s' "$out_txt" | grep -q 'GATE_PASS' && printf '%s' "$out_txt" | grep -qi 'SKIP'; then
    pass
  else
    fail "GATE_PASS/SKIP が揃わない: $out_txt"
  fi
else
  fail "合格なのに exit 非 0: $out_txt"
fi

it "プロジェクトルート以外の作業ディレクトリから起動しても既定 acceptance を解決する"
# 回帰: verify/loop-gate は cwd 相対ではなくスクリプト位置基準でルートへ cd すること。
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
# 既定パス（scripts/acceptance.sh）を通す stub に差し替え、VERIFY_ACCEPTANCE は使わない
printf '#!/usr/bin/env bash\nexit 0\n' > "$out/scripts/acceptance.sh"
make_tracked_repo "$out"
foreign="$(new_workdir)/elsewhere"; mkdir -p "$foreign"
if out_txt="$(cd "$foreign" && ALLOWED_AUTHOR_EMAILS="$ALLOWED_EMAIL" bash "$out/scripts/loop-gate.sh" 2>&1)"; then
  assert_contains "$out_txt" "GATE_PASS" "loop-gate 出力（異なる cwd から）"
else
  fail "異なる cwd から起動すると既定 acceptance を解決できない: $out_txt"
fi

# ── commit identity（loop-gate の step 1、#302） ───────────────────────────────
#
# 判定ロジックそのもの（許可 email の解決順序・ドメイン許可・co-author の検査など）
# の網羅的な検証は test-git-identity.sh が担う。ここで見るのは「loop-gate.sh が
# verify-commit-identity.sh を verify より前に呼ぶこと」「許可外 identity では
# 早く落ち、後続の段（verify / 第二意見）まで進まないこと」だけ。

it "許可外 identity のコミットは step 1 で GATE_FAIL になり、後続の段まで進まない"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
printf '#!/usr/bin/env bash\necho REVIEW_INVOKED\nexit 0\n' > "$out/scripts/second-opinion-review.sh"
chmod +x "$out/scripts/second-opinion-review.sh"
make_tracked_repo "$out"
if out_txt="$(cd "$out" && ALLOWED_AUTHOR_EMAILS="other@example.com" VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  fail "許可外 identity なのに通過してしまった: $out_txt"
else
  if printf '%s' "$out_txt" | grep -q '\[loop-gate\] step 1' \
     && printf '%s' "$out_txt" | grep -q 'commit identity not passed' \
     && printf '%s' "$out_txt" | grep -q 'GATE_FAIL'; then
    # 第二意見が誤って呼ばれていないこと（stub の出力 REVIEW_INVOKED も、
    # verify を示す step 2 のログも現れないこと）を両方で確かめる。
    if printf '%s' "$out_txt" | grep -q 'REVIEW_INVOKED' \
       || printf '%s' "$out_txt" | grep -q '\[loop-gate\] step 2'; then
      fail "identity で落ちたのに後続の段まで進んでいる: $out_txt"
    else
      pass
    fi
  else
    fail "identity 由来の GATE_FAIL が出ていない: $out_txt"
  fi
fi

it "許可内 identity のコミットだけなら、従来どおり後続の段が実行される（対照群）"
# 同じプロジェクト・同じコミットのまま、許可 email だけを一致させる。上のケースが
# 「たまたま acceptance / 第二意見の設定不備で落ちた」のではなく、identity の
# 許可・不許可だけで結果が変わることを確かめる。
if out_txt="$(cd "$out" && ALLOWED_AUTHOR_EMAILS="$ALLOWED_EMAIL" VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  if printf '%s' "$out_txt" | grep -q 'GATE_PASS' && printf '%s' "$out_txt" | grep -q 'REVIEW_INVOKED'; then
    pass
  else
    fail "許可内 identity なのに後続の段が実行されていない: $out_txt"
  fi
else
  fail "許可内 identity なのに通過しない: $out_txt"
fi

it "acceptance 不合格で GATE_FAIL / exit 1"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
make_tracked_repo "$out"
acc="$(new_workdir)/acc-fail.sh"; printf '#!/usr/bin/env bash\nexit 1\n' > "$acc"
if out_txt="$(cd "$out" && ALLOWED_AUTHOR_EMAILS="$ALLOWED_EMAIL" VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  fail "不合格なのに通過してしまった: $out_txt"
else
  # identity（step 1）は許可 email を渡しているので通過し、verify（step 2）で
  # 落ちることを確かめる。単に GATE_FAIL が出るだけでは、原因が acceptance の
  # 不合格ではなく identity 側にずれていても気づけない。
  #
  # 「identity で落ちていない」だけでは足りない。verify.sh は acceptance の
  # 手前で check-no-secrets.sh も実行するため、それだけで GATE_FAIL になっても
  # 同じ形の出力になり得る。acceptance（$acc）が実際に起動されたことまで固定する
  # （verify.sh が acceptance の起動直前に出す "[verify] running acceptance:" を見る）。
  if printf '%s' "$out_txt" | grep -q 'commit identity not passed'; then
    fail "acceptance 不合格を検証する前に identity で落ちている: $out_txt"
  elif ! printf '%s' "$out_txt" | grep -q '\[verify\] running acceptance:'; then
    fail "acceptance が起動された痕跡が無い（identity 以外の別段で落ちている疑い）: $out_txt"
  else
    assert_contains "$out_txt" "GATE_FAIL" "loop-gate 出力"
  fi
fi

it "第二意見（second-opinion-review.sh）が存在すれば直列化して通過する"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
make_tracked_repo "$out"
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
printf '#!/usr/bin/env bash\necho stub-lgtm\nexit 0\n' > "$out/scripts/second-opinion-review.sh"
chmod +x "$out/scripts/second-opinion-review.sh"
if out_txt="$(cd "$out" && ALLOWED_AUTHOR_EMAILS="$ALLOWED_EMAIL" VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  if printf '%s' "$out_txt" | grep -q 'stub-lgtm' && printf '%s' "$out_txt" | grep -q 'GATE_PASS'; then
    pass
  else
    fail "第二意見が直列化されていない: $out_txt"
  fi
else
  fail "全段合格なのに exit 非 0: $out_txt"
fi

it "第二意見が指摘を返すと GATE_FAIL"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
make_tracked_repo "$out"
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
printf '#!/usr/bin/env bash\necho stub-findings\nexit 1\n' > "$out/scripts/second-opinion-review.sh"
chmod +x "$out/scripts/second-opinion-review.sh"
if out_txt="$(cd "$out" && ALLOWED_AUTHOR_EMAILS="$ALLOWED_EMAIL" VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  fail "第二意見が指摘したのに通過: $out_txt"
else
  # identity / verify（step 1・2）は通過しており、第二意見（step 3）が原因で
  # 落ちていることを確かめる。
  if printf '%s' "$out_txt" | grep -q 'commit identity not passed' \
     || printf '%s' "$out_txt" | grep -q 'verify not passed'; then
    fail "第二意見の不合格を検証する前に別の段で落ちている: $out_txt"
  else
    assert_contains "$out_txt" "GATE_FAIL" "loop-gate 出力"
  fi
fi

it "LOOP_GATE_REVIEW_CMD='' で第二意見を明示スキップできる"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
make_tracked_repo "$out"
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
# reviewer が存在しても、空文字指定なら実行しない
printf '#!/usr/bin/env bash\necho SHOULD_NOT_RUN\nexit 1\n' > "$out/scripts/second-opinion-review.sh"
chmod +x "$out/scripts/second-opinion-review.sh"
if out_txt="$(cd "$out" && ALLOWED_AUTHOR_EMAILS="$ALLOWED_EMAIL" LOOP_GATE_REVIEW_CMD='' VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  if printf '%s' "$out_txt" | grep -q 'GATE_PASS' && ! printf '%s' "$out_txt" | grep -q 'SHOULD_NOT_RUN'; then
    pass
  else
    fail "空文字指定でも reviewer が走った、または通過しない: $out_txt"
  fi
else
  fail "スキップ指定で exit 非 0: $out_txt"
fi

it "ステージが空の git リポジトリでは commit 済み範囲を第二意見へ渡す"
# second-opinion-review.sh の既定対象はステージ済み差分で、空なら 0 を返す。commit 後に
# ゲートを回すと第二意見が実質スキップされたまま GATE_PASS が出る（偽の緑）。
#
# 範囲が渡ることだけでは足りない。reviewer は範囲を git diff に渡すため、
# 渡した範囲が空の差分にしかならなければ（例: --range HEAD は作業ツリー vs HEAD で、
# commit 直後は空）素通りは塞がれていない。stub 側で実際の差分量を測る。
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
cat > "$out/scripts/second-opinion-review.sh" <<'STUB'
#!/usr/bin/env bash
echo "REVIEW_ARGV:$*"
if [[ "${1-}" == "--range" ]]; then
  echo "REVIEW_DIFF_LINES:$(git diff "$2" | wc -l | tr -d ' ')"
fi
exit 0
STUB
chmod +x "$out/scripts/second-opinion-review.sh"
(
  cd "$out" && git init -q && git add -A \
    && git -c user.name=T -c user.email=t@example.com commit -q -m c1
) >/dev/null 2>&1
if out_txt="$(cd "$out" && ALLOWED_AUTHOR_EMAILS="$ALLOWED_EMAIL" VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  lines="$(printf '%s' "$out_txt" | sed -n 's/^REVIEW_DIFF_LINES://p')"
  if printf '%s' "$out_txt" | grep -q 'REVIEW_ARGV:--range ' \
     && [[ -n "$lines" && "$lines" -gt 0 ]] \
     && printf '%s' "$out_txt" | grep -q 'GATE_PASS'; then
    pass
  else
    fail "ステージ空で範囲が渡っていない、または差分が空 (lines=${lines:-none}): $out_txt"
  fi
else
  fail "全段合格なのに exit 非 0: $out_txt"
fi

it "ステージ済み差分があるときは範囲を渡さない（reviewer の既定に委ねる）"
# 既定の対象を上書きしてしまうと、レビュー範囲が意図せず広がる。
printf 'change\n' > "$out/STAGED.txt"
( cd "$out" && git add STAGED.txt ) >/dev/null 2>&1
if out_txt="$(cd "$out" && ALLOWED_AUTHOR_EMAILS="$ALLOWED_EMAIL" VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  if printf '%s' "$out_txt" | grep -q 'REVIEW_ARGV:$' && printf '%s' "$out_txt" | grep -q 'GATE_PASS'; then
    pass
  else
    fail "ステージ済みがあるのに範囲を渡している: $out_txt"
  fi
else
  fail "全段合格なのに exit 非 0: $out_txt"
fi

it "git 管理外かつ許可 email 未設定のプロジェクトでは commit identity 検査が成立せず GATE_FAIL"
# 契約の変更を明示する（#302）。以前は「生成直後で git 管理下にないプロジェクトでも
# ゲートが使える」ことを不変条件にしていたが、step 1 の commit identity 検査
# （verify-commit-identity.sh）が最初に走るようになった。許可 email
# （ALLOWED_AUTHOR_EMAILS / .env の GIT_IDENTITY_EMAIL）を解決できなければ
# fail-closed で落ち、verify.sh が呼ぶ機密混入検査（git の作業ツリーを前提とする）
# へはそもそも到達しない。したがって生成直後は、許可 email を用意したうえで
# git init して追跡対象をコミットするまでゲートは通らない。ここで通過を期待すると、
# 検査していない状態を緑として固定してしまう。
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
printf '#!/usr/bin/env bash\necho "REVIEW_ARGV:$*"\nexit 0\n' > "$out/scripts/second-opinion-review.sh"
chmod +x "$out/scripts/second-opinion-review.sh"
if out_txt="$(cd "$out" && VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  fail "git 管理外で通過してしまった: $out_txt"
elif printf '%s' "$out_txt" | grep -q 'GATE_FAIL' \
     && printf '%s' "$out_txt" | grep -q 'commit identity not passed'; then
  # verify（step 2）・第二意見（step 3）のどちらも走らないことを確かめる。
  # 走ってしまうと、identity 未検証のまま先の段へ進めることになる。
  if printf '%s' "$out_txt" | grep -q 'REVIEW_ARGV' \
     || printf '%s' "$out_txt" | grep -q '\[loop-gate\] step 2'; then
    fail "identity で止まったのに後続の段が走っている: $out_txt"
  else
    pass
  fi
else
  fail "GATE_FAIL と理由が出ていない: $out_txt"
fi

it "git 管理外でも範囲解決そのものは引数なしになる（source して単体で呼ぶ）"
# 上のケースがゲート全体を落とすようになったため、範囲解決の git 外挙動を
# 直接検証する（ゲート経由では verify で止まって到達しない）。loop-gate.sh は
# source ガードを持ち、読み込んだだけでは本体を実行しない。
foreign="$(new_workdir)/no-git"; mkdir -p "$foreign"
range_txt="$(bash -c '
  cd "$1" || exit 1
  . "$2"
  resolve_review_range
  printf "RANGE:%s\n" "$REVIEW_RANGE"
' _ "$foreign" "$out/scripts/loop-gate.sh" 2>&1)"
assert_eq "$(printf '%s\n' "$range_txt" | sed -n 's/^RANGE://p' | tail -1)" "" "git 外での解決範囲"

# ── 範囲解決: push 済みブランチ（HEAD == 上流） ───────────────────────────────
#
# 上流が設定済みでも、push 済みなら上流 == HEAD で @{upstream}..HEAD の差分が
# 空になる。reviewer は空差分を 0 で返すため、第二意見が一度も差分を見ないまま
# GATE_PASS が出る（ステージ空の穴と同じ構造の残穴）。ここでは「範囲が渡ること」
# ではなく「渡した範囲に実際の差分があること」を検証する。

# push 済みブランチのフィクスチャを作る。
#   $1 = 生成済みプロジェクトのパス
#   $2 = "main"（既定ブランチのまま push）または "feature"（枝を切って push）
# 生成物一式を main へ commit し、bare リポジトリを origin として push する。
# origin/HEAD は clone 以外では自動で作られないため明示的に設定する（実運用の
# clone 済みリポジトリと同じ状態にするため）。
make_pushed_repo() {
  local repo="$1" kind="$2" origin
  origin="$(new_workdir)/origin.git"
  git init -q --bare "$origin"
  (
    cd "$repo" || exit 1
    git init -q
    # 既定ブランチ名は git のバージョン・設定で変わるため明示する。
    git symbolic-ref HEAD refs/heads/main
    git add -A
    git -c user.name=T -c user.email=t@example.com commit -q -m c1
    git remote add origin "$origin"
    git push -q -u origin main
    git remote set-head origin main
    if [[ "$kind" == "feature" ]]; then
      git checkout -q -b feat
      printf 'feature\n' > FEATURE.txt
      git add FEATURE.txt
      git -c user.name=T -c user.email=t@example.com commit -q -m c2
      git push -q -u origin feat
    fi
  ) >/dev/null 2>&1
}

it "push 済みブランチ（HEAD == 上流）でも差分のある範囲を第二意見へ渡す"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
# 範囲そのものに加えて、その範囲が指す差分の量と対象ファイルを stub 側で測る。
# 範囲が渡るだけでは、空差分の素通りを塞げたことにならない。
cat > "$out/scripts/second-opinion-review.sh" <<'STUB'
#!/usr/bin/env bash
echo "REVIEW_ARGV:$*"
if [[ "${1-}" == "--range" ]]; then
  echo "REVIEW_DIFF_LINES:$(git diff "$2" | wc -l | tr -d ' ')"
  echo "REVIEW_DIFF_NAMES:$(git diff --name-only "$2" | tr '\n' ',')"
fi
exit 0
STUB
chmod +x "$out/scripts/second-opinion-review.sh"
make_pushed_repo "$out" feature
if out_txt="$(cd "$out" && ALLOWED_AUTHOR_EMAILS="$ALLOWED_EMAIL" VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  lines="$(printf '%s' "$out_txt" | sed -n 's/^REVIEW_DIFF_LINES://p')"
  names="$(printf '%s' "$out_txt" | sed -n 's/^REVIEW_DIFF_NAMES://p')"
  if [[ -n "$lines" && "$lines" -gt 0 ]] \
     && printf '%s' "$names" | grep -q 'FEATURE.txt' \
     && printf '%s' "$out_txt" | grep -q 'GATE_PASS'; then
    # 分岐点起点であること。既定ブランチにしか無いファイル（生成物一式）が
    # 差分へ混じるなら、範囲がブランチの変更を超えて広がっている。
    if printf '%s' "$names" | grep -q 'scripts/verify.sh'; then
      fail "範囲が分岐点を超えて広がっている: $names"
    else
      pass
    fi
  else
    fail "push 済みブランチで第二意見の対象が空 (lines=${lines:-none}, names=${names:-none}): $out_txt"
  fi
else
  fail "全段合格なのに exit 非 0: $out_txt"
fi

it "レビュー対象が本当に無いときは、その旨を明示して GATE_PASS"
# 既定ブランチを push した直後（HEAD == 上流 == origin/HEAD）。分岐点まで戻しても
# 差分は無い。ここで空を FAIL にすると差分の無い状態でのゲート実行が落ちるため
# 通過させるが、黙って通すと偽の緑と区別が付かないので明示する。
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
acc="$(new_workdir)/acc-pass.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$acc"
printf '#!/usr/bin/env bash\necho REVIEW_INVOKED\nexit 0\n' > "$out/scripts/second-opinion-review.sh"
chmod +x "$out/scripts/second-opinion-review.sh"
make_pushed_repo "$out" main
if out_txt="$(cd "$out" && ALLOWED_AUTHOR_EMAILS="$ALLOWED_EMAIL" VERIFY_ACCEPTANCE="$acc" bash scripts/loop-gate.sh 2>&1)"; then
  if printf '%s' "$out_txt" | grep -q 'no reviewable diff' \
     && printf '%s' "$out_txt" | grep -q 'GATE_PASS' \
     && ! printf '%s' "$out_txt" | grep -q 'REVIEW_INVOKED'; then
    pass
  else
    fail "対象なしが明示されない、または対象の無い reviewer を呼んでいる: $out_txt"
  fi
else
  fail "対象が無いだけなのに exit 非 0: $out_txt"
fi

# ── 外部層の受け入れ条件（acceptance-remote.sh） ───────────────────────────────
#
# 受け入れ条件はローカル層（acceptance.sh）と外部層（acceptance-remote.sh）に分かれる。
# 外部層は外部認証とネットワークを要するため、ループの接地信号にも push 前ゲートにも
# 含めない（規範の正本は loop-workflow.md「受け入れ条件の二層」）。ここでは配置条件と
# 骨格、そして「検査未定義を合格にしない」ことを検証する。

it "装備を選ばない構成では acceptance-remote.sh を配置しない"
# 外部状態を持たない構成へ空の雛形を配ると、消す作業をさせることになる。
# 併せて、条件付き一覧が空になる経路で bootstrap 自身が停止しないことも見る
# （集約側は set -euo pipefail のパイプラインなので、条件関数が非 0 を返すと
# 生成が丸ごと止まる）。
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
if [[ -f "$out/scripts/verify.sh" ]]; then
  assert_file_absent "$out/scripts/acceptance-remote.sh"
else
  fail "装備なしの構成で生成そのものが失敗している（条件付き一覧の終了ステータスを確認）"
fi

it "--with-aws / --with-gcp のいずれかで acceptance-remote.sh を配置する"
missing=""
for flag in --with-aws --with-gcp; do
  o="$(new_workdir)/p"
  run_bootstrap "$o" "$flag" >/dev/null 2>&1
  [[ -f "$o/scripts/acceptance-remote.sh" ]] || missing="$missing $flag"
done
if [[ -z "$missing" ]]; then pass; else fail "配置されないフラグ:$missing"; fi

out="$(new_workdir)/p"
run_bootstrap "$out" --with-aws >/dev/null 2>&1
# 外部層のケースも verify.sh を経由するため、機密混入検査の前提（git の作業ツリーで
# あり追跡ファイルが 1 件以上ある）を満たしてから回す。満たさないと acceptance 段へ
# 到達する前に SECRETS_FAIL で落ち、外部層の挙動を検証できない。
make_tracked_repo "$out"
REMOTE="$out/scripts/acceptance-remote.sh"

it "acceptance-remote.sh は有効な bash 構文で実行可能（755）"
if bash -n "$REMOTE" 2>/dev/null; then
  assert_mode "$REMOTE" "755"
else
  fail "構文エラー: $REMOTE"
fi

it "検査未定義の acceptance-remote.sh は VERIFY_FAIL / exit 1 になる"
# 検証していないことを合格として報告するのが最悪であるため、雛形は「検査を 1 件も
# 実行していない」状態を失敗として扱う（acceptance.sh の ran_any と同じ構え）。
if out_txt="$(cd "$out" && VERIFY_ACCEPTANCE=scripts/acceptance-remote.sh bash scripts/verify.sh 2>&1)"; then
  fail "検査が未定義なのに通過してしまった: $out_txt"
else
  if printf '%s' "$out_txt" | grep -q 'VERIFY_FAIL' \
     && printf '%s' "$out_txt" | grep -q '未定義'; then
    pass
  else
    fail "未定義である旨と VERIFY_FAIL が揃わない: $out_txt"
  fi
fi

it "acceptance-remote.sh の一時ログは mktemp のテンプレートで作り、\$\$ 由来の名前を使わない"
# 予測可能な名前は、同名を先に置かれると書き込み先を乗っ取られる。
# コメント行は落として本体だけを見る（雛形のコメントがこの理由を説明するために
# \$\$ という文字列そのものを含むため、全文へ当てると自分の説明文で落ちる）。
# 照合は grep -F で行う（パターン側が \$ や引用符を含み、正規表現として解釈させる
# 理由が無い）。
remote_code="$(grep -v '^[[:space:]]*#' "$REMOTE")"
if printf '%s\n' "$remote_code" | grep -Fq 'mktemp "${TMPDIR:-/tmp}/acceptance-remote.XXXXXX"' \
   && printf '%s\n' "$remote_code" | grep -Fq "trap 'rm -f \"\$LOG\"' EXIT" \
   && ! printf '%s\n' "$remote_code" | grep -Fq '$$'; then
  pass
else
  fail "mktemp テンプレート / EXIT トラップが無い、または \$\$ 由来の名前を使っている"
fi

it "acceptance-remote.sh は set -e を使わない代わりに失敗しうる代入をガードする"
# set -e が無い分、失敗しうる代入は個別に止める必要がある。塞がないと:
#   HERE  解決に失敗して空になると dirname が "." を返し、続く cd が成功してしまう
#         （ルート外で検査が走る）
#   LOG   作成に失敗して空になると run の >"$LOG" が必ず失敗し、実行できていない
#         検査が「失敗した検査」として報告される
if printf '%s\n' "$remote_code" | grep -Fq 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1' \
   && printf '%s\n' "$remote_code" | grep -Fq 'LOG="$(mktemp "${TMPDIR:-/tmp}/acceptance-remote.XXXXXX")" || exit 1'; then
  pass
else
  fail "HERE / LOG の代入ガード（|| exit 1）が無い"
fi

it "acceptance-remote.sh は前提（認証済みであること）を明示する"
# 未認証での失敗は「宣言と外部状態の乖離」ではない。読み分けの手掛かりを雛形に置く。
if grep -q '認証済み' "$REMOTE"; then pass; else fail "前提の記述が無い"; fi

it "acceptance-remote.sh は具体的な検査を持たない"
# 何が外部状態かはプロジェクトごとに違う。特定のツールを決め打つと必ず外れる。
if grep -qE '^[[:space:]]*run "' "$REMOTE"; then
  fail "雛形が具体的な検査を持っている（骨格だけを配ること）"
else
  pass
fi

# 骨格へ検査を差し込んだ写しを作る。判定行の直前へ run 呼び出しを入れる。
# アンカーが見つからなければ非 0 を返し、差し込めていないことを呼び出し側へ伝える
# （差し込めないまま「検査未定義」で落ちたのを run の挙動と読み違えないため）。
inject_remote_checks() {
  local src="$1" dest="$2" ins="$3"
  awk -v ins="$ins" '
    !injected && $0 == "if [[ \"$ran_any\" -eq 0 ]]; then" { print ins; injected = 1 }
    { print }
    END { if (!injected) exit 1 }
  ' "$src" > "$dest"
}

it "run ヘルパーは成功した検査の出力を出さない"
work="$(new_workdir)/p"
run_bootstrap "$work" --with-gcp >/dev/null 2>&1
if inject_remote_checks "$work/scripts/acceptance-remote.sh" "$work/scripts/injected.sh" \
     'run "quiet ok" bash -c "echo MUST_NOT_APPEAR"'; then
  # 差し込んだ後に追跡させる（機密混入検査の前提。上の make_tracked_repo と同じ理由）。
  make_tracked_repo "$work"
  if out_txt="$(cd "$work" && VERIFY_ACCEPTANCE=scripts/injected.sh bash scripts/verify.sh 2>&1)"; then
    if printf '%s' "$out_txt" | grep -q 'MUST_NOT_APPEAR'; then
      fail "成功した検査の出力が漏れている: $out_txt"
    else
      assert_contains "$out_txt" "VERIFY_PASS" "verify 出力"
    fi
  else
    fail "検査が成功しているのに通過しない: $out_txt"
  fi
else
  fail "検査の差し込みに失敗した（雛形の判定行の書式が変わった可能性）"
fi

it "run ヘルパーは失敗した検査の出力と失敗件数を出し、非 0 で終わる"
work="$(new_workdir)/p"
run_bootstrap "$work" --with-gcp >/dev/null 2>&1
if inject_remote_checks "$work/scripts/acceptance-remote.sh" "$work/scripts/injected.sh" \
     'run "ok one" true\nrun "bad one" bash -c "echo BOOM >&2; exit 3"\nrun "bad two" false'; then
  # 差し込んだ後に追跡させる（機密混入検査の前提。上の make_tracked_repo と同じ理由）。
  make_tracked_repo "$work"
  if out_txt="$(cd "$work" && VERIFY_ACCEPTANCE=scripts/injected.sh bash scripts/verify.sh 2>&1)"; then
    fail "検査が失敗しているのに通過した: $out_txt"
  else
    # 1 件目の失敗で止めず全件を見てから落とす（失敗件数が 2 になる）。
    if printf '%s' "$out_txt" | grep -q 'FAIL: bad one' \
       && printf '%s' "$out_txt" | grep -q 'BOOM' \
       && printf '%s' "$out_txt" | grep -q 'FAIL: bad two' \
       && printf '%s' "$out_txt" | grep -q '2 件の検査が失敗'; then
      pass
    else
      fail "失敗の出力・件数の集計が揃わない: $out_txt"
    fi
  fi
else
  fail "検査の差し込みに失敗した（雛形の判定行の書式が変わった可能性）"
fi

it "loop-gate は外部層を実行しない"
# 外部認証の失効やオフラインでゲート全体が止まると、実装が正しいのにループが止まる。
if grep -q 'acceptance-remote' "$out/scripts/loop-gate.sh"; then
  fail "loop-gate.sh が外部層を参照している"
else
  pass
fi

# ── 配布層とプロジェクト層の一致 ──────────────────────────────────────────────

it "生成される loop-gate.sh はこのリポジトリの scripts/loop-gate.sh と一致する"
# 同じ欠陥を片方だけ直すと、配布物と開発リポジトリでゲートの挙動が食い違う。
# 範囲解決だけを比べると比較対象の抜き出し方が別の乖離源になるため、ファイル
# 全体の一致で固定する（プロジェクト層は配布テンプレートの写しとして運用する）。
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
# 末尾改行の有無は比較から外す。bootstrap は雛形をコマンド置換で受け取るため
# 生成物の末尾改行が必ず落ちる（loop-gate に限らない書き出し側の性質）。ここで
# 差として扱うと、乖離検知が「編集時に末尾改行が付いたか」で揺れる。
# awk '{print}' は最終行にも改行を付けるため、両側を同じ形へ揃えられる。
norm_repo="$(new_workdir)/repo-loop-gate.sh"
norm_gen="$(new_workdir)/generated-loop-gate.sh"
awk '{print}' "$REPO_ROOT/scripts/loop-gate.sh" > "$norm_repo"
awk '{print}' "$out/scripts/loop-gate.sh" > "$norm_gen"
if d="$(diff -u "$norm_repo" "$norm_gen" 2>&1)"; then
  pass
else
  fail "配布テンプレートとプロジェクト層が乖離している: $(printf '%s' "$d" | head -c 400)"
fi

# ── doctor 連携 ───────────────────────────────────────────────────────────────

it "doctor はループスクリプトを含めて FAIL=0 で診断する"
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
output="$(bash "$PKG_DIR/doctor.sh" --target-dir "$out" 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]] && printf '%s' "$output" | grep -q 'verify.sh syntax OK' && printf '%s' "$output" | grep -q 'FAIL=0'; then
  pass
else
  fail "doctor が verify を検査していない、または FAIL がある (rc=$rc): $(printf '%s' "$output" | grep -iE 'verify|fail')"
fi

exit_with_result
