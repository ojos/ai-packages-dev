# リリース実行ランブック

このランブックは、実装 issue のマージ後に最終パッケージリリースを実行する手順を定義する。

**リリースの実行場所は GitHub Actions。ローカルからの実行経路は廃止した。**

## 対象範囲

対象リポジトリ:
- `ojos/ai-packages-dev`（開発・調整）
- `ojos/ai-playbook`
- `ojos/devcontainer-bootstrap`

## 実行場所

リリースは、このリポジトリの release workflow（`.github/workflows/release.yml`）を `workflow_dispatch` で起動して実行する。
実行環境を一本化するため、ローカル実行は廃止した。2 経路を残すと、手元の環境差（認証・処理系・作業ツリーの状態）に起因する失敗経路が構造的に残り続ける。

廃止は文書だけでなく機構で担保する。`scripts/release-packages.sh` は `GITHUB_ACTIONS` を見て、Actions 外での `--execute` を preflight より前に拒否する（非ゼロ終了・副作用なし）。
環境変数を手で偽装すれば越えられるが、それは故意の迂回であり、事故としてのローカル実行は必ず止まる。

手元から実行できるのは、公開側へ副作用を出さない次の 2 つに限る。

| 操作 | コマンド | 用途 |
|---|---|---|
| dry-run | `bash scripts/release-packages.sh --owner ojos --playbook-version vX.Y.Z` | preflight を手早く回して手戻りを短くする補助。本番の予行演習は Actions 側で行う（実行環境が違うため、手元で通っても本番の保証にはならない） |
| 資産監査 | `bash scripts/release-packages.sh --owner ojos --audit` | 公開済み Release の資産を取得し、SHA256 を再計算して整合性を検証する（直近 10 件。件数は `AUDIT_RELEASE_LIMIT` で変える） |

git identity は workflow が GitHub App の bot として渡す。実行者が `.env` に identity を用意する必要はない
（`.github/project-ai-rules.md`「Git identity」）。

## 前提条件（リポジトリ設定）

workflow は認証と identity をリポジトリ設定から解決する。値をコードへ焼き込まない方針のため、未設定のまま起動すると実行時に落ちる。

| 種別 | 名前 | 値 |
|---|---|---|
| Secret | `RELEASE_APP_ID` | リリース用 GitHub App（`ojos-release-bot`）の App ID |
| Secret | `RELEASE_APP_PRIVATE_KEY` | 同 App の秘密鍵（`.pem` の中身全文） |
| Variable | `RELEASE_BOT_NAME` | `ojos-release-bot[bot]` |
| Variable | `RELEASE_BOT_EMAIL` | `<bot ユーザー ID>+ojos-release-bot[bot]@users.noreply.github.com` |

いずれも Settings > Secrets and variables > Actions に置く（Secrets と Variables はタブが分かれている）。

- App は `ojos/devcontainer-bootstrap` と `ojos/ai-playbook` の 2 リポジトリへ install し、権限は `contents: write` のみを与える。Actions の `GITHUB_TOKEN` は自リポジトリにしかスコープが効かず、クロスリポジトリ push ができないため。
- bot ユーザー ID は install 後に `gh api '/users/ojos-release-bot[bot]' --jq '.id'` で取得する。**App ID とは別番号**で、コミットを bot アカウントへ紐付けるのはこちら。

### artifact attestation（#340）

`release.yml` は `SHA256SUMS` へ artifact attestation（SLSA provenance）を発行する。**設定は要らない**（secret も variable も追加しない）。workflow の `permissions` に `id-token: write` と `attestations: write` があれば足りる。

**このリポジトリが public でなければ発行できない。** private では拒否される（#189 の実測。`Feature not available for user-owned private repositories`）。

発行の流れ:

1. `release-packages.sh` が一時クローンで `SHA256SUMS` を作り、`ATTEST_SUBJECTS_DIR` が設定されていればその digest を `<package>.sha256` へ書く
2. workflow が digest を読み、`actions/attest-build-provenance` へ `subject-digest` として渡す
3. 対象が無い実行（playbook だけのリリース）では `if` で飛ばす

**dry-run では発行されない。** `--execute` が無ければ資産生成より前に終了する。

**発行元はこのリポジトリになる。** 資産は配布リポジトリのリリースに置かれるため、利用者は「配布リポジトリの owner」を指して検証する（同じ owner に属する attestation が引ける）。手順は DCB の README にある。

配線は `tests/test-release-attestation.sh` が機械照合する。**実際に発行できることは検査しない**（リリースの実行を要するため）。#340 では使い捨てのワークフローで発行と検証を実測し、票へ記録した。

## 配布方式（パッケージごとに異なる）

