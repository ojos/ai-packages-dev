# Package Architecture

## 目的

この package は、マルチエージェント開発基盤を別プロジェクトへ再利用可能な形で導入することを目的とする。

---

## ディレクトリ構成

```
packages/agent-swarm-framework/
├── install.sh                      # メインインストーラー（エントリポイント）
├── config.schema.json              # 設定 JSON Schema（正規パス）
├── README.md
├── docs/                           # ドキュメント
│   ├── install.md                  # インストールガイド（CLI リファレンス）
│   ├── architecture.md             # このファイル
│   ├── VISION_AUTONOMOUS_ORCHESTRATION.md
│   ├── github-actions.md
│   ├── bootstrap-issues.md
│   ├── runtime-operations.md
│   └── STATE_MANAGEMENT.md
├── runtime-core/                   # 実行基盤カテゴリ
│   ├── README.md
│   └── files/
│       └── scripts/
│           ├── gate/               # ゲート制御スクリプト
│           │   ├── auto-gate.sh
│           │   ├── command-dispatch.sh
│           │   ├── command-validate.sh
│           │   └── workflow.sh
│           ├── monitor/            # モニタリングスクリプト
│           │   ├── monitor-common.sh
│           │   ├── monitor-incident.sh
│           │   ├── monitor-line.sh
│           │   ├── monitor-merge-queue.sh
│           │   ├── monitor-overview.sh
│           │   ├── monitor-stop.sh
│           │   └── status.sh
│           └── worker/             # ワーカースクリプト
│               ├── closer-worker.sh
│               ├── delegate-line-task.sh
│               ├── line-worker.sh
│               ├── line-workers-scale.sh
│               ├── orchestrate-task.sh
│               ├── orchestrator-worker.sh
│               ├── worker-coordinator.sh
│               ├── worker-dead-letter.sh
│               ├── workers-start.sh
│               └── workers-stop.sh
├── agent-skills/                   # エージェントスキル定義カテゴリ
│   ├── README.md
│   └── files/
│       └── .multi-agent/skills/
│           ├── orchestrator.md
│           ├── planner.md
│           ├── implementer.md
│           ├── reviewer.md
│           └── closer.md
├── executors/                      # リモート実行カテゴリ
│   ├── README.md
│   └── github-actions/
│       └── files/
│           └── .github/workflows/
│               └── multi-agent-planner-implementer.yml
├── template-project/               # プロジェクトテンプレートカテゴリ
│   ├── README.md
│   ├── files/
│   │   └── .multi-agent/
│   │       ├── labels.json
│   │       └── project-overrides.example.json
│   └── github/                     # GitHub bootstrap スクリプト群
│       ├── create-bootstrap-items.sh
│       ├── create-project-board.sh
│       └── milestone-definitions.json（等）
└── .preview/                       # インストーラー生成物（git 管理対象外推奨）
    └── <projectSlug>/              # install.sh 実行時に自動生成
      ├── .agent-swarm-framework.config.json
      ├── .agent-swarm-framework.manifest.json
        └── （runtime-core / agent-skills / executors / template-project の展開物）
```

---

## 責務分離

### runtime-core

- **役割**: 対象リポジトリでマルチエージェント実行基盤を動かすための純粋シェルスクリプト群
- **配置先**: `scripts/gate/`, `scripts/monitor/`, `scripts/worker/`
- **設計方針**: 外部サービス依存を最小化し、`jq`・`gh`・`git` のみで動作する

| サブディレクトリ | 内容 |
|----------------|------|
| `gate/` | コマンド受付・バリデーション・オートゲート判定 |
| `monitor/` | ライン状況・インシデント・マージキューの監視 |
| `worker/` | LINE ワーカー・クローザーワーカー・オーケストレーター |

### agent-skills

- **役割**: 各エージェントロールの行動指針を Markdown で定義
- **配置先**: `.multi-agent/skills/`
- **ロール一覧**: `orchestrator` / `planner` / `implementer` / `reviewer` / `closer`

### executors

- **役割**: リモート実行環境（GitHub Actions 等）向けのワークフロー定義
- **配置条件**: `remoteProvider` が `github-actions` または `both` の場合のみ適用される
- **拡張方針**: 将来 `aws` executor を追加可能な構造を維持する

### template-project

