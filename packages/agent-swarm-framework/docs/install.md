# Install Guide

`packages/agent-swarm-framework/install.sh` は、マルチエージェント開発パッケージを対象リポジトリに適用するメインスクリプトです。

English:
`packages/agent-swarm-framework/install.sh` is the main entrypoint to apply the multi-agent package into a target repository.

---

## At A Glance (English)

1. Collect config from interactive wizard or `--config` JSON.
2. Validate config with `config.schema.json`.
3. Generate preview in `.preview/<projectSlug>/`.
4. Review per-category add/overwrite files.
5. Apply selected categories into `--target-dir`.
6. Optionally create GitHub milestones/issues (or skip with `--skip-github`).

---

## 動作概要

1. **設定収集** — インタラクティブウィザード、または `--config` で指定した JSON ファイルから設定を読み込む
2. **バリデーション** — `config.schema.json` に基づいて設定値を検証する
3. **プレビュー生成** — `.preview/<projectSlug>/` にカテゴリ別ファイルを展開する
4. **カテゴリ確認** — 各カテゴリの追加・上書きファイル一覧を表示する
5. **適用確認** — カテゴリごとに対話確認して `--target-dir` へコピーする
6. **GitHub 初期化** — milestone / issue を対象リポジトリに作成する（スキップ可）

---

## 既存プロジェクトへの途中導入（Retrofit）

ASF は新規プロジェクト専用ではない。既存プロジェクトへ段階導入できる。

### 基本方針

1. いきなり全自動へ切り替えない。
2. `automationStage` と `mergePolicy` を使って段階的に解放する。
3. 初回は `--skip-github` で外部副作用を切り離す。

### 推奨導入ステップ

Step 1: 監査導入（副作用なし）

```bash
bash packages/agent-swarm-framework/install.sh \
  --retrofit-safe \
  --non-interactive \
  --config retrofit.json \
  --target-dir /path/to/project
```

`retrofit.json` の推奨初期値:
- `automationStage: "plan"`
- `mergePolicy: "manual"`
- `executionMode: "local"`

補足:
- `--retrofit-safe` は安全プリセットを強制適用する。
  - `executionMode=local`
  - `remoteProvider=none`
  - `automationStage=plan`
  - `mergePolicy=manual`
  - `orchestratorMode=local`
  - `--skip-github` 自動有効化
- カテゴリ適用の既定値も安全側に切り替える。
  - `runtime-core` / `agent-skills`: 適用
  - `executors` / `template-project`: スキップ
  - `--non-interactive` 時は上記既定値で自動適用される
- サンプルは `packages/agent-swarm-framework/retrofit-config.sample.json` を参照。

Step 2: 実装自動化へ拡張
- `automationStage` を `implement` へ変更
- CI とローカル検証が安定していることを確認

Step 3: レビュー/マージ自動化へ拡張
- `automationStage` を `review` -> `merge` の順で段階的に拡張
- `mergePolicy` は `manual` -> `conditional` -> `auto` の順で解放

### 途中導入での非破壊ルール

1. 既存運用を壊さないため、カテゴリ適用は段階的に行う。
- 先に `runtime-core` と `agent-skills`
- 次に `template-project`
- 最後に `executors`

2. 既存設定との競合は Layer 4 で解決する。
- 優先順位: Layer 4 > Layer 3 > Layer 1

3. ロールバック手段を先に作る。
- 適用前に `git status` がクリーンであること
- 適用単位を小さく保ち、1回の適用を1コミットに分割

### 途中導入が難しくなる典型パターン

| 症状 | 原因 | 回避策 |
|---|---|---|
| 既存指示とASFスキルが競合 | Layer 4上書き未定義 | Layer 4にengine routing宣言を追加 |
| 既存CIとexecutorが衝突 | 一括適用 | `executors` は最後に適用 |
| 人間承認フローと自動化が混線 | stageを一気に解放 | `plan` -> `implement` -> `review` -> `merge` で段階移行 |

### Retrofit クイックチェックリスト

- [ ] `git status` がクリーン
- [ ] 初回は `--retrofit-safe` を使う
- [ ] 初回適用は `runtime-core` / `agent-skills` のみ
- [ ] 反映後に `workflow.sh status` で状態確認
- [ ] 問題なければ `automationStage` を `implement` へ引き上げ

---

## 現在の受入済みベースライン（2026-04-10）

- `bash packages/agent-swarm-framework/install.sh --help` は正常終了する
- `bash packages/agent-swarm-framework/tests/e2e-init.sh` は `main` 上で PASS する
- package CI は `e2e-init` を自動実行し、install/init の回帰を検知する
- 生成メタデータは次の 2 ファイルに統一済み
  - `.agent-swarm-framework.config.json`
  - `.agent-swarm-framework.manifest.json`

