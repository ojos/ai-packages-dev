# リリース実行ランブック

このランブックは、実装 issue のマージ後に最終パッケージリリースを実行する手順を定義する。

**リリースの実行場所は GitHub Actions。ローカルからの実行経路は廃止した。**

## 対象範囲

対象リポジトリ:
- `ojos/ai-packages-dev`（開発・調整）
- `ojos/ai-playbook`
- `ojos/devcontainer-bootstrap`
- `ojos/devcontainer-host`（devhost。#486）

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
| Secret | `RELEASE_APP_CLIENT_ID` | リリース用 GitHub App（`ojos-release-bot`）の Client ID（`Iv` で始まる。App ID ではない。`create-github-app-token@v3` で `app-id` が非推奨になったため。#432） |
| Secret | `RELEASE_APP_PRIVATE_KEY` | 同 App の秘密鍵（`.pem` の中身全文） |
| Variable | `RELEASE_BOT_NAME` | `ojos-release-bot[bot]` |
| Variable | `RELEASE_BOT_EMAIL` | `<bot ユーザー ID>+ojos-release-bot[bot]@users.noreply.github.com` |

いずれも Settings > Secrets and variables > Actions に置く（Secrets と Variables はタブが分かれている）。

- App は `ojos/devcontainer-bootstrap`・`ojos/ai-playbook`・`ojos/devcontainer-host` の 3 リポジトリへ install し、権限は `contents: write` のみを与える。**`ojos/devcontainer-host` への install は、利用者の手作業である**（リポジトリそのものは `infra/github/` の Terraform が作るが、App の install は個人のアカウントでは PAT で扱えない見込みのため Terraform の範囲外。#487）。トークンの対象リポジトリは、公開する側だけに絞る（`release.yml` の手前のステップが、`host-version` を指定したときだけ `devcontainer-host` を加える）。install 前でも、DCB だけ・ai-playbook だけのリリースは通る。`host-version` を指定したときに install を忘れていると、トークンの発行で落ちる。Actions の `GITHUB_TOKEN` は自リポジトリにしかスコープが効かず、クロスリポジトリ push ができないため。
- bot ユーザー ID は install 後に `gh api '/users/ojos-release-bot[bot]' --jq '.id'` で取得する。**App ID とは別番号**で、コミットを bot アカウントへ紐付けるのはこちら。
- **配布先の公開リポジトリそのもの（存在と設定）は、このワークフローではなく `infra/github/` の Terraform が作る**（#487。`.github/project-ai-rules.md`「外部サービスの状態管理」）。新しい配布先を足すときは、先にそちらの PR で作ってから、App の install（手作業）とこのワークフローの対応を行う。

### artifact attestation（#340）

`release.yml` は `SHA256SUMS` へ artifact attestation（SLSA provenance）を発行する。**設定は要らない**（secret も variable も追加しない）。workflow の `permissions` に `id-token: write` と `attestations: write` があれば足りる。

**このリポジトリが public でなければ発行できない。** private では拒否される（#189 の実測。`Feature not available for user-owned private repositories`）。

発行の流れ:

1. `release-packages.sh` が一時クローンで `SHA256SUMS` を作り、`ATTEST_SUBJECTS_DIR` が設定されていればその digest を `<package>.sha256` へ書く（ステージングの時点。公開の証明ではない）
2. `release-packages.sh` が、そのパッケージの公開（`tag_and_release`）に成功した時点で `<package>.published` の印を同じ場所へ書く（`mark_attest_published`）
3. workflow が、**印のあるパッケージの digest だけ**を読み、`actions/attest-build-provenance` へ `subject-digest` として渡す。公開に進まなかった（あるいは公開に失敗した）パッケージには発行しない
4. 対象が無い実行（playbook だけのリリース）では `if` で飛ばす

途中で失敗しても、公開に成功したパッケージの attestation は発行される（`!cancelled()`）。

**dry-run では発行されない。** `--execute` が無ければ資産生成より前に終了する。

**発行元はこのリポジトリになる。** 資産は配布リポジトリのリリースに置かれるため、利用者は「配布リポジトリの owner」を指して検証する（同じ owner に属する attestation が引ける）。手順は DCB の README にある。