- **役割**: プロジェクト初期化に必要な設定ファイル・GitHub bootstrap スクリプトを提供
- **含む資産**:
  - `labels.json`: GitHub ラベル定義
  - `project-overrides.example.json`: プロジェクト設定オーバーライド例
  - `github/`: milestone / issue / プロジェクトボード作成スクリプト

---

## インストールフロー

```
install.sh 実行
    │
    ├─ 設定収集（インタラクティブ or --config）
    ├─ バリデーション（config.schema.json）
    ├─ プレビュー生成（.preview/<projectSlug>/）
    │
    ├─ カテゴリ確認ループ
    │   ├─ runtime-core     → [y/N] → --target-dir に適用
    │   ├─ agent-skills     → [y/N] → --target-dir に適用
    │   ├─ executors        → [y/N] → --target-dir に適用（条件付き）
    │   └─ template-project → [y/N] → --target-dir に適用
    │
    └─ GitHub bootstrap（--skip-github がなければ）
        └─ template-project/github/create-bootstrap-items.sh
```

---

## モード設計

| 設定 | 説明 | 既定値 |
|------|------|--------|
| `executionMode` | エージェントの実行場所 | `hybrid` |
| `orchestratorMode` | オーケストレーターの実行場所 | `remote` |
| `automationStage` | 自動化の終端フェーズ | `implement` |
| `mergePolicy` | マージ判断ポリシー | `manual` |

- **hybrid** は「ローカルとリモートを組み合わせる」ことを示す
- オーケストレーターは理想形として `remote` を既定とし、スケールアウトを想定する

---

## 設計確定事項（2026-04-10）

この節は、運用方針の再確認セッションで確定した設計意思決定を記録する。

| ID | 決定内容 | 方針 |
|---|---|---|
| Q1 | AIエンジン割り当て | 固定ではなく設定可能（role->engine） |
| Q2 | 割り当て粒度 | role単位を基本とし、task種別で上書き可能 |
| Q3 | 実行インターフェース | API直接ではなく CLI 呼び出しを正とする |
| Q4 | remote実行基盤 | self-hosted runner を正とする |
| Q5 | タスク取得モデル | 目標は mesh（各ラインの自律 pull） |
| Q6 | 並列ライン戦略 | dynamic を標準戦略とする |
| Q7 | 完了条件 | self-hosted で full loop + mesh pull 実装を必須化 |

補足:
- Q3 の採用理由は、サブスクリプション型 CLI 運用（例: MAXプラン）との整合性を最優先するため。
- Q5 は目標状態であり、現行実装は中央割り当て寄りのため移行フェーズを要する。

---

## 現在の実装ギャップ（設計との差分）

| 項目 | 現在 | 目標 |
|---|---|---|
| タスク取得 | coordinator による中央ルーティング主体 | 各ラインが backlog から自律 pull |
| remote executor | GitHub Actions は placeholder を含む | self-hosted runner で実ジョブ処理 |
| エンジン割り当て | 一部スクリプトで固定呼び出し | role/task 上書き設定による切替 |
| ライン運用 | fixed2 前提の記述が残る | dynamic 標準の運用記述へ統一 |

移行方針:
1. 設定I/O契約を先に確定（role/task override）
2. self-hosted 前提の remote 実行パスを実装
3. pull型取得を導入し、coordinator は最小限の整合制御へ縮退

---

## 状態管理

- **GitHub** を正の状態面（Issues / Projects / PR）として扱う
- **runtime files**（`orchestration/runtime/`）は補助状態として扱う
- 不整合時は GitHub 側を優先する
- `stateBackend: "hybrid"` は両方を併用することを示す

---

## 安全ポリシー

- 既定 `mergePolicy` は `manual`（最小権限）
- `conditional` は「CI 全通過 + レビュー承認」を条件としたセミオート
- `auto` は将来拡張として扱い、現時点では動作保証外

---

## スキーマ管理

設定の正規 JSON Schema は **`packages/agent-swarm-framework/config.schema.json`** とする。  
新規実装・検証・配布のすべてでこのパスのみを参照すること。

---

## 関連ドキュメント

- [install.md](./install.md) — CLI リファレンス
- [VISION_AUTONOMOUS_ORCHESTRATION.md](./VISION_AUTONOMOUS_ORCHESTRATION.md) — 自律オーケストレーション最終ビジョン
- [STATE_MANAGEMENT.md](./STATE_MANAGEMENT.md) — 状態管理詳細
- [github-actions.md](./github-actions.md) — GitHub Actions executor 詳細