---

## 前提条件

| ツール | 用途 |
|--------|------|
| `bash` 3.2 以上 | スクリプト実行環境（macOS 標準 bash 3.2 で動作） |
| `jq` | JSON 処理（設定バリデーション・マニフェスト生成） |
| `git` | 対象リポジトリ判定 |
| `gh` CLI | GitHub milestone/issue 作成（`--skip-github` 時は不要） |

---

## 使い方

```bash
bash packages/agent-swarm-framework/install.sh [options]
```

### standalone 実行（install.sh 単体ダウンロード）

```bash
curl -fsSL https://raw.githubusercontent.com/ojos/agent-swarm-framework/main/install.sh \
  -o install.sh

bash install.sh \
  --non-interactive \
  --config my-config.json \
  --target-dir /path/to/my-project \
  --skip-github
```

補足:
- install.sh 単体で実行された場合、同梱 package レイアウトが見つからなければ archive を取得して再実行する。
- 取得元 URL は `--bootstrap-from <url>` または環境変数 `AGENT_SWARM_FRAMEWORK_ARCHIVE_URL` で指定できる。
- 未指定時は main ブランチ archive を使用する。

### オプション一覧

| オプション | 引数 | デフォルト | 説明 |
|-----------|------|-----------|------|
| `--target-dir` | `<path>` | カレントディレクトリ | 適用先リポジトリのパス |
| `--preview-dir` | `<path>` | `.preview/<projectSlug>/` | プレビュー出力先ディレクトリ |
| `--config` | `<json-file>` | なし | 設定 JSON ファイルのパス |
| `--bootstrap-from` | `<url>` | main ブランチ archive URL | standalone 実行時の package 取得元 |
| `--retrofit-safe` | — | false | 既存プロジェクト向け安全プリセットを適用 |
| `--non-interactive` | — | false | 非インタラクティブモード（`--config` と併用必須） |
| `--skip-github` | — | false | GitHub milestone/issue 作成をスキップ |
| `-h` / `--help` | — | — | ヘルプを表示して終了 |

---

## インタラクティブモード

オプションなしで実行するとウィザード形式で設定を収集します。

```bash
cd /path/to/my-project
bash packages/agent-swarm-framework/install.sh
```

| 設問 | 選択肢 | デフォルト |
|------|-------|-----------|
| Display name | 任意の文字列 | `My Multi-Agent Project` |
| Project slug | `[a-z0-9-]+` | Display name から自動生成 |
| Execution mode | `local` / `remote` / `hybrid` | `hybrid` |
| Remote provider | `github-actions`（execution mode が remote/hybrid 時のみ） | `github-actions` |
| Automation stage | `plan` / `implement` / `review` / `merge` | `implement` |
| Merge policy | `manual` / `conditional` / `auto` | `manual` |
| Line strategy | `fixed2` / `dynamic` | `fixed2` |
| Orchestrator mode | `local` / `remote` / `hybrid` | `remote` |
| State backend | `github` / `file` / `hybrid` | `hybrid` |

---

## 非インタラクティブモード

CI や自動化スクリプトから使用する場合は `--non-interactive --config <file>` を指定します。

### 設定ファイル例（通常導入）

```json
{
  "version": "1.0",
  "displayName": "My Multi-Agent Project",
  "projectSlug": "my-project",
  "executionMode": "hybrid",
  "remoteProvider": "github-actions",
  "automationStage": "implement",
  "mergePolicy": "conditional",
  "lineStrategy": "fixed2",
  "orchestratorMode": "remote",
  "stateBackend": "hybrid",
  "agentEngines": {
    "roles": {
      "orchestrator": "copilot",
      "planner": "copilot",
      "implementer": "claude",
      "reviewer": "gemini",
      "closer": "copilot"
    }
  },
  "taskEngineOverrides": {
    "frontend_state_finalize": {
      "implementer": "codex",
      "reviewer": "gemini"
    }
  }
}
```

### 設定ファイル例（Retrofit 導入）

`packages/agent-swarm-framework/retrofit-config.sample.json` をベースに使う。

推奨実行:

```bash
bash packages/agent-swarm-framework/install.sh \
  --retrofit-safe \
  --non-interactive \
  --config packages/agent-swarm-framework/retrofit-config.sample.json \
  --target-dir /path/to/project
```

### 実行例

