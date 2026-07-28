#!/usr/bin/env bash
# リリース実行場所のガードを検証する。
#
# リリースの実行場所は GitHub Actions に一本化した。文書からローカル手順を消す
# だけでは「規約は禁じているが機構は許している」状態が残るため、
# release-packages.sh 自身が Actions 外での --execute を拒否する。
#
# ここではその挙動を、実トークンにも公開リポジトリにも触れずに固定する。
# 判定に使う GITHUB_ACTIONS は必ず明示する。CI（Actions）では既に true が
# 設定されており、明示しないとローカルと CI で結果が変わる。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-release-execution-guard"

RELEASE_SH="$REPO_ROOT/scripts/release-packages.sh"

it "リリーススクリプトが存在する"
assert_file_exists "$RELEASE_SH"

# ── スタブ ────────────────────────────────────────────────────────────────────
#
# gh: 呼ばれた事実をログへ残す。ガードが preflight より前で止まっていれば
#     ログは空のままで、外部への問い合わせにすら到達していないことを示せる。
#     release view / api の応答はテストごとに切り替える（環境変数 STUB_PUBLISHED）。
# git: status を clean と応答する。実行者の作業ツリーの状態でテスト結果が
#      変わらないようにする。それ以外は本物へ委譲する。
stub="$(new_workdir)/bin"
mkdir -p "$stub"
gh_log="$(new_workdir)/gh-calls.log"
: > "$gh_log"

cat > "$stub/gh" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "$gh_log"
# 「公開済み」を演じるかどうかを呼び出し側が選ぶ。
# release view / api tags が成功 = 既に公開済み。
if [[ "\${STUB_PUBLISHED:-false}" == "true" ]]; then exit 0; fi
exit 1
STUB

real_git="$(command -v git)"
cat > "$stub/git" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "status" ]]; then exit 0; fi
exec "$real_git" "\$@"
STUB
chmod +x "$stub/gh" "$stub/git"

# ── Actions 外での --execute は副作用の前に止まる ─────────────────────────────

: > "$gh_log"
out="$(cd "$REPO_ROOT" && PATH="$stub:$PATH" env -u GITHUB_ACTIONS timeout 60 \
        bash "$RELEASE_SH" --owner test --playbook-version v9.9.9 --execute 2>&1)"
code=$?

it "Actions 外の --execute は非ゼロで終了する"
if [[ $code -ne 0 ]]; then pass; else fail "ローカルでも --execute が通ってしまった"; fi

it "拒否の理由と代替手段を示す"
assert_contains "$out" "GitHub Actions" "エラー出力"

it "止まる前に外部へ問い合わせない"
# gh が 1 度でも呼ばれていれば、公開側の状態を見るところまで進んでいる。
if [[ ! -s "$gh_log" ]]; then
  pass
else
  fail "ガードより先に gh が呼ばれた（副作用の恐れ）: $(head -3 "$gh_log" | tr '\n' ' ')"
fi

# ── ローカルでも dry-run は従来どおり実行できる ───────────────────────────────

it "ローカルの dry-run は通る"
# ai-playbook 側だけを対象にする。--dcb-version は preflight で DCB 機能テスト
# 一式を起動し、テストからの再帰と 4 分の待ちを招くため使わない。
out="$(cd "$REPO_ROOT" && PATH="$stub:$PATH" env -u GITHUB_ACTIONS timeout 120 \
        bash "$RELEASE_SH" --owner test --playbook-version v9.9.9 2>&1)"
code=$?
if [[ $code -eq 0 ]]; then
  assert_contains "$out" "dry-run mode" "dry-run 出力"
else
  fail "ローカルの dry-run が失敗した（終了コード $code）:
$(printf '%s' "$out" | tail -5)"
fi

# ── Actions 上では従来どおり実行できる ────────────────────────────────────────

it "GITHUB_ACTIONS=true なら --execute がガードを通過して preflight へ進む"
# 実際に公開はしない。公開済みを演じるスタブを使い、preflight の不変性検査で
# 止まることをもって「ガードを越えて従来の経路に入った」ことを確認する。
: > "$gh_log"
out="$(cd "$REPO_ROOT" && PATH="$stub:$PATH" GITHUB_ACTIONS=true STUB_PUBLISHED=true \
        timeout 60 bash "$RELEASE_SH" --owner test --playbook-version v9.9.9 --execute 2>&1)"
code=$?
if [[ $code -eq 0 ]]; then
  fail "公開済みなのに成功してしまった"
elif printf '%s' "$out" | grep -q 'GitHub Actions 上でのみ'; then
  fail "Actions 上なのにガードで拒否された"
else
  assert_contains "$out" "already has tag" "エラー出力"
fi

it "Actions 上の実行は公開側の状態を確認する"
if [[ -s "$gh_log" ]]; then
  pass
else
  fail "gh が一度も呼ばれていない（preflight へ到達していない）"
fi

# ── ガードは EXECUTE の判定に紐づく ───────────────────────────────────────────

it "ガードが --execute の経路に配線されている"
# 実装の配線を読む。挙動テストだけだと、ガードが別条件（例: 常時拒否）へ
# 変わっても気づけない。
if grep -q 'if \[\[ "\$EXECUTE" == "true" \]\]; then' "$RELEASE_SH" \
   && grep -q 'require_actions_runtime' "$RELEASE_SH"; then
  pass
else
  fail "--execute とガードの結び付きが実装に無い"
fi

it "ガードが preflight より前にある"
# 4 分かかる DCB 機能テストを走らせてから拒否しても手戻りが増えるだけ。
guard="$(grep -n '^  require_actions_runtime$' "$RELEASE_SH" | head -1 | cut -d: -f1)"
preflight="$(grep -n '^require_clean_worktree$' "$RELEASE_SH" | head -1 | cut -d: -f1)"
if [[ -n "$guard" && -n "$preflight" && "$guard" -lt "$preflight" ]]; then
  pass
else
  fail "ガード（$guard 行）が preflight（$preflight 行）より後、または欠落"
fi

exit_with_result
