#!/usr/bin/env bash
# 生成される受け入れ検証の CI ワークフロー（.github/workflows/verify.yml）を検証する。
#
# 背景:
#   verify.sh / acceptance.sh / loop-gate.sh は配られるが、それを CI で回す側の
#   ワークフローが配られていなかった。手元でしか走らないため、ローカル事前ゲートを
#   回し忘れた PR は受け入れ条件を満たさないままレビューへ届く。ゲートを整備しても
#   実行を忘れられるなら、守られている外観だけが残る。
#
# ここで固定するのは 5 点:
#   1. 配置が無条件であること（--with-playbook を付けない生成でも置かれる）。
#      規範パッケージの雛形にすると require_playbook_template が停止し、受け入れ
#      検証が rules 配置へ従属してしまう。その形を採っていないことを固定する。
#   2. 2 系統（pull_request / push(main)）が揃っていること。
#   3. fetch-depth: 0 であること。
#   4. ALLOWED_AUTHOR_EMAILS をリポジトリ変数から渡すこと。
#   5. fork からの PR をスキップしない判断が保たれていること。
#
# あわせて「雛形が持たないもの」（言語ランタイム・ツール導入・依存インストール）を
# 実際に持っていないことも見る。ここが決め打ちに戻ると、利用者は毎回それを消す
# 作業をさせられる。

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "test-verify-workflow"

# ── 生成（装備フラグを 1 つも付けない最小構成） ───────────────────────────────
# run_bootstrap は --with-* を付けない。--with-playbook 無しの経路をそのまま踏む。
out="$(new_workdir)/p"
run_bootstrap "$out" >/dev/null 2>&1
WF="$out/.github/workflows/verify.yml"

it "--with-playbook を付けない生成でも verify.yml が置かれる"
assert_file_exists "$WF"

it "生成ワークフローが YAML/Actions として妥当である"
# actionlint があれば通す。無ければ PyYAML、それも無ければ最低限の構造検査で代替する
# （沈黙スキップはしない）。test-review-gate.sh / test-copilot-review.sh と同じ段構え。
if command -v actionlint >/dev/null 2>&1; then
  if actionlint "$WF" >/dev/null 2>&1; then pass; else fail "actionlint 検査に失敗"; fi
elif python3 -c 'import yaml' >/dev/null 2>&1; then
  if python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$WF" >/dev/null 2>&1; then
    pass
  else
    fail "PyYAML の safe_load に失敗"
  fi
else
  # 最低限の構造検査: 必須トップキーが存在し、行頭タブインデントが無いこと。
  tab="$(printf '\t')"
  if grep -Eq '^on:' "$WF" \
     && grep -Eq '^jobs:' "$WF" \
     && grep -Eq '^permissions:' "$WF" \
     && grep -Eq '^concurrency:' "$WF" \
     && ! grep -q "^${tab}" "$WF"; then
    pass
  else
    fail "必須トップキー欠落またはタブインデント混入"
  fi
fi

it "verify.yml が template_rel_paths() に登録されている（--dry-run の plan に現れる）"
# 存在の検査だけでは、条件付き配置の別経路で置かれた場合と区別できない。無条件の
# 一覧に載っていることを、生成経路と同じ関数を通る --dry-run から確かめる。
plan="$(bash "$BOOTSTRAP" --project-name test --languages node \
  --output-dir "$(new_workdir)/dry" --dry-run 2>/dev/null)"
assert_contains "$plan" ".github/workflows/verify.yml" "--dry-run の plan 行"

it "規範パッケージ側に雛形の正本を持たない（配置が rules に従属しない）"
# 正本を .ai-playbook/templates/ へ置くと、--with-playbook 無しの生成で配置経路が
# 消える。撤回した設計へ戻っていないことを、供給元の不在で固定する。
if [[ -e "$PLAYBOOK_SRC/templates/verify.yml" ]]; then
  fail "規範パッケージ側に verify.yml の雛形がある（正本は bootstrap.sh のヒアドキュメント）"
else
  pass
fi

# ── 内容 ──────────────────────────────────────────────────────────────────────

it "2 系統を張る（pull_request と push(main)）"
if grep -q '^  pull_request:' "$WF" \
  && grep -q '^    types: \[opened, synchronize, reopened\]' "$WF" \
  && grep -q '^  push:' "$WF" \
  && grep -q '^    branches: \[main\]' "$WF"; then
  pass
else
  fail "2 系統の trigger が揃っていない"
fi

it "checkout が fetch-depth: 0 を指定する"
# 既定の深さ 1 では既定ブランチの追跡枝が作られず、履歴を見る検査を acceptance.sh へ
# 足したときに「検査対象 1 件で通過」という偽の緑になる（実測済み。落ちないので
# 気づく機会が無い）。
if grep -q '^          fetch-depth: 0$' "$WF"; then pass; else fail "fetch-depth: 0 がない"; fi

it "許可 author email はリポジトリ変数から渡す（固有 email を焼き込まない）"
if grep -q 'ALLOWED_AUTHOR_EMAILS: ${{ vars.ALLOWED_AUTHOR_EMAILS }}' "$WF"; then
  pass
else
  fail "vars.ALLOWED_AUTHOR_EMAILS の配線がない"
fi

it "permissions を contents: read に絞る"
if grep -q '^permissions:$' "$WF" && grep -q '^  contents: read$' "$WF"; then
  pass
else
  fail "permissions: contents: read がない"
fi