パッケージは消費モデルが異なるため、配布方式も異なる。均一の資産契約は課さない。

| パッケージ | 配布方式 | 消費者が取得するもの |
|---|---|---|
| `devcontainer-bootstrap` | GitHub Release + 資産 | `bootstrap.sh` / `doctor.sh` / `SHA256SUMS`（curl でダウンロード） |
| `ai-playbook` | git タグのみ（Release なし・資産なし） | git タグ（submodule / subtree / archive tarball で固定して取り込む） |

DCB の `SHA256SUMS` は、README がダウンロードさせるファイル（`bootstrap.sh` / `doctor.sh`）だけを対象にする。
検証する人が手元に持たないファイルを列挙すると `sha256sum -c` が失敗するため。
ai-playbook はリリース資産を持たない。DCB の `--playbook-from` も git 由来の `archive/refs/tags/` tarball を使う。

### 配布リポジトリのルートへ載せるファイル

両パッケージ共通で、配布リポジトリのルートへ次を載せる。正本は開発リポジトリ側にあり、配布はその写しになる。
一覧は `scripts/release-packages.sh` の `DCB_DISTRIBUTED_FILES` / `PLAYBOOK_DISTRIBUTED_FILES` が正本で、
dry-run（`execute: false`）が `[plan]` 行として出力する。

| 配布先のファイル | 開発リポジトリ側の正本 |
|---|---|
| `LICENSE` | `LICENSE`（MIT） |
| `CHANGELOG.md` | `docs/release/release-notes-devcontainer-bootstrap.md` / `docs/release/release-notes-ai-playbook.md` |

配布先には `docs/` 階層が存在しないため、リリースノートはルートで解決できる `CHANGELOG.md` へ改名して配る。
同じ理由で、リリースノート本文にリポジトリ内の相対リンクを書かない（配布先で解決できないリンクになる）。
`LICENSE` / `CHANGELOG.md` は規範ではないため、DCB の `--with-playbook` による取り込み対象からは外れる。

外部からの貢献は受け付けない。配布リポジトリはリリースのたびに全置換されるため、直接の PR は次のリリースで失われる。
この方針は両パッケージの README に明記する（CONTRIBUTING ファイルは置かない）。

背景と経緯は [archive/RELEASE_PROCESS_RECORD.md](../archive/RELEASE_PROCESS_RECORD.md)（旧世代の記録）を参照。
現行のリリース履歴の正本は [RELEASE_HISTORY](RELEASE_HISTORY.md)。

## ゲート条件（すべて満たすこと）

`scripts/release-packages.sh` の preflight が以下を自動で検査する。1 つでも落ちれば、公開側にも実行環境にも副作用を出さずに終了する。

| # | 検査 | 実行条件 | 実装 |
|---|---|---|---|
| 1 | 必要コマンド（`git` / `gh` / `bash` / `tar` / `sha256sum` / `python3`）が存在する | 常時 | `require_cmd` |
| 2 | 作業ツリーが clean | 常時 | `require_clean_worktree` |
| 3 | タグ形式が `vX.Y.Z` | 指定した版ごと | `extract_semver` |
| 4 | 指定バージョンが未公開（DCB は Release の有無、ai-playbook はタグの有無で判定） | 指定した版ごと | `require_version_unpublished` / `require_tag_unpublished` |
| 5 | DCB のバージョン正本照合（5 箇所。「バージョンの正本」節を参照） | `--dcb-version` 指定時 | `validate_dcb_docs` |
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

workflow の `dcb-version` / `playbook-version` に渡す値も同じ `vX.Y.Z` 形式。
`extract_semver` が `^v[0-9]+\.[0-9]+\.[0-9]+$` 以外を弾くため、接頭辞付きや `v` 無しは preflight で落ちる。

## バージョンの正本