配線は `tests/test-release-attestation.sh` が機械照合する。**実際に発行できることは検査しない**（リリースの実行を要するため）。#340 では使い捨てのワークフローで発行と検証を実測し、票へ記録した。

#### 発行だけが失敗したときの復旧

**attest ステップは `gh release create` の後に走る。** attestation API の一時障害でそこだけが失敗すると、**attestation の無いリリースが公開されたまま残る。** 同じ版での再実行は preflight が拒否するため（公開済みバージョンは不変）、`release.yml` では修復できない。

**公開されたのに印が書かれない場合も、同じ手順で復旧する。** `gh release create` が公開に成功したあとに 0 以外で終わると（`tag_and_release` の後段の失敗など）、`mark_attest_published` に到達せず、印が書かれないので attestation が付かない（印の導入前は digest だけで発行されていた）。見分け方は、リリースが公開されている（`gh release view <tag> --repo <owner>/<repo>` が成功する）のに、`gh attestation verify SHA256SUMS --owner <owner>` が失敗する、または release.yml の「Read the attestation subjects」のログに「発行を飛ばします」が出ていること。この場合も下の `attest-recover.yml` で発行し直す（挙動は変えていない）。

**`attest-recover.yml` を使う**（`workflow_dispatch` のみ）。attestation は digest だけを対象にできるので、資産を作り直さずに後から発行できる。

```bash
# 1. 公開済みの SHA256SUMS を取得して digest を求める
#    この手順はメンテナの手元で叩くため、macOS も想定して分岐する。
curl -sSL "https://github.com/ojos/devcontainer-bootstrap/releases/download/<tag>/SHA256SUMS" -o SHA256SUMS
if command -v sha256sum >/dev/null 2>&1; then sha256c="sha256sum"; else sha256c="shasum -a 256"; fi
$sha256c SHA256SUMS

# 2. その 64 桁を渡して実行する
gh workflow run attest-recover.yml -f subject-digest=<64 桁の 16 進>
```

- **入力は形を検査してから発行する。** 64 桁の小文字 16 進以外は弾く（`sha256:` を付けた形も弾く）。誰も検証できない attestation を増やさないため
- **発行し直しても既存の attestation は消えない。** 同じ digest に複数付くだけで、検証はどれか 1 つが通れば成功する
- **契機は `workflow_dispatch` だけに限定している。** 公開リポジトリで発行権限を持つ workflow を自動起動させない（#203 の懸念 7）。`tests/test-release-attestation.sh` がこれを固定する

## 配布方式（パッケージごとに異なる）

パッケージは消費モデルが異なるため、配布方式も異なる。均一の資産契約は課さない。

| パッケージ | 配布方式 | 消費者が取得するもの |
|---|---|---|
| `devcontainer-bootstrap` | GitHub Release + 資産 | `bootstrap.sh` / `doctor.sh` / `SHA256SUMS`（curl でダウンロード） |
| `devcontainer-host` | GitHub Release + 資産（DCB と同じ形に加え、`dev.sh` / `dev-up@.service` / `install.sh` / `projects.example` を個別に添付） | `install.sh`（マニフェストで照合してから実行する）、`dev.sh` / `dev-up@.service`（`dev self-update` は `dev.sh` を直接取得する）、または `PACKAGE_ARCHIVE.tar.gz`（ツリー一式） |
| `ai-playbook` | git タグのみ（Release なし・資産なし） | git タグ（submodule / subtree / archive tarball で固定して取り込む） |

DCB の `SHA256SUMS` は、README がダウンロードさせるファイル（`bootstrap.sh` / `doctor.sh` / `PACKAGE_ARCHIVE.tar.gz`）を対象にする（アーカイブは attestation からアーカイブまで辿れるようにするため。#491）。
検証する人が手元に持たないファイルを列挙すると `sha256sum -c` が失敗するため、README の手順は取得したファイルの行だけを抜き出して検証する。
ai-playbook はリリース資産を持たない。DCB の `--playbook-from` も git 由来の `archive/refs/tags/` tarball を使う。

