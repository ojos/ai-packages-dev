# devcontainer-bootstrap Release Notes

新世代（2026-07-17 リポジトリ再作成後）のリリースノートです。旧世代（〜v0.3.1）は [archive/release-notes-devcontainer-bootstrap.md](../archive/release-notes-devcontainer-bootstrap.md) を参照。

## v0.4.1

### Summary
- ai-playbook ソース指定の使い勝手を改善（後方互換の追加）。

### Highlights
- `--playbook-version <tag>` を追加。既定ソース `ojos/ai-playbook` のタグ tarball（`.../archive/refs/tags/<tag>.tar.gz`）へ内部展開し、長い URL を打たずに版だけで指定できる。`--playbook-from` とは相互排他。
- ソース（`--playbook-from` / `--playbook-version`）を指定した場合、`--with-playbook` を省略しても規範を配置する。判定順は「明示 opt-out（`--without-playbook`）> 明示 opt-in（`--with-playbook`）> ソース指定あり」。

### Breaking Changes
- なし。`--playbook-from` 単体は従来「無視」だったが「配置」になる（silent no-op の解消）。`--without-playbook` は最優先で従来どおり配置しない。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.4.0

### Summary
- `--mode <minimal|standard|full>` を廃止し、装備を `--with-*` フラグへ分解した**破壊的変更**。

### Highlights
- `--mode` 廃止（未知オプションとしてエラー）。3 mode 別テンプレを 1 つのパラメータ化テンプレへ集約し重複を解消。
- docker のリッチさ（buildx + compose-switch）を全生成物で標準化。
- cloud: `--with-aws` / `--with-gcp` を追加。Terraform はいずれかの cloud 指定時に暗黙同梱（両指定でも 1 回、cloud 無指定なら無し）。
- AI ツール: `--with-claude` / `--with-gemini` / `--with-copilot` を追加。トークンによる自動導入を廃止し明示 opt-in のみ。各フラグは CLI + VS Code 拡張 + 設定の永続化（compose named volume）を同型で実施。
- AI 認証の永続化を mode 非依存化（旧 full 限定を撤廃）。
- `doctor.sh` に cloud CLI（aws/gcloud/terraform）可用性検査を追加。

### Breaking Changes
- **`--mode` を削除**。旧 `--mode standard` は概ね `--with-aws`、旧 `--mode full` は `--with-aws --with-gcp --with-claude --with-gemini --with-copilot` に相当。移行対応表は DCB README「mode オプションからの移行」を参照。
- AI CLI（claude/gemini）の**トークンによる自動導入を廃止**。今後は `--with-<ai>` の明示指定が必要。
- docker のリッチさが全生成物で標準になったため、旧 `minimal` 相当でも buildx 等が入る。

### 予定（未実装）
- `--with-codex`（OpenAI Codex）/ `--with-sakura`（さくらのクラウド）/ `--with-cloudflare`（Cloudflare）は拡張点の枠のみ。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.3.1

### Summary
- ループコーディング支援の実行体を生成に追加。全モードで生成し、外部パッケージの導入を前提にせず単体で動作する。

### Highlights
- 生成物に `scripts/verify.sh`（受け入れ条件を非対話実行し一意な通過信号 `VERIFY_PASS` を返す接地信号）、`scripts/acceptance.sh`（プロジェクト所有の受け入れ条件。選択言語の慣習的テストコマンドを既定配置）、`scripts/loop-gate.sh`（push / PR 前のローカル事前ゲート。`verify.sh` と任意の第二意見レビューを直列化）を追加。
- `doctor.sh` がループスクリプト 3 種の存在・構文・実行権限を検査。
- README に「ループコーディング支援」節を追加。ワークフローの正本は ai-playbook の `loop-workflow.md` / 解説は `loop-coding-guide.md` を参照。`--with-playbook` の取得元を ai-playbook `v0.1.1` へ更新。

### Breaking Changes
- なし（後方互換の機能追加）。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.1.0

### Summary
- 配布リポジトリをクリーンな履歴で再作成した、新世代の初回リリース。

### Highlights
- 機能は旧世代最終版（v0.3.1）の内容をすべて含む: `--with-playbook --playbook-from <ai-playbook タグ tarball>`、`.ai-playbook/` 配置、GitHub archive 形式の構造検出、`.env` 自動読み込み、アカウント自動選択フォールバック。
- 履歴・タグ・Release を新規に作成。コミット作者情報は `Ido <ido@ojos.jp>` に統一。

### Breaking Changes
- 旧世代のタグ（v0.1.15〜v0.3.1）と Release の固定 URL は無効。取得手順の `TAG` を `v0.1.0` へ更新する。

### Verification
- [x] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [x] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）
- [x] コミット作者・コントリビューターが単一 identity であることを確認
