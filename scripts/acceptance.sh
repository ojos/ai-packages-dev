#!/usr/bin/env bash
# acceptance.sh — このプロジェクトの受け入れ条件（プロジェクトが所有・編集する）
#
# verify.sh がこのスクリプトを実行し、終了コードで合否を判定する。
#
# このリポジトリは CI（.github/workflows/ci.yml）の 6 ジョブ
# + .github/workflows/identity-guard.yml を完全ミラーする。
# 「ローカルが緑なら CI も緑」を保つのが目的で、部分ミラーは push してから CI で
# 落ちる経路を残すため採らない。
#
# 二重管理の負債:
#   ci.yml / identity-guard.yml を変更したら、このファイルも同じ内容へ追随させる
#   こと。CI とここが食い違うと、ローカルゲートは「CI の予行演習」ではなくなり、
#   通っても意味を持たなくなる。追随漏れを機械で検知する仕組みは今のところ無い。
#
# 生成既定（言語マニフェスト検出）は使わない:
#   ルート直下に package.json / go.mod 等が無いため、既定のままでは常に
#   「受け入れ条件が未定義」で失敗する。このリポジトリはシェルスクリプトと
#   文書が実体なので、その実態に合わせて検証を定義している。
#
# 反復を速く回したい場合:
#   DCB テスト（約 4 分）が所要時間の大半を占める。軽量な受け入れ条件へ
#   差し替えるには VERIFY_ACCEPTANCE を使う。
#     VERIFY_ACCEPTANCE=scripts/acceptance-fast.sh bash scripts/verify.sh
#
# 終了コード: 0 = 合格 / 非0 = 不合格・未定義
set -euo pipefail

# 検証はプロジェクトルート基準で行う。scripts/ の 1 階層上がルート。
# 任意の作業ディレクトリから起動しても結果が不変になるよう、起動時 CWD に依存しない。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(dirname "$HERE")"

echo "[acceptance] project acceptance checks"
# 実際に検証を 1 つでも実行したか。1 つも実行できなければ「合格」ではなく失敗にする。
# 検証していないことを合格として報告するのが最悪であるため。
ran_any=0

# ツールが無い場合は「スキップ」ではなく「実行できなかった」として落とす。
# 両者を混同すると、検証していないものを緑として報告することになる。
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[acceptance] $1 not found. $2" >&2
    exit 1
  }
}

require_cmd git "install git to run this acceptance check."

# ── CI: Shell syntax and lint ────────────────────────────────────────────────
echo "[acceptance] (shell) syntax check"
syntax_fail=0
while IFS= read -r f; do
  bash -n "$f" || { echo "[acceptance] syntax error: $f" >&2; syntax_fail=1; }
done < <(git ls-files '*.sh')
[[ "$syntax_fail" -eq 0 ]] || exit 1
ran_any=1

require_cmd shellcheck "install it with: sudo apt-get update && sudo apt-get install -y shellcheck"
echo "[acceptance] (shell) shellcheck"
# 出力書式を -f gcc に固定する理由: 既定の tty 書式は指摘箇所のソース行をそのまま
# 出力する。bootstrap.sh / doctor.sh は日本語コメントが密で、ロケールが POSIX の
# この環境では shellcheck がその行をエンコードできず commitBuffer エラー
# （終了コード 2）で落ち、指摘本文が読めなくなる（#252）。すり抜けは起きない
# （非ゼロ終了で本スクリプトは set -e により落ちる）が、赤の理由が読めないまま
# 止まるのはゲートへの信頼を削る。ソース行を出さない書式に固定すれば、日本語
# コメントの近くで指摘が出たかどうかに関わらず本文が読める。
#
# LC_ALL は立てない: 可搬なロケール名が環境ごとに違う（C.UTF-8 / en_US.UTF-8）ため、
# どちらを書いても環境依存が残る。#236 の tests/test-generated-shellcheck.sh も
# 同じ理由で -f gcc を選んでいる。指摘の所在は file:line:col で足りる。
shellcheck -x -f gcc packages/devcontainer-bootstrap/bootstrap.sh packages/devcontainer-bootstrap/doctor.sh

# ── CI: Self devcontainer credential isolation ───────────────────────────────
# このリポジトリ自身の devcontainer も、生成物と同じ「資格情報をホストから
# 注入しない」構造を保つ。remoteEnv に ${localEnv:...} を 1 つでも足すと、
# その値がホスト OS から静かに流れ込む。
require_cmd jq "install jq to run this acceptance check."
echo "[acceptance] (devcontainer) remoteEnv carries only LOCAL_WORKSPACE_FOLDER"
keys="$(jq -r '.remoteEnv | keys | join(",")' .devcontainer/devcontainer.json)"
if [[ "$keys" != "LOCAL_WORKSPACE_FOLDER" ]]; then
  echo "[acceptance] remoteEnv must contain only LOCAL_WORKSPACE_FOLDER, got: $keys" >&2
  exit 1
fi

echo "[acceptance] (devcontainer) no localEnv reference"
# ${localEnv: は展開させず、リテラルとして探す文字列。単一引用符は意図的。
# shellcheck disable=SC2016
if grep -q '${localEnv:' .devcontainer/devcontainer.json; then
  echo "[acceptance] host credential injection path found:" >&2
  # shellcheck disable=SC2016
  grep -n '${localEnv:' .devcontainer/devcontainer.json >&2
  exit 1
fi