**devhost（`packages/devcontainer-host/.`）は DCB に同梱せず、独自の版を持つ公開リポジトリ `ojos/devcontainer-host` から配る（#486。#376 で DCB への同梱としていたものを移した）。**
配布先のルートに `packages/devcontainer-host/` の中身（`dev.sh`・`dev-up@.service`・`README.md`・`selftest.sh`・`*.example`・`termux/` など）が並ぶ。
Release の資産は DCB と同じ `RELEASE-MANIFEST.json`・`SHA256SUMS`・`PACKAGE_ARCHIVE.tar.gz` に加えて、**`dev.sh`・`dev-up@.service`・`install.sh`・`projects.example` を個別の資産として添付する**（#495）。
この 4 つは `SHA256SUMS` と `RELEASE-MANIFEST.json` の `checksums` の対象になる（`dev self-update` が `checksums["dev.sh"]` と取得した `dev.sh` を、`install.sh` が `dev.sh` / `dev-up@.service` / `projects.example` を照合する。`install.sh` 自身は、README の手順が `checksums["install.sh"]` と照合してから実行する）。
`projects.example` を個別の資産にしたのは、アーカイブから取り出す経路だと、アーカイブの展開とそのハッシュの照合という別の経路が `install.sh` に増えるため。個別の資産なら `dev.sh` と同じ照合の経路で済む。
個別の資産にするのは単一ファイル名のものだけで、複数ファイル・サブディレクトリ（`termux/`）を持つツリーは `PACKAGE_ARCHIVE.tar.gz` に乗せる（`SHA256SUMS` / `RELEASE-MANIFEST.json` の資産名は単一ファイル名の前提で、`is_plain_asset_name`・監査側）。
`SHA256SUMS` には DCB と同じく artifact attestation を発行する。**DCB と違い、devcontainer-host の `SHA256SUMS` は `PACKAGE_ARCHIVE.tar.gz` も対象に含める**（attestation の対象は `SHA256SUMS` 1 つなので、アーカイブが無いと、アーカイブとマニフェストの archive 用ハッシュを一緒に差し替えられても検証が通る）。導入手順は `packages/devcontainer-host/README.md`。
DCB の `PACKAGE_ARCHIVE.tar.gz` に `devhost/` は含まれない（`packages/devcontainer-bootstrap/tests/test-release-no-devhost-bundle.sh` が固定する）。

**#376 の acceptance と、実際に入った旧方式は違う。** #376（devhost を DCB のリリースへ同梱する）の acceptance は「配布ツリーと `SHA256SUMS` に devhost の一式が含まれる」だった。実際に入った方式（v0.14.0〜v0.17.0）は、devhost を `PACKAGE_ARCHIVE.tar.gz` の `devhost/` に載せただけで、**`SHA256SUMS` には含めなかった**（対象は `bootstrap.sh` / `doctor.sh` のまま）。つまり acceptance の「`SHA256SUMS` に含める」は満たされておらず、アーカイブ内の devhost は `SHA256SUMS` の行を持たなかった（マニフェストの `PACKAGE_ARCHIVE.tar.gz` のハッシュ経由でしか辿れなかった）。#486 で同梱ごと外したため旧方式は現行ではないが、旧版（v0.14.0〜v0.17.0）の検証範囲を読むときはこの差に注意する。現行は、DCB・devcontainer-host とも `SHA256SUMS` が `PACKAGE_ARCHIVE.tar.gz` を持つ（#491）。

### 配布リポジトリのルートへ載せるファイル

3 パッケージ共通で、配布リポジトリのルートへ次を載せる。正本は開発リポジトリ側にあり、配布はその写しになる。
一覧は `scripts/release-packages.sh` の `DCB_DISTRIBUTED_FILES` / `HOST_DISTRIBUTED_FILES` / `PLAYBOOK_DISTRIBUTED_FILES` が正本で、
dry-run（`execute: false`）が `[plan]` 行として出力する。

| 配布先のファイル | 開発リポジトリ側の正本 |
|---|---|
| `LICENSE` | `LICENSE`（MIT） |
| `CHANGELOG.md` | `docs/release/release-notes-devcontainer-bootstrap.md` / `docs/release/release-notes-devcontainer-host.md` / `docs/release/release-notes-ai-playbook.md` |

配布先には `docs/` 階層が存在しないため、リリースノートはルートで解決できる `CHANGELOG.md` へ改名して配る。
同じ理由で、リリースノート本文にリポジトリ内の相対リンクを書かない（配布先で解決できないリンクになる）。
`LICENSE` / `CHANGELOG.md` は規範ではないため、DCB の `--with-playbook` による取り込み対象からは外れる。