- DCB: **版そのものの正本は、公開するタグ**（workflow の `dcb-version` 入力、`vX.Y.Z`）である。
  `packages/devcontainer-bootstrap/README.md` の 3 箇所と、
  `packages/devcontainer-bootstrap/bootstrap.sh` / `doctor.sh` の `DCB_VERSION` は、
  いずれもこのタグの**独立した写し**であり、5 箇所は対等（どちらかがどちらかから
  自動生成される関係にはない）。リリース準備で人手によりすべて揃える。
  preflight の `validate_dcb_docs` が次の **5 箇所**を照合し、1 つでも `dcb-version` と揃わなければ落ちる。
  1. `README.md` の見出し行 `最新安定リリース:`（または `Latest stable release:`）が存在すること
  2. `README.md` の固定行 `` - `vX.Y.Z` `` が存在すること
  3. `README.md` の取得手順の `TAG=vX.Y.Z` が一致すること
  4. `bootstrap.sh` の `DCB_VERSION="vX.Y.Z"` が一致すること
  5. `doctor.sh` の `DCB_VERSION="vX.Y.Z"` が一致すること

  4・5 は生成物の由来記録（`.devcontainer/ORIGIN`）と `doctor.sh` の自己診断（ネットワークを
  使わず、自身に埋め込んだ版で上流の更新を判定する）が使う値で、`bootstrap.sh` /
  `doctor.sh` はそれぞれ単体取得されうるため互いを参照できず、値を複製で持つ。
  `bootstrap.sh` と `doctor.sh` の**間**の整合は
  `packages/devcontainer-bootstrap/tests/test-origin-record.sh` が別に機械照合する
  （あちらは 2 ファイル間の整合を見ており、ここでの `validate_dcb_docs` は
  **リリースするタグとの**整合を見ている。見ているものが違うため両方を残す）。

  RUNBOOK 側のこの一覧と `validate_dcb_docs` の照合件数が一致することは
  `tests/test-dcb-version-anchors.sh` が機械照合する。一覧を増減したら
  `validate_dcb_docs` 側も同数に揃えること。
- ai-playbook: リリース時に `playbook-version` で指定するタグ（README 側の照合はない）

## workflow の入力

| 入力 | 値 | 既定 | 備考 |
|---|---|---|---|
| `dcb-version` | `vX.Y.Z` または空欄 | 空欄 | 出さない側は空欄にする |
| `playbook-version` | `vX.Y.Z` または空欄 | 空欄 | 両方を空欄にするとエラー |
| `execute` | `true` / `false` | `false` | `false` は dry-run。`true` は `main` からのみ起動できる |

パッケージは独立してリリースできる。指定した側だけを触り、空欄にした側の公開物には手を触れない。

多重起動は `concurrency` で直列化される。公開リポジトリを全置換する処理が並走すると内容が壊れるため、
実行中に同じ workflow を起動した場合は待ち合わせになる（進行中の実行はキャンセルされない）。

## 実行手順

この節の版は、現行の公開版（正本は [RELEASE_HISTORY](RELEASE_HISTORY.md)）の次のパッチ版を仮に置いたもの。
実際に出す版へ読み替える。公開済みの版を指定すると preflight（ゲート条件 #4）で落ちる。

### 1) リリース内容を main へ入れる

`execute: true` は `main` からしか起動できない。次をすべてコミットし、PR を経て `main` へマージしてから起動する。

- DCB を出す場合、バージョンの正本 5 箇所（「バージョンの正本」節。`README.md` の 3 箇所 + `bootstrap.sh` + `doctor.sh` の `DCB_VERSION`）が目的の版へ更新済みであること。
- 各パッケージの変更点をリリースノートへ追記していること。

  | パッケージ | リリースノート |
  |---|---|
  | `devcontainer-bootstrap` | [release-notes-devcontainer-bootstrap.md](release-notes-devcontainer-bootstrap.md) |
  | `ai-playbook` | [release-notes-ai-playbook.md](release-notes-ai-playbook.md) |

- [RELEASE_HISTORY](RELEASE_HISTORY.md) の現行バージョン表と版更新表を更新していること。

workflow は起動時の `main` の内容を配布する。マージ前の変更は配布されない。

### 2) dry-run で起動する

`execute: false`（既定）で起動する。preflight だけが走り、公開側にも副作用は出ない。本番実行の前に必ず一度通す。

```bash
# ai-playbook 側だけ
gh workflow run release.yml --ref main -f playbook-version=v0.1.6

# DCB 側だけ
gh workflow run release.yml --ref main -f dcb-version=v0.7.4

# 両方まとめて
gh workflow run release.yml --ref main -f dcb-version=v0.7.4 -f playbook-version=v0.1.6
```

GitHub の Actions 画面から `Run workflow` で起動してもよい。実行ログは `gh run watch` か Actions 画面で追う。

ログに `[ok] preflight checks passed` と `[plan]` 行、末尾の `[info] dry-run mode. add --execute to publish releases` が出れば通過。
`dcb-version` を含む dry-run は DCB 機能テスト（ゲート条件 #7）を含むため約 4 分かかる。

### 3) リリースを実行する

同じ入力に `execute: true` を足して起動する。

```bash
gh workflow run release.yml --ref main \
  -f dcb-version=v0.7.4 -f playbook-version=v0.1.6 -f execute=true
```

preflight がもう一度すべて走る。dry-run 通過後に `main` や公開側の状態が変わっていれば、ここで落ちる。

パッケージごとの挙動:

