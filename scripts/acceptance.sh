#!/usr/bin/env bash
# acceptance.sh — このプロジェクトの受け入れ条件（プロジェクトが所有・編集する）
#
# verify.sh がこのスクリプトを実行し、終了コードで合否を判定する。
#
# このリポジトリは CI（.github/workflows/ci.yml）の 5 ジョブを完全ミラーする。
# 「ローカルが緑なら CI も緑」を保つのが目的で、部分ミラーは push してから CI で
# 落ちる経路を残すため採らない。
#
# 二重管理の負債:
#   ci.yml を変更したら、このファイルも同じ内容へ追随させること。CI とここが
#   食い違うと、ローカルゲートは「CI の予行演習」ではなくなり、通っても意味を
#   持たなくなる。追随漏れを機械で検知する仕組みは今のところ無い。
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
shellcheck -x packages/devcontainer-bootstrap/bootstrap.sh packages/devcontainer-bootstrap/doctor.sh

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
# プロジェクト固有の値がパッケージ層と規範層へ混入していないことを検証する。
# tests/ は除外する（配布されない層であり、生成物に固有名詞が残らないことを
# 検証する都合上、検査対象語をリテラルで持つ必要があるため）。
# 対象拡張子は .github/workflows/ci.yml の同名ジョブと一致させる（本スクリプトは
# CI の完全ミラーであり、片方だけが検知する状態を作らない）。*.yml / *.yaml は
# 規範層が配布する workflow テンプレート（.ai-playbook/templates/*.yml）を含む。
echo "[acceptance] (neutrality) no project-specific names in packages or .ai-playbook"
if grep -rniE 'bascule|ojos' packages/ .ai-playbook/ \
  --include='*.sh' --include='*.md' --include='*.json' \
  --include='*.yml' --include='*.yaml' --exclude-dir=tests \
  | grep -v 'ojos/devcontainer-bootstrap' \
  | grep -v 'ojos/ai-playbook'; then
  echo "[acceptance] project-specific names must not leak into packages/ or .ai-playbook/" >&2
  exit 1
fi

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