devcontainer-host は、上の共通ファイルに加えて `packages/devcontainer-host/.` をルート直下へ載せる（一覧は `HOST_DISTRIBUTED_FILES` と `prepare_host_release_repo`）。
`CHANGELOG.md` の正本は `docs/release/release-notes-devcontainer-host.md`。DCB と ai-playbook には devhost を載せない。

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
| 4 | 指定バージョンが未公開（DCB と devcontainer-host は Release の有無、ai-playbook はタグの有無で判定） | 指定した版ごと | `require_version_unpublished` / `require_tag_unpublished` |
| 5 | DCB のバージョン正本照合（5 箇所。「バージョンの正本」節を参照） | `--dcb-version` 指定時 | `validate_dcb_docs` |
| 6 | Markdown の相対リンク・アンカー検証（配下の `README*.md` が対象） | `--dcb-version` 時は `packages/devcontainer-bootstrap/` と `.ai-playbook/`、`--playbook-version` 時は `.ai-playbook/`、`--host-version` 時は `packages/devcontainer-host/` | `validate_markdown_links_in_tree` |
| 7 | DCB 機能テスト `packages/devcontainer-bootstrap/tests/run-tests.sh`（テストファイルを CPU 数で並列に実行する。直列では約 20 分、14 コアの手元で約 4 分。Actions のランナーでは release.yml 全体で約 10 分（2026-10-07 の実測）。並列度は `DCB_TEST_JOBS` で変えられる） | `--dcb-version` 指定時 | `run_dcb_tests` |
| 8 | `dev.sh` に `DEV_VERSION="vX.Y.Z"` の行がちょうど 1 つある（リリースの手順が公開する版を書き込む行） | `--host-version` 指定時 | `validate_host_version_anchor` |
| 10 | devcontainer-host の文書が公開するタグと一致する（`README.md` の `TAG=` と `--version` の例、リリースノートの `## vX.Y.Z` の見出し） | `--host-version` 指定時 | `validate_host_docs` |
| 9 | devhost の自己試験 `packages/devcontainer-host/selftest.sh`（偽の `curl` / `docker` などを使い、ネットワークには出ない。数秒） | `--host-version` 指定時 | `run_host_tests` |

検査は安い順に並ぶ。版の重複（#4）は問い合わせ 1 回で判定できるため、重い DCB 機能テスト（#7）より先に落ちる。

**ai-playbook 単独リリースでも `.ai-playbook/` の Markdown リンク検査（#6）は走る。**
DCB は規範パッケージの `templates/` を配布するため、DCB リリース時は `packages/devcontainer-bootstrap/` に加えて `.ai-playbook/` 側も検査される。
リンク切れやアンカー切れがあると、リリース対象のコード差分が無くても preflight は落ちる。

## workflow 側のゲート（preflight より前）

**上の表は `scripts/release-packages.sh` の preflight である。それより前に、workflow 自身が 1 つ検査する。**

| 検査 | 実行条件 | 実装 |
|---|---|---|
| 配るコミットに対する `ci.yml` の実行が、success で完了している | `execute: true` のときだけ | `scripts/check-release-commit-verified.sh` |

**なぜ preflight ではなく workflow 側か。** preflight は手元のツリーを見る検査で、`ci.yml` の結論は GitHub 側にしかない。判定に API が要るため、置き場所が分かれる。

**何を止めるか。** `release.yml` の `actions/checkout` は ref を渡さないので、配るのは**起動時点の `main` の head** である。`ci.yml` は `push: branches: [main]` で走るため、マージで生まれたコミットには新しい実行が作られる——ruleset の必須チェックは PR の head に対する評価であって、squash で生まれたコミットを見たわけではない。したがって「マージ直後、その実行が終わる前に起動する」窓が開く。

**判定できないときは配らない。** 実行が 1 件も無い（契機のイベントが届かない状態は実在する）、完了していない実行がある、のいずれも赤にする。実行が複数あれば、**すべて完了していることを確かめたうえで最新の実行の結論**を見る（再実行で緑にした場合は通し、再実行で赤くなった場合は止める）。

**この検査が見ないこと。** 起動してから配り終えるまでの間に `main` が進む場合は対象外である。配るのは起動時点の head のままで、それは別の問題である。