- **DCB**: 公開リポジトリへソースを反映し、タグを push し、GitHub Release を作成して
  `bootstrap.sh` / `doctor.sh` / `SHA256SUMS` / `RELEASE-MANIFEST.json` / `PACKAGE_ARCHIVE.tar.gz` を添付する。
- **ai-playbook**: 公開リポジトリへソースを反映し、タグを push する。Release も資産も作らない。

公開リポジトリへの release snapshot コミットは GitHub App の bot 名義になる。実行主体とコミット名義を一致させるため。

公開処理のあと、同じ実行の中で次が走る。

1. `scripts/update-release-status.sh` によるルート `README.md` の書き換え。
   **これは runner 上の作業ツリーに対する変更で、このリポジトリへはコミットされない**（手順 4 で手元から反映する）。
2. 各配布リポジトリの直近 3 リリースの一覧表示。
3. DCB のリリース資産監査（`audit_release_assets`）。手順 4 で `--audit` を別途実行する必要はない。

### 4) 事後確認

- **ルート `README.md` の RELEASE_STATUS ブロックを手元で更新してコミットする。**
  bot はこのモノレポへコミットしないため、この反映は人が行う。放置すると README の公開状況が実態とずれる。

  ```bash
  bash scripts/update-release-status.sh --owner ojos --readme README.md
  ```

- 各リポジトリでタグがリモートに見えること。
- DCB は README の手順（`curl` + `sha256sum -c`）が通ること。
- ai-playbook は `archive/refs/tags/<tag>.tar.gz` が取得でき、展開したルートが `.ai-playbook/` の中身であること
  （配布リポジトリのルート = `.ai-playbook` の中身。`.ai-playbook` という階層は挟まらない）。
- 資産監査は手順 3 の末尾で自動実行済み。あとから単独で再確認する場合のみ、手元で次を使う
  （`--audit` は `--owner` だけを要求し、監査して終了する。ai-playbook は Release を持たないため対象外）:

  ```bash
  bash scripts/release-packages.sh --owner ojos --audit
  ```

## 定期監査

公開後に資産が差し替えられた場合、リリース時の 1 回の検査では気づけない。`.github/workflows/release-audit.yml` が週次（月曜 03:17 UTC）で公開済みリリースを再検査する。`workflow_dispatch` で手動起動もできる。

- 検査対象は直近 10 件。手動起動時は `limit` 入力で変えられる。**検査した件数と、範囲外として見ていない件数は必ず出力に出る**（黙って打ち切ると「全部見た」と読めるため）。
- 読み取り専用で、公開状態は一切変更しない。
- 失敗が **2 回連続したときだけ** issue を起票する。1 回目では起票しない（一過性のネットワークエラーで issue が溜まるのを避けるため）。同じ失敗で open issue が既にあればコメント追記に留める。判定と起票は `scripts/audit-failure-notify.sh` が持つ。

## 失敗時の対応

**前進復旧のみを持つ。自動の巻き戻しは無い。** 公開済みリリースは不変であり、巻き戻しはその前提と正面から衝突するため。

- **preflight で落ちた場合**: 副作用は出ていない。原因を直して `main` へ入れ、同じ手順をやり直す。
- **副作用へ入ってから落ちた場合**: 原因を直し、**同じ入力で再実行する**。処理は冪等で、差分が無ければコミットせず、既存タグは push せず、公開済み Release は preflight が拒否する。既に反映済みの部分が二重に適用されることはない。
- **片方だけ公開できていた場合**: 公開済みの側を空欄にし、残りの版だけを指定して再実行してもよい。公開済みの側を指定したままでも、その側は preflight（ゲート条件 #4）で拒否されるため、再公開はされない。
- **同じ版でやり直したい場合**: 原則は版を上げる。どうしても同じ版が必要なときに限り、例外として公開側を先に削除する。

  ```bash
  # DCB（Release + タグ）
  gh release delete <tag> --repo ojos/devcontainer-bootstrap --cleanup-tag
  # ai-playbook（タグのみ）
  git push https://github.com/ojos/ai-playbook.git :refs/tags/<tag>
  ```

  これは公開状態の手動操作にあたる。実施したら、スクリプト側の前提（README の固定バージョン等）へ後追いで反映する。

## ロールバック方針

リリース内容に誤りがあった場合:
- 修正版のパッチリリース（`vX.Y.(Z+1)`）を公開する
- 公開済みリリースタグの書き換えは、致命的な場合を除き行わない

## 責任分担

- 意思決定・調整: consult-facilitator
- 実装: implementer ロール
- レビュー・承認: reviewer ロール
- リリース実行: release workflow を起動する権限を持つメンテナ
