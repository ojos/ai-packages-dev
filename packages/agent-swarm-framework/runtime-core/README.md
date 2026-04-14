# runtime-core

再利用可能な runtime 実行基盤を保持するカテゴリです。

## 含まれるもの
- **gate scripts**: ゲート管理・自動化（例: auto-gate.sh）
- **monitor scripts**: ライン・インシデント・マージキュー等の監視（例: monitor-overview.sh, monitor-line.sh）
- **worker scripts**: タスク実行・ワーカー管理（例: orchestrate-task.sh, workers-start.sh）

`files/` 配下は導入先 repository のルートへ展開される前提で構成しています。

---

## 代表的なスクリプトと運用例

### gate scripts
- `auto-gate.sh` : Reviewer未応答やgate停滞を自動検知し、必要に応じてissueへコメント。CIや定期実行に適用可能。
	- 例: `./scripts/gate/auto-gate.sh --dry-run --once`
	- 環境変数: `MONITOR_REPO`, `AUTO_GATE_REVIEWER_STALL_MINUTES`, `AUTO_GATE_IMPL_STALL_MINUTES`

### monitor scripts
- `monitor-overview.sh` : 全ラインのgate/owner/risk等を一覧表示。ダッシュボード用途。
	- 例: `./scripts/monitor/monitor-overview.sh --interval 120`
- `monitor-line.sh` : 指定ラインの詳細監視。
	- 例: `./scripts/monitor/monitor-line.sh --line auto-001 --interval 60`

### worker scripts
- `orchestrate-task.sh` : 指定planファイルまたはissue番号からワークフローを自動実行。
	- 例: `./scripts/worker/orchestrate-task.sh --issue 1234`
- `workers-start.sh` / `workers-stop.sh` : ワーカー群の一括起動・停止
	- 例: `./scripts/worker/workers-start.sh`

---

## 導入・運用のポイント
- 各スクリプトはCI/CDやcron等での自動化運用を想定
- 必要に応じて環境変数やオプションで挙動を調整
- 詳細は各スクリプト先頭のコメント・ヘルプ参照