## 不変性

**公開済みバージョンは不変。** 同じバージョンでの再リリースは preflight で失敗し、副作用は出ない。
タグを固定した利用者にとって内容が変わらないことを保証するため。やり直すには版を上げるか、公開側を削除する。

## タグ命名

タグはパッケージごとの配布リポジトリに打つため、パッケージ名の接頭辞は付けない。

- `ojos/ai-playbook` に `vX.Y.Z`
- `ojos/devcontainer-bootstrap` に `vX.Y.Z`
- `ojos/devcontainer-host` に `vX.Y.Z`

workflow の `dcb-version` / `playbook-version` / `host-version` に渡す値も同じ `vX.Y.Z` 形式。
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
- devcontainer-host: **版そのものの正本は、公開するタグ**（workflow の `host-version` 入力、`vX.Y.Z`）である。DCB と違い、リポジトリの中の写しとの照合ではなく**書き込み**にする。リリースの手順（`stamp_host_version`）が、配布ツリーの `dev.sh` の `DEV_VERSION="vX.Y.Z"` の行をタグの値に書き換えてから資産を作る（`dev version` / `dev --version` が出す値）。`packages/devcontainer-host/dev.sh` の中の値は次に出す版の目印で、公開物の値ではない。preflight の `validate_host_version_anchor` は、行の形が崩れていないこと（ちょうど 1 行）だけを見る。`packages/devcontainer-host/README.md` の `TAG=vX.Y.Z` と `--version vX.Y.Z` の例、`release-notes-devcontainer-host.md` の `## vX.Y.Z` の見出しは、リリース準備で人手により公開するタグへ揃え、`validate_host_docs` が照合する（食い違えば落ちる。DCB の `validate_dcb_docs` と同じ方式）。
- ai-playbook: リリース時に `playbook-version` で指定するタグ（README 側の照合はない）

## workflow の入力

| 入力 | 値 | 既定 | 備考 |
|---|---|---|---|
| `dcb-version` | `vX.Y.Z` または空欄 | 空欄 | 出さない側は空欄にする |
| `playbook-version` | `vX.Y.Z` または空欄 | 空欄 | 3 つの版（`dcb-version` / `playbook-version` / `host-version`）をすべて空欄にするとエラー |
| `host-version` | `vX.Y.Z` または空欄 | 空欄 | 出さない側は空欄にする |
| `execute` | `true` / `false` | `false` | `false` は dry-run。`true` は `main` からのみ起動できる |

パッケージは独立してリリースできる。指定した側だけを触り、空欄にした側の公開物には手を触れない。

多重起動は `concurrency` で直列化される。公開リポジトリを全置換する処理が並走すると内容が壊れるため、
実行中に同じ workflow を起動した場合は待ち合わせになる（進行中の実行はキャンセルされない）。

## 実行手順

この節の版は、現行の公開版（正本は [RELEASE_HISTORY](RELEASE_HISTORY.md)）の次のパッチ版を仮に置いたもの。
実際に出す版へ読み替える。公開済みの版を指定すると preflight（ゲート条件 #4）で落ちる。

### 1) リリース内容を main へ入れる

`execute: true` は `main` からしか起動できない。次をすべてコミットし、PR を経て `main` へマージしてから起動する。

- devcontainer-host を出す場合、`README.md` の `TAG=` / `--version` の例とリリースノートの見出しを目的の版へ揃えていること（必須。`validate_host_docs`）。`packages/devcontainer-host/dev.sh` の `DEV_VERSION` も揃えておくと読み手が迷わない（公開物の値はリリースの手順が書き込むので、揃っていなくても公開物は正しい）。
- DCB を出す場合、バージョンの正本 5 箇所（「バージョンの正本」節。`README.md` の 3 箇所 + `bootstrap.sh` + `doctor.sh` の `DCB_VERSION`）が目的の版へ更新済みであること。
- 各パッケージの変更点をリリースノートへ追記していること。

  | パッケージ | リリースノート |
  |---|---|
  | `devcontainer-bootstrap` | [release-notes-devcontainer-bootstrap.md](release-notes-devcontainer-bootstrap.md) |
  | `devcontainer-host` | [release-notes-devcontainer-host.md](release-notes-devcontainer-host.md) |
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

