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
| `scripts/post-rebuild-check.sh` | リビルド後チェック。**手動実行専用**（`postCreateCommand` / `postAttachCommand` からは起動しない）。 |
| `scripts/release-packages.sh` | ai-playbook / DCB のリリース実行と監査（`--audit` は公開資産を再取得し SHA256 を再計算して整合性を検証する）。 |
| `scripts/audit-failure-notify.sh` | リリース資産監査の失敗通知。2 回連続の失敗でのみ issue を起票し、同じ失敗の open issue があればコメント追記に留める。 |
| `scripts/setup-git-identity.sh` | global identity の無害化と local identity 適用、credential.helper の gh 固定。 |
| `scripts/acceptance.sh` | このプロジェクトの受け入れ条件（`ci.yml` 5 ジョブ + `identity-guard.yml` の完全ミラー）。プロジェクトが所有・編集する。 |
| `scripts/check-neutrality.sh` | `packages/` と `.ai-playbook/` への固有名詞混入検査。検査対象・除外条件の正本で、CI・`acceptance.sh`・`PROJECT_DEFINITION.md` が共用する。 |
| `scripts/verify.sh` | `acceptance.sh` を非対話実行し、一意な通過信号（`VERIFY_PASS`）を返す接地信号。 |
| `scripts/loop-gate.sh` | push / PR 前のローカル事前ゲート。`verify.sh` と第二意見を直列化する単一入口（`GATE_PASS`）。 |
| `scripts/verify-commit-identity.sh` | コミット履歴の identity 検証（email のみで判定）。CI（identity-guard）と手元で共用。 |
| `scripts/update-release-status.sh` | README のリリース状況更新。 |
| `scripts/CATALOG.md` | `scripts/` 配下の索引（本ファイル）。 |
