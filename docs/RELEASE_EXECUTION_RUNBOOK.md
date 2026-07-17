# リリース実行ランブック

このランブックは、実装 issue のマージ後に最終パッケージリリースを実行する手順を定義する。

## 対象範囲

対象リポジトリ:
- `ojos/ai-packages-dev`（開発・調整）
- `ojos/ai-playbook`
- `ojos/devcontainer-bootstrap`

## 配布方式（パッケージごとに異なる）

パッケージは消費モデルが異なるため、配布方式も異なる。均一の資産契約は課さない。

| パッケージ | 配布方式 | 消費者が取得するもの |
|---|---|---|
| `devcontainer-bootstrap` | GitHub Release + 資産 | `bootstrap.sh` / `doctor.sh` / `SHA256SUMS`（curl でダウンロード） |
| `ai-playbook` | git タグのみ（Release なし・資産なし） | git タグ（submodule / subtree / archive tarball で固定して取り込む） |

DCB の `SHA256SUMS` は、README がダウンロードさせるファイル（`bootstrap.sh` / `doctor.sh`）だけを対象にする。
検証する人が手元に持たないファイルを列挙すると `sha256sum -c` が失敗するため。
ai-playbook はリリース資産を持たない。DCB の `--playbook-from` も git 由来の `archive/refs/tags/` tarball を使う。

背景と経緯は [archive/RELEASE_PROCESS_RECORD.md](archive/RELEASE_PROCESS_RECORD.md)（旧世代の記録）を参照。
現行のリリース履歴の正本は [RELEASE_HISTORY](RELEASE_HISTORY.md)。

## ゲート条件（すべて満たすこと）

- 作業ツリーが clean（`scripts/release-packages.sh` の preflight が検査する）
- 指定バージョンが未公開（DCB は Release、ai-playbook はタグの有無で判定。preflight が検査する）

## 不変性

**公開済みバージョンは不変。** 同じバージョンでの再リリースは preflight で失敗し、副作用は出ない。
タグを固定した利用者にとって内容が変わらないことを保証するため。やり直すには版を上げるか、公開側を削除する。

## タグ命名

- `ai-playbook/vX.Y.Z`
- `devcontainer-bootstrap/vX.Y.Z`

## バージョンの正本

- DCB: `packages/devcontainer-bootstrap/README.md` の固定バージョン（preflight が照合する）
- ai-playbook: リリース時に指定するタグ

## 実行手順

### 1) 事前確認

- 作業ツリーが clean であること。
- DCB を出す場合、`packages/devcontainer-bootstrap/README.md` の固定バージョンが目的の版と一致すること。
- 目的のバージョンが未公開であること（公開済みは不変。再公開は preflight で失敗する）。

これらは `scripts/release-packages.sh` の preflight が自動で検査する。

### 2) リリースノート

各パッケージの変更点を `docs/release-notes-*.md` に追記する。

### 3) リリース実行

`scripts/release-packages.sh` が、ソースの反映・タグ付け・（DCB のみ）Release 作成をまとめて行う。
手動でのタグ作成や clone は不要。

```bash
set -euo pipefail
cd /workspaces/ojos-ai-packages-dev

# 片方だけ
bash scripts/release-packages.sh --owner ojos --dcb-version v0.1.1 --execute
bash scripts/release-packages.sh --owner ojos --playbook-version v0.2.0 --execute

# 両方
bash scripts/release-packages.sh --owner ojos \
  --dcb-version v0.1.1 --playbook-version v0.2.0 --execute
```

`--dcb-version` / `--playbook-version` は最低 1 つ。指定したパッケージだけを触り、他方の公開物には手を触れない。

パッケージごとの挙動:

- **DCB**: 公開リポジトリへソースを反映し、タグを push し、GitHub Release を作成して
  `bootstrap.sh` / `doctor.sh` / `SHA256SUMS` / `RELEASE-MANIFEST.json` / `PACKAGE_ARCHIVE.tar.gz` を添付する。
- **ai-playbook**: 公開リポジトリへソースを反映し、タグを push する。Release も資産も作らない。

やり直す場合は版を上げる。どうしても同じ版でやり直すなら、先に公開側を削除する:

```bash
# DCB（Release + タグ）
gh release delete <tag> --repo ojos/devcontainer-bootstrap --cleanup-tag
# ai-playbook（タグのみ）
git push https://github.com/ojos/ai-playbook.git :refs/tags/<tag>
```

### 4) 事後確認

- DCB の Release 資産が揃っているか監査する（ai-playbook は Release を持たないため対象外）:

```bash
bash scripts/release-packages.sh --owner ojos --audit
```

- 各リポジトリでタグがリモートに見えること。
- DCB は README の手順（`curl` + `sha256sum -c`）が通ること。
- ai-playbook は `archive/refs/tags/<tag>.tar.gz` が取得でき、`.ai-playbook` を含むこと。

## ロールバック方針

リリース内容に誤りがあった場合:
- 修正版のパッチリリース（`vX.Y.(Z+1)`）を公開する
- 公開済みリリースタグの書き換えは、致命的な場合を除き行わない

## 責任分担

- 意思決定・調整: consult-facilitator
- 実装: implementer ロール
- レビュー・承認: reviewer ロール
- リリース実行: リポジトリの admin / タグ権限を持つメンテナ

