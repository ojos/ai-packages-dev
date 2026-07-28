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

背景と経緯は [archive/RELEASE_PROCESS_RECORD.md](../archive/RELEASE_PROCESS_RECORD.md)（旧世代の記録）を参照。
現行のリリース履歴の正本は [RELEASE_HISTORY](RELEASE_HISTORY.md)。

## ゲート条件（すべて満たすこと）

`scripts/release-packages.sh` の preflight が以下を自動で検査する。1 つでも落ちれば、公開側にもローカルにも副作用を出さずに終了する。

| # | 検査 | 実行条件 | 実装 |
|---|---|---|---|
| 1 | 必要コマンド（`git` / `gh` / `bash` / `tar` / `sha256sum` / `python3`）が存在する | 常時 | `require_cmd` |
| 2 | 作業ツリーが clean | 常時 | `require_clean_worktree` |
| 3 | タグ形式が `vX.Y.Z` | 指定した版ごと | `extract_semver` |
| 4 | 指定バージョンが未公開（DCB は Release の有無、ai-playbook はタグの有無で判定） | 指定した版ごと | `require_version_unpublished` / `require_tag_unpublished` |
| 5 | DCB README の固定バージョン照合（3 箇所。「バージョンの正本」節を参照） | `--dcb-version` 指定時 | `validate_dcb_docs` |
| 6 | Markdown の相対リンク・アンカー検証（配下の `README*.md` が対象） | `--dcb-version` 時は `packages/devcontainer-bootstrap/` と `.ai-playbook/`、`--playbook-version` 時は `.ai-playbook/` | `validate_markdown_links_in_tree` |
| 7 | DCB 機能テスト `packages/devcontainer-bootstrap/tests/run-tests.sh`（約 4 分かかる） | `--dcb-version` 指定時 | `run_dcb_tests` |

検査は安い順に並ぶ。版の重複（#4）は問い合わせ 1 回で判定できるため、重い DCB 機能テスト（#7）より先に落ちる。

**ai-playbook 単独リリースでも `.ai-playbook/` の Markdown リンク検査（#6）は走る。**
DCB は規範パッケージの `templates/` を配布するため、DCB リリース時は `packages/devcontainer-bootstrap/` に加えて `.ai-playbook/` 側も検査される。
リンク切れやアンカー切れがあると、リリース対象のコード差分が無くても preflight は落ちる。

## 不変性

**公開済みバージョンは不変。** 同じバージョンでの再リリースは preflight で失敗し、副作用は出ない。
タグを固定した利用者にとって内容が変わらないことを保証するため。やり直すには版を上げるか、公開側を削除する。

## タグ命名

タグはパッケージごとの配布リポジトリに打つため、パッケージ名の接頭辞は付けない。

- `ojos/ai-playbook` に `vX.Y.Z`
- `ojos/devcontainer-bootstrap` に `vX.Y.Z`

`--dcb-version` / `--playbook-version` に渡す値も同じ `vX.Y.Z` 形式。
`extract_semver` が `^v[0-9]+\.[0-9]+\.[0-9]+$` 以外を弾くため、接頭辞付きや `v` 無しは preflight で落ちる。

## バージョンの正本

- DCB: `packages/devcontainer-bootstrap/README.md` の固定バージョン。
  preflight の `validate_dcb_docs` が次の **3 箇所**を照合し、1 つでも `--dcb-version` と揃わなければ落ちる。
  1. 見出し行 `最新安定リリース:`（または `Latest stable release:`）が存在すること
  2. 固定行 `` - `vX.Y.Z` `` が存在すること
  3. 取得手順の `TAG=vX.Y.Z` が一致すること
- ai-playbook: リリース時に `--playbook-version` で指定するタグ（README 側の照合はない）

## 実行手順

この節のコマンド例は、現行の公開版（DCB `v0.7.2` / ai-playbook `v0.1.4`。正本は [RELEASE_HISTORY](RELEASE_HISTORY.md)）の次のパッチ版を仮に置いたもの。
実際に出す版へ読み替える。公開済みの版を指定すると preflight（ゲート条件 #4）で落ちる。

### 1) 前提条件を整える

- 作業ツリーが clean であること。
  DCB の README 更新やリリースノートの追記は、**コミットまで済ませてから**実行する（ゲート条件 #2）。
- DCB を出す場合、`packages/devcontainer-bootstrap/README.md` の 3 箇所（「バージョンの正本」節）が目的の版に更新済みであること。
- 目的のバージョンが未公開であること（公開済みは不変。再公開は preflight で失敗する）。
- `gh` が認証済みで、配布リポジトリの push / Release 作成権限があること。
- **`--execute` を使う場合のみ**: プロジェクトルートの `.env` に `GIT_IDENTITY_NAME` と `GIT_IDENTITY_EMAIL` が設定されていること。

`--execute` は `/tmp` 配下の一時クローンでコミットする。そこはこのリポジトリの外なので local 設定を持たず、
`scripts/setup-git-identity.sh` が global identity を削除して `user.useConfigOnly=true` を立てているためフォールバックも無い。
`resolve_release_identity` がこの 2 つを解決できないと、公開側へ手を付ける前に exit 1 で停止する。
雛形は `.env.example`。**値そのものはこのランブックにも他の文書にも書かない**（変数名の記載に留める）。
identity の解決は preflight 通過後・最初の副作用の前に行われるため、**dry-run では `.env` は不要**。