```bash
# 非インタラクティブ実行（GitHub bootstrap スキップ）
bash packages/agent-swarm-framework/install.sh \
  --non-interactive \
  --config my-config.json \
  --target-dir /path/to/my-project \
  --skip-github

# 設定ファイル指定 + GitHub bootstrap 付き適用
bash packages/agent-swarm-framework/install.sh \
  --config my-config.json \
  --target-dir ./output

# self-hosted 実行前の前提チェック
bash packages/agent-swarm-framework/tests/self-hosted-preflight.sh \
  --repo-root ./output \
  --config ./output/.agent-swarm-framework.config.json
```

---

## 設定フィールド仕様

設定の正規スキーマ: `packages/agent-swarm-framework/config.schema.json`

| フィールド | 型 | 必須 | 許容値 | 説明 |
|-----------|-----|------|--------|------|
| `version` | string | ✓ | `"1.0"` | スキーマバージョン |
| `displayName` | string | ✓ | 任意 | プロジェクト表示名 |
| `projectSlug` | string | ✓ | `[a-z0-9-]+` | プロジェクト識別子（ディレクトリ名に使用） |
| `executionMode` | string | ✓ | `local` / `remote` / `hybrid` | エージェントの実行場所 |
| `remoteProvider` | string | ✓ | `none` / `github-actions` / `aws` / `both` | リモート実行プロバイダー |
| `automationStage` | string | ✓ | `plan` / `implement` / `review` / `merge` | 自動化の終端フェーズ |
| `mergePolicy` | string | ✓ | `manual` / `conditional` / `auto` | マージ判断ポリシー |
| `lineStrategy` | string | ✓ | `fixed2` / `dynamic` | 実装ライン数の戦略 |
| `orchestratorMode` | string | ✓ | `local` / `remote` / `hybrid` | オーケストレーターの実行場所 |
| `stateBackend` | string | ✓ | `github` / `file` / `hybrid` | 状態管理バックエンド |
| `agentEngines.roles` | object | 任意 | `copilot` / `claude` / `gemini` / `codex` | ロールごとの既定エンジン割り当て |
| `taskEngineOverrides` | object | 任意 | task kind -> role別 engine | task種別ごとのエンジン上書き |

補足:
- `agentEngines` 未指定時は `orchestrator/planner/closer=copilot`, `implementer=claude`, `reviewer=gemini` が既定値になる。
- `taskEngineOverrides.<taskKind>.<role>` が設定されている場合は、role 既定より優先される。
- `implementer` / `reviewer` は CLI 実行ロールのため、`copilot` は指定不可（`claude` / `gemini` / `codex` のみ）。

---

## 出力ファイル

`--preview-dir`（デフォルト: `.preview/<projectSlug>/`）に以下が生成されます。

| ファイル | 説明 |
|---------|------|
| `.agent-swarm-framework.config.json` | 適用した設定の記録 |
| `.agent-swarm-framework.manifest.json` | 生成日時 + 設定のマニフェスト |
| `.multi-agent/skills/*.md` | エージェントスキル定義（7 ロール） |
| `.multi-agent/labels.json` | GitHub ラベル定義 |
| `.multi-agent/project-overrides.example.json` | プロジェクト設定オーバーライド例 |
| `scripts/gate/*.sh` | ゲート制御スクリプト |
| `scripts/monitor/*.sh` | モニタリングスクリプト |
| `scripts/worker/*.sh` | ワーカースクリプト |
| `.github/workflows/*.yml` | GitHub Actions ワークフロー（`remoteProvider` が `github-actions` or `both` の場合のみ） |

---

## よくある失敗と対策

| 症状 | 原因 | 対策 |
|------|------|------|
| `error: required command not found: jq` | jq 未インストール | `apt install jq` または `brew install jq` |
| `gh: command not found`（GitHub bootstrap 時） | gh CLI 未インストール | GitHub CLI をインストールして `gh auth login` |
| `error: --non-interactive requires --config` | `--non-interactive` 単独指定 | `--config <file>` を必ず併用する |
| `error: config file not found` | ファイルパスが間違い | 絶対パスまたは正しい相対パスを指定 |
| 既存ファイルが上書きされた | プレビュー確認をスキップ | プレビューの「上書き予定」欄を必ず確認する |

---

## 終了コード

| コード | 意味 |
|--------|------|
| `0` | 正常終了 |
| `1` | エラー（不正なオプション、バリデーション失敗、必須コマンド不在 など） |

---

## 関連ドキュメント

- [architecture.md](./architecture.md) — ディレクトリ構成と設計方針
- [VISION_AUTONOMOUS_ORCHESTRATION.md](./VISION_AUTONOMOUS_ORCHESTRATION.md) — 自律オーケストレーションの最終ビジョン
- `config.schema.json` — 設定 JSON Schema（正規パス）