# devcontainer-host 側だけ
gh workflow run release.yml --ref main -f host-version=v0.1.0

# まとめて
gh workflow run release.yml --ref main -f dcb-version=v0.7.4 -f playbook-version=v0.1.6 -f host-version=v0.1.0
```

GitHub の Actions 画面から `Run workflow` で起動してもよい。実行ログは `gh run watch` か Actions 画面で追う。

ログに `[ok] preflight checks passed` と `[plan]` 行、末尾の `[info] dry-run mode. add --execute to publish releases` が出れば通過。
`dcb-version` を含む dry-run は DCB 機能テスト（ゲート条件 #7）を含む。直列だった時点では約 20 分かかった（ai-playbook v0.8.0 / DCB v0.16.0 の dry-run・本実行はどちらも約 22 分。2026-10-06）。並列化（#458）のあとは CPU 数に依存し、14 コアの手元では約 4 分。Actions のランナーでは、ai-playbook v0.8.1 / DCB v0.17.0 の dry-run が約 10 分、本実行が約 11 分だった（2026-10-07）。待ちの打ち切りは、ランナーの混み具合の揺れを見込んで 20 分より長く取る。

### 3) リリースを実行する

同じ入力に `execute: true` を足して起動する。

```bash
gh workflow run release.yml --ref main \
  -f dcb-version=v0.7.4 -f playbook-version=v0.1.6 -f execute=true
```

**配るコミットの `ci.yml` が緑で完了していなければ、ここで落ちる**（「workflow 側のゲート（preflight より前）」節）。マージ直後に起動して実行がまだ終わっていない場合も同じく落ちるので、CI の完了を待ってから起動する。

preflight がもう一度すべて走る。dry-run 通過後に `main` や公開側の状態が変わっていれば、ここで落ちる。

パッケージごとの挙動:

- **DCB**: 公開リポジトリへソースを反映し、タグを push し、GitHub Release を作成して
  `bootstrap.sh` / `doctor.sh` / `SHA256SUMS` / `RELEASE-MANIFEST.json` / `PACKAGE_ARCHIVE.tar.gz` を添付する。
- **devcontainer-host**: 公開リポジトリへソースを反映し（`dev.sh` の `DEV_VERSION` を公開するタグへ書き換えたツリー）、タグを push し、GitHub Release を作成して
  `dev.sh` / `dev-up@.service` / `install.sh` / `projects.example` / `SHA256SUMS` / `RELEASE-MANIFEST.json` / `PACKAGE_ARCHIVE.tar.gz` を添付する。`SHA256SUMS` へ attestation を発行する。
- **ai-playbook**: 公開リポジトリへソースを反映し、タグを push する。Release も資産も作らない。

公開リポジトリへの release snapshot コミットは GitHub App の bot 名義になる。実行主体とコミット名義を一致させるため。

公開処理のあと、同じ実行の中で次が走る。

1. `scripts/update-release-status.sh` によるルート `README.md` の書き換え。
   **これは runner 上の作業ツリーに対する変更で、このリポジトリへはコミットされない**（手順 4 で手元から反映する）。
2. 各配布リポジトリの直近 3 リリースの一覧表示。
3. DCB と devcontainer-host のリリース資産監査（`audit_release_assets`）。手順 4 で `--audit` を別途実行する必要はない。

### 4) 事後確認

- **ルート `README.md` の RELEASE_STATUS ブロックを手元で更新してコミットする。**
  bot はこのモノレポへコミットしないため、この反映は人が行う。放置すると README の公開状況が実態とずれる。

  ```bash
  bash scripts/update-release-status.sh --owner ojos --readme README.md
  ```

- 各リポジトリでタグがリモートに見えること。
- devcontainer-host は、`dev self-update` の取得先（`https://github.com/ojos/devcontainer-host/releases/latest/download/RELEASE-MANIFEST.json`）が引けること、`checksums["dev.sh"]` と個別の資産 `dev.sh` のハッシュが一致すること、公開した `dev.sh` の `dev version` が公開した版を出すこと。DCB に同梱されていた古い `dev` の移行の案内（DCB のリリースノート・README）が出ていること。
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
  # devcontainer-host（Release + タグ）
  gh release delete <tag> --repo ojos/devcontainer-host --cleanup-tag
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