# 一時クローンでの commit は identity を明示する。global identity は
# setup-git-identity.sh が削除するため、明示しないと exit 128 で止まる。
echo "[acceptance] (devcontainer) release script commits with an explicit identity"
if ! grep -q "git -c user.name=.*-c user.email=.* \\\\" scripts/release-packages.sh; then
  echo "[acceptance] scripts/release-packages.sh must commit with an explicit identity" >&2
  exit 1
fi

# ── CI: Docs and catalog consistency ─────────────────────────────────────────
echo "[acceptance] (docs) CATALOG lists every tracked file"
catalog_fail=0
while IFS= read -r f; do
  grep -q "\`$f\`" docs/CATALOG.md || { echo "[acceptance] not listed in docs/CATALOG.md: $f" >&2; catalog_fail=1; }
done < <(git ls-files 'docs/*.md')
while IFS= read -r f; do
  grep -q "\`$f\`" scripts/CATALOG.md || { echo "[acceptance] not listed in scripts/CATALOG.md: $f" >&2; catalog_fail=1; }
done < <(git ls-files 'scripts/*.sh')
[[ "$catalog_fail" -eq 0 ]] || exit 1

echo "[acceptance] (docs) CATALOG has no dangling entries"
# バッククォートで囲まれたパスを抜き出す。単一引用符はコマンド置換を
# 起こさせないための意図的な記述。
# shellcheck disable=SC2016
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  [[ -e "$f" ]] || { echo "[acceptance] listed but missing: $f" >&2; catalog_fail=1; }
done < <(grep -o '`docs/[^`]*`' docs/CATALOG.md | tr -d '`')
# shellcheck disable=SC2016
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  [[ -e "$f" ]] || { echo "[acceptance] listed but missing: $f" >&2; catalog_fail=1; }
done < <(grep -o '`scripts/[^`]*`' scripts/CATALOG.md | tr -d '`')
[[ "$catalog_fail" -eq 0 ]] || exit 1

echo "[acceptance] (docs) relative markdown links resolve"
link_fail=0
while IFS= read -r f; do
  d="$(dirname "$f")"
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    case "$l" in http*) continue ;; esac
    [[ -f "$d/$l" ]] || [[ -f "$l" ]] || { echo "[acceptance] dangling link: $f -> $l" >&2; link_fail=1; }
  done < <(grep -oE '\]\([^)#:]+\.md[)#]' "$f" | sed 's/^](//; s/[)#]$//')
done < <(git ls-files '*.md')
[[ "$link_fail" -eq 0 ]] || exit 1

# ── CI: Package neutrality ───────────────────────────────────────────────────
# 検査対象・除外条件の正本は scripts/check-neutrality.sh。CI の同名ジョブも同じ
# スクリプトを呼ぶため、本スクリプトが CI の完全ミラーであることが構造的に保たれる
# （条件を書き写さないので、片方だけが古くなる余地がない）。
echo "[acceptance] (neutrality) no project-specific names in packages or .ai-playbook"
bash scripts/check-neutrality.sh

# ── CI: identity-guard ───────────────────────────────────────────────────────
# 判定ロジックの正本は scripts/verify-commit-identity.sh。CI の identity-guard も
# 同じスクリプトを呼ぶため、条件を書き写さずミラーを保てる。
#
# 検査範囲の決め方:
#   identity-guard.yml は範囲をイベントから決める（pull_request なら base..head、
#   push(main) なら --full）。ローカルにはイベントが無いため、引数を渡さず
#   verify-commit-identity.sh 自身の既定解決に委ねる。既定は origin/main が
#   取得できれば origin/main..HEAD（= PR 経路の base..head と同じ範囲）で、
#   取得できなければ HEAD の全履歴（= push(main) 経路の --full と同じ）へ落ちる。
#   2 つの分岐が CI の 2 系統とそのまま対応するため、ここで範囲を計算し直す必要はない。
#
#   loop-gate.sh の resolve_review_range は流用しない。あちらは範囲を git diff へ
#   渡す前提で、起点が無いとき空ツリーへ落とす。git log へ渡す本検査とは
#   意味が異なり（verify-commit-identity.sh の resolve_range に明記がある）、
#   3 つ目の範囲定義を増やすことになる。
#
#   fail-closed のため、許可 email が解決できなければ落ちる。ローカルでは .env の
#   GIT_IDENTITY_EMAIL が、CI ではリポジトリ変数 ALLOWED_AUTHOR_EMAILS が供給元。
echo "[acceptance] (identity) commit identity guard"
bash scripts/verify-commit-identity.sh

# ── CI: Project tests ────────────────────────────────────────────────────────
# 文書と実装のテキスト照合だけで、外部依存も無く秒で終わる。DCB テスト（約 4 分）
# より前に置き、安い検査から落ちるようにする。
echo "[acceptance] (project) tests"
bash tests/run-tests.sh

# ── CI: devcontainer-bootstrap tests ─────────────────────────────────────────
# 所要時間が最も長い（約 4 分）ため最後に置く。手前の速い検査で落ちる差分は、
# ここへ到達する前に落として反復を短くする。
echo "[acceptance] (dcb) tests"
bash packages/devcontainer-bootstrap/tests/run-tests.sh

if [[ "$ran_any" -eq 0 ]]; then
  echo "[acceptance] 受け入れ条件が未定義です。検証対象が 1 つも見つかりません。" >&2
  echo "[acceptance] このプロジェクトの受け入れ条件（テスト等）を scripts/acceptance.sh に定義してください。" >&2
  exit 1
fi

echo "[acceptance] OK"
