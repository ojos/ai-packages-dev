# agent-definitions

ロール契約とタスクプレイブックを保持するカテゴリです。

## 構成

- `.multi-agent/role-contracts/*.md`: ロール別の振る舞い契約（role contract）
- `.multi-agent/task-playbooks/*.md`: タスク単位の再利用手順（task playbook）

## ロール契約（7 ロール）
- orchestrator
- planner
- implementer
- reviewer
- closer
- intake-manager
- consult-facilitator

## タスクプレイブック（初期セット）
- issue-triage
- plan-breakdown
- pr-review
- issue-close-policy
- web-modernization-modern-web-guidance

---

## カスタマイズ・拡張方法
- 各 Markdown ファイルは導入先プロジェクトで自由に編集・追加可能
- ロール契約は「いつ何を判断するか」を定義し、タスクプレイブックは「どう実行するか」を定義する
- 例: reviewer.mdに「レビュー観点テンプレート」や「自動チェックリスト」を追加

## ロール契約テンプレート（推奨）
- 各ロール契約は次の必須セクションを持つ: `目的` / `入力` / `出力` / `禁止事項` / `エスカレーション条件` / `完了定義`
- 実装手順や具体コマンドは、必要に応じて `実用プロンプト例` として補足する

## 活用例
- 導入先で独自のskillセットを作成し、AIエージェントや人間レビュワーの指針として活用
- プロジェクト固有のルールやワークフローをskillに反映し、運用の一貫性を担保
