# devcontainer-bootstrap Release Notes

新世代（2026-07-17 リポジトリ再作成後）のリリースノートです。旧世代（〜v0.3.1）は [archive/release-notes-devcontainer-bootstrap.md](../archive/release-notes-devcontainer-bootstrap.md) を参照。

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