### 2) dry-run で事前確認する

`--execute` を外して実行すると、preflight だけを走らせて `[info] dry-run mode. add --execute to publish releases` で終了する。
公開側にもローカルにも副作用は出ないため、本番実行の前に必ず一度通す。

```bash
set -euo pipefail
cd /workspaces/ojos-ai-packages-dev

# ai-playbook 側の事前確認
bash scripts/release-packages.sh --owner ojos --playbook-version v0.1.5

# DCB 側の事前確認（README を同じ版へ更新・コミット済みであること）
bash scripts/release-packages.sh --owner ojos --dcb-version v0.7.3

# 両方まとめて
bash scripts/release-packages.sh --owner ojos \
  --dcb-version v0.7.3 --playbook-version v0.1.5
```

`[ok] preflight checks passed` が出れば通過。
`--dcb-version` を含む dry-run は DCB 機能テスト（ゲート条件 #7）を含むため約 4 分かかる。

### 3) リリースノート

各パッケージの変更点を、該当するファイルへ追記する。

| パッケージ | リリースノート |
|---|---|
| `devcontainer-bootstrap` | [release-notes-devcontainer-bootstrap.md](release-notes-devcontainer-bootstrap.md) |
| `ai-playbook` | [release-notes-ai-playbook.md](release-notes-ai-playbook.md) |

あわせて [RELEASE_HISTORY](RELEASE_HISTORY.md) の現行バージョン表と版更新表を更新する。
追記した内容はコミットしてから次へ進む（作業ツリーが clean でないと preflight で落ちる）。

### 4) リリース実行

`scripts/release-packages.sh` が、ソースの反映・タグ付け・（DCB のみ）Release 作成をまとめて行う。
手動でのタグ作成や clone は不要。

```bash
set -euo pipefail
cd /workspaces/ojos-ai-packages-dev

# 片方だけ
bash scripts/release-packages.sh --owner ojos --dcb-version v0.7.3 --execute
bash scripts/release-packages.sh --owner ojos --playbook-version v0.1.5 --execute

# 両方
bash scripts/release-packages.sh --owner ojos \
  --dcb-version v0.7.3 --playbook-version v0.1.5 --execute
```

`--execute` の前に preflight が再度すべて走る。dry-run で通っていても、その後に作業ツリーを汚したり
公開側の状態が変わったりしていれば、ここで落ちる。

`--dcb-version` / `--playbook-version` は最低 1 つ。指定したパッケージだけを触り、他方の公開物には手を触れない。

パッケージごとの挙動:

- **DCB**: 公開リポジトリへソースを反映し、タグを push し、GitHub Release を作成して
  `bootstrap.sh` / `doctor.sh` / `SHA256SUMS` / `RELEASE-MANIFEST.json` / `PACKAGE_ARCHIVE.tar.gz` を添付する。
- **ai-playbook**: 公開リポジトリへソースを反映し、タグを push する。Release も資産も作らない。

公開処理のあと、`--execute` は次を自動で行う。

1. `scripts/update-release-status.sh --owner <owner> --readme README.md` を実行し、
   ルート `README.md` の `<!-- RELEASE_STATUS:START -->` 〜 `<!-- RELEASE_STATUS:END -->` ブロックを最新の公開状況へ書き換える
   （`[info] README release status refreshed. commit README.md if changed.`）。
   **書き換えるだけでコミットはしない。実行者が `README.md` の差分をコミットする必要がある**（手順 5）。
2. 各配布リポジトリの直近 3 リリースを一覧表示する。
3. DCB のリリース資産監査（`audit_release_assets`）を実行する。手順 5 で `--audit` を別途実行する必要はない。

やり直す場合は版を上げる。どうしても同じ版でやり直すなら、先に公開側を削除する:

```bash
# DCB（Release + タグ）
gh release delete <tag> --repo ojos/devcontainer-bootstrap --cleanup-tag
# ai-playbook（タグのみ）
git push https://github.com/ojos/ai-playbook.git :refs/tags/<tag>
```

### 5) 事後確認

- **ルート `README.md` の RELEASE_STATUS ブロックの差分をコミットする。**
  手順 4 で自動更新されるが、コミットは自動化されていない。放置すると README の公開状況が実態とずれる。
- 資産監査（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` の有無）は手順 4 の末尾で自動実行済み。
  あとから単独で再確認する場合のみ、次を使う（`--audit` は `--owner` だけを要求し、監査して終了する。
  ai-playbook は Release を持たないため対象外）:

```bash
bash scripts/release-packages.sh --owner ojos --audit
```

- 各リポジトリでタグがリモートに見えること。
- DCB は README の手順（`curl` + `sha256sum -c`）が通ること。
- ai-playbook は `archive/refs/tags/<tag>.tar.gz` が取得でき、展開したルートが `.ai-playbook/` の中身であること
  （配布リポジトリのルート = `.ai-playbook` の中身。`.ai-playbook` という階層は挟まらない）。

## ロールバック方針

リリース内容に誤りがあった場合:
- 修正版のパッチリリース（`vX.Y.(Z+1)`）を公開する
- 公開済みリリースタグの書き換えは、致命的な場合を除き行わない

## 責任分担

- 意思決定・調整: consult-facilitator
- 実装: implementer ロール
- レビュー・承認: reviewer ロール
- リリース実行: リポジトリの admin / タグ権限を持つメンテナ