it "concurrency を持ち、pull_request のときだけ古い実行を取り消す"
# main を取り消すと、マージ後の統合状態がどのコミットから壊れたのか追えなくなる。
if grep -q '^concurrency:$' "$WF" \
  && grep -q "^  cancel-in-progress: \${{ github.event_name == 'pull_request' }}\$" "$WF"; then
  pass
else
  fail "concurrency の条件付き取り消しがない"
fi

it "push 側の concurrency グループ鍵が github.ref にフォールバックしない（github.sha で一意になる）"
# group 行だけを見る。コメントには経緯説明として github.ref という文字列が
# 出てくるため、ファイル全体を対象にすると誤検出する。
# github.ref にフォールバックすると main への push はどのコミットでも同じ ref
# になり、cancel-in-progress: false と合わさって「取り消されない代わりに
# 直列でキュー待ちする」状態になる（取り消さないことと直列化しないことは
# 別の要求）。
group_line="$(grep '^  group: ' "$WF")"
if printf '%s' "$group_line" | grep -q 'github.sha' \
  && ! printf '%s' "$group_line" | grep -q 'github.ref'; then
  pass
else
  fail "group 行が github.sha を使っていない、または github.ref を含む: ${group_line}"
fi

it "判定をシェルへ委譲する（scripts/verify.sh を呼ぶだけ）"
if grep -q '^        run: bash scripts/verify.sh$' "$WF"; then
  pass
else
  fail "scripts/verify.sh の呼び出しがない"
fi

# ── fork からの PR の扱い ─────────────────────────────────────────────────────
#
# 判断: スキップしない。verify.sh は Secrets を要さず、permissions: contents: read は
# fork からの PR に既に与えられている権限なので、走らせられない理由が無い。スキップ
# すれば、最も検証が要る外部からの変更にだけゲートが掛からなくなる。
#
# ただし fork からの PR にはリポジトリ変数も渡らないため、acceptance.sh へ供給元を
# 要する検査を足すと fork でだけ fail-closed で赤くなる。その逃げ道（if の 1 行）を
# コメントで置いてあり、有効化は利用側の判断とする。
#
# 検査は「扱いが書かれている」ことと「実際にスキップしていない」ことの 2 点に分ける。
# 前者だけだと、コメントを残したまま if を有効化しても緑のままになる。

it "fork からの PR の扱いが雛形に書かれている"
if grep -q 'fork からの PR' "$WF" \
  && grep -q '# if: github.event.pull_request.head.repo.fork != true' "$WF"; then
  pass
else
  fail "fork からの PR の扱いと、切り替え用の if がコメントに無い"
fi

# コメント行を落とした「実際に効いている行」だけを取り出す。以降の検査はこちらを見る。
#
# 行頭コメントに加えてインラインコメント（`run: ... # 説明`）も落とす。落とさないと、
# 説明文に出てきただけの語（actions/setup- 等）を「有効な行に入っている」と誤判定する。
# YAML の慣行どおり、コメントの開始は空白に続く # だけとみなす（値の中の # を巻き込ま
# ないため）。現行の雛形に空白 + # を含む値は無いことを確認済み。
active="$(sed -e 's/[[:space:]]#.*$//' "$WF" 2>/dev/null | grep -v '^[[:space:]]*#')"

it "コメントを除いた有効な行を取り出せる"
# 以降の 4 件は「入っていないこと」を見る検査なので、抽出が空だと全部が素通りで
# 緑になる（雛形が生成されていない状態でも通ってしまう）。先に抽出結果を検査する。
if [[ -n "$active" ]]; then pass; else fail "verify.yml から有効な行を取り出せなかった"; fi

it "fork からの PR をスキップしない（job の if 条件が有効になっていない）"
# 見るのは job-level の if だけにする（jobs > <job> の直下なので 4 スペース）。
# ファイル全体から if: を探すと step-level の if（例: if: failure()）まで拾い、
# fork の扱いとは無関係な変更で赤くなる。しかもメッセージは「fork をスキップしない
# 判断が覆っている」と出るため、原因と違うことを言って次に踏んだ人を遠回りさせる。
if printf '%s\n' "$active" | grep -Eq '^ {4}if:'; then
  fail "job に有効な if 条件がある（fork をスキップしない判断が覆っている）"
else
  pass
fi

# ── 雛形が持たないもの ────────────────────────────────────────────────────────

it "言語ランタイムの用意を決め打たない"
# acceptance.sh が何を検査するかに従属するため、雛形が決めると消す作業が毎回要る。
case "$active" in
  *"actions/setup-"*) fail "actions/setup-* が有効な行として入っている" ;;
  *) pass ;;
esac

it "ツールの導入・依存のインストールを決め打たない"
if printf '%s\n' "$active" | grep -Eq 'apt-get|npm (ci|install)|pip install|go mod download|bundle install'; then
  fail "依存・ツール導入の手順が有効な行として入っている"
else
  pass
fi

it "実行される run は verify.sh の 1 本だけ"
# 「足す位置をコメントで示すだけ」が保たれているかを本数で見る。
run_count="$(printf '%s\n' "$active" | grep -c '^[[:space:]]*run:')"
assert_eq "$run_count" "1" "有効な run 行の本数"

it "足す位置がコメントで示されている"
if grep -q 'プロジェクトの前提はここへ足す' "$WF"; then
  pass
else
  fail "追記位置の案内が無い"
fi

# ── 中立性 ────────────────────────────────────────────────────────────────────

it "生成物に固有名詞が焼き込まれていない"
if grep -Eqi 'bascule|ojos' "$WF"; then
  fail "固有名詞が生成物に含まれる"
else
  pass
fi

exit_with_result
