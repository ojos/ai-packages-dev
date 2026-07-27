# scripts カタログ

このファイルは `scripts/` 配下の運用対象スクリプト一覧と用途を示す索引です。

## 収録ルール

- `scripts/` 配下の運用対象ファイルを列挙する。
- ファイル追加・削除・改名時は、このファイルを同一コミットで更新する。

## ファイル一覧（運用対象）

| ファイル | 概要 |
|---|---|
| `scripts/gemini-review.sh` | 別ベンダーのモデルによる第二意見（クロスモデル二段ゲートの2段目）。 |
| `scripts/fix-mount-owner.sh` | 永続 volume のマウント先を remoteUser 所有へ戻す（postCreate の先頭）。 |
| `scripts/install-ai-tools.sh` | AI CLI ツール導入。 |
| `scripts/load-project-env.sh` | プロジェクト .env を source せず安全にパースして export（ホスト env を後勝ちで上書き）。 |
| `scripts/on-attach.sh` | attach 時の初期化処理。 |
| `scripts/post-rebuild-check.sh` | リビルド後チェック。 |
| `scripts/release-packages.sh` | ai-playbook / DCB のリリース実行と監査。 |
| `scripts/setup-git-identity.sh` | global identity の無害化と local identity 適用、credential.helper の gh 固定。 |
| `scripts/verify-commit-identity.sh` | コミット履歴の identity 検証（email のみで判定）。CI（identity-guard）と手元で共用。 |
| `scripts/setup-ai-directory-policy.sh` | AI 用ディレクトリ方針ウィザード。 |
| `scripts/setup-devcontainer-bootstrap-release-repo.sh` | DCB リリースリポジトリ準備。 |
| `scripts/update-release-status.sh` | README のリリース状況更新。 |
| `scripts/CATALOG.md` | `scripts/` 配下の索引（本ファイル）。 |
