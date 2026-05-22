# scripts カタログ

このファイルは `scripts/` 配下の運用対象スクリプト一覧と用途を示す索引です。

## 収録ルール

- `scripts/` 配下の運用対象ファイルを列挙する。
- 可変ログ領域は除外する（`scripts/orchestration/runtime/**`, `scripts/orchestration/command-history/**`）。
- ファイル追加・削除・改名時は、このファイルを同一コミットで更新する。

## ファイル一覧（運用対象）

| ファイル | 概要 |
|---|---|
| `scripts/asf` | ASF 統一 CLI エントリポイント。 |
| `scripts/asf-workflow.sh` | ASF ワークフロー実行ヘルパー。 |
| `scripts/gate/asf-doctor.sh` | ASF 依存と前提条件の健全性チェック。 |
| `scripts/gate/asf-enforcement-check.sh` | ASF 運用ルールの強制チェック。 |
| `scripts/gate/auto-gate.sh` | 自動ゲート判定実行。 |
| `scripts/gate/command-dispatch.sh` | コマンドのルーティングとディスパッチ。 |
| `scripts/gate/command-validate.sh` | 受信コマンドのバリデーション。 |
| `scripts/gate/conversation-entry.sh` | 会話入力から intake 変換を実行。 |
| `scripts/gate/conversation-gate.sh` | 会話ゲート判定。 |
| `scripts/gate/install-git-hooks.sh` | Git hooks の導入スクリプト。 |
| `scripts/gate/workflow.sh` | ゲート経由の標準ワークフロー。 |
| `scripts/github-account-switch.sh` | GitHub アカウント/プロファイル切替。 |
| `scripts/install-ai-tools.sh` | AI CLI ツール導入。 |
| `scripts/load-env.sh` | 環境変数ロード。 |
| `scripts/monitor/dashboard.sh` | 監視ダッシュボード起動。 |
| `scripts/monitor/monitor-common.sh` | monitor 共通関数。 |
| `scripts/monitor/monitor-incident.sh` | インシデント監視。 |
| `scripts/monitor/monitor-line.sh` | ライン別監視。 |
| `scripts/monitor/monitor-merge-queue.sh` | マージキュー監視。 |
| `scripts/monitor/monitor-overview.sh` | 全体監視ビュー。 |
| `scripts/monitor/monitor-stop.sh` | 監視停止。 |
| `scripts/monitor/status.sh` | 監視状態表示。 |
| `scripts/on-attach.sh` | attach 時の初期化処理。 |
| `scripts/post-rebuild-check.sh` | リビルド後チェック。 |
| `scripts/release-packages.sh` | 3パッケージのリリース実行。 |
| `scripts/release/preflight-check.sh` | リリース前の事前検証。 |
| `scripts/setup-ai-directory-policy.sh` | AI 用ディレクトリ方針ウィザード。 |
| `scripts/setup-devcontainer-bootstrap-release-repo.sh` | DCB リリースリポジトリ準備。 |
| `scripts/update-release-status.sh` | README のリリース状況更新。 |
| `scripts/worker/auto-enqueue-issues.sh` | Issue の自動 enqueue 判定。 |
| `scripts/worker/auto-enqueue-worker.sh` | 自動 enqueue ワーカー。 |
| `scripts/worker/close-issue-with-policy.sh` | 方針に沿った Issue クローズ。 |
| `scripts/worker/closer-worker.sh` | closer ロール実行。 |
| `scripts/worker/delegate-issue-implementation.sh` | 実装 Issue の line task 化。 |
| `scripts/worker/delegate-line-task.sh` | ラインタスク委譲。 |
| `scripts/worker/line-worker.sh` | line worker 実行。 |
| `scripts/worker/line-workers-scale.sh` | line worker スケール調整。 |
| `scripts/worker/orchestrate-task.sh` | タスク分解・振り分けのオーケストレーション。 |
| `scripts/worker/orchestrator-worker.sh` | orchestrator worker 実行。 |
| `scripts/worker/worker-coordinator.sh` | ワーカー協調制御。 |
| `scripts/worker/worker-dead-letter.sh` | dead-letter 処理。 |
| `scripts/worker/workers-start.sh` | ワーカー群起動。 |
| `scripts/worker/workers-stop.sh` | ワーカー群停止。 |
| `scripts/CATALOG.md` | `scripts/` 配下の索引（本ファイル）。 |
