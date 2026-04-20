# Agent Swarm Framework

複数エージェントによる開発運用を、新規プロジェクトへ導入するための初期パッケージです。

## パッケージ構成

```
packages/agent-swarm-framework/
├── install.sh              # エントリポイント（インタラクティブ / 非インタラクティブ対応）
├── config.schema.json      # 設定 JSON Schema（正規パス）
├── README.md               # このファイル
├── runtime-core/           # 実行基盤（workflow / command / monitor / worker）
├── agent-skills/           # ロール別の基本 skill（7 ロール）
├── executors/              # リモート実行アダプタ（github-actions）
├── template-project/       # 設定・Issue・milestone 雛形
└── docs/                   # ドキュメント
    ├── install.md          # CLI リファレンス
    ├── architecture.md     # ディレクトリ構成・設計方針
    └── VISION_AUTONOMOUS_ORCHESTRATION.md
```

## 使い方

```bash
# インタラクティブ（ウィザード形式）
bash packages/agent-swarm-framework/install.sh

# 非インタラクティブ（CI 等）
bash packages/agent-swarm-framework/install.sh \
  --non-interactive \
  --config my-config.json \
  --target-dir /path/to/project

# standalone（install.sh 単体ダウンロード実行）
curl -fsSL https://raw.githubusercontent.com/ojos/agent-swarm-framework/main/install.sh \
  -o install.sh && \
bash install.sh --non-interactive --config my-config.json --target-dir /path/to/project --skip-github
```

導入フロー:

1. ウィザードまたは設定ファイルで設定を入力
2. `.preview/<projectSlug>/` にプレビューを生成
3. `runtime-core` / `agent-skills` / `executors` / `template-project` をカテゴリ単位で確認
4. 確認後に target repository へ反映
5. 確認付きで milestone / bootstrap issue を GitHub に起票

## Runtime CLI

統一エントリポイントとして次を利用できます:

```bash
bash scripts/asf doctor
bash scripts/asf preflight
bash scripts/asf status
bash scripts/asf up --interval 15
bash scripts/asf down
```

doctor モードでは、必須ファイル/スクリプト、コマンド可用性、`gh auth`、hook path の健全性を確認します。

既存プロジェクトへの途中導入（Retrofit）:
- ASF は新規リポジトリだけでなく既存リポジトリへ段階導入できる。
- まず `--retrofit-safe` + `automationStage=plan` で監査導入し、次に `implement/review/merge` を順次解放する。
- `--retrofit-safe` は `executionMode=local`, `remoteProvider=none`, `mergePolicy=manual`, `orchestratorMode=local` を強制し、`--skip-github` も自動有効化する。
- `--retrofit-safe` のカテゴリ既定は `runtime-core/agent-skills` を適用、`executors/template-project` をスキップとする。
- サンプル設定は `retrofit-config.sample.json` を参照。
- 詳細手順は [docs/install.md](docs/install.md) の「既存プロジェクトへの途中導入（Retrofit）」を参照。

standalone 実行時（install.sh 単体）の動作:
- 同梱ディレクトリ（`runtime-core` など）が見つからない場合、install.sh は package アーカイブを自動取得して再実行する。
- 取得元はデフォルトで main ブランチのアーカイブ。必要に応じて `--bootstrap-from <url>` で上書き可能。

詳細は [docs/install.md](docs/install.md) を参照してください。

## 既定方針

| 設定 | 既定値 |
|------|--------|
| execution mode | `hybrid` |
| remote provider | `github-actions` |
| automation stage | `implement` |
| merge policy | `manual` |
| line strategy | `fixed2` |
| orchestrator mode | `remote` |
| state backend | `hybrid` |

## バージョン方針

| 項目 | 方針 |
|------|------|
| スキーマバージョン | `config.schema.json` の `version` フィールド（現在: `"1.0"`） |
| 後方互換性 | メジャーバージョン間（例: 1.x → 2.x）は互換保証なし |
| 変更管理 | スキーマ変更時は `version` を更新し、`install.sh` のバリデーションも更新する |
| 正規パス | `packages/agent-swarm-framework/config.schema.json` |
| リリース単位 | このディレクトリ全体を `git archive` または `tar.gz` で配布する |

## dotfiles との責務境界

ASF はワークフロー固有の協調挙動を担います。
dotfiles は共有の環境設定と言語レベルの AI ルールを担います。

- ASF の責務: 委譲パターン、conversation-gate reason code、実行時協調スクリプト、ロール間ワークフロー挙動
- dotfiles の責務: 共通記述/開発ルール、共通指示スタイル、再利用可能な shell/editor 環境規約

ASF は単体利用も可能ですが、dotfiles を併用する場合は、dotfiles を基盤ポリシー、ASF をワークフローレイヤーとして扱います。

## 詳細ドキュメント

- [docs/install.md](docs/install.md) — CLI リファレンス・設定フィールド仕様
- [docs/architecture.md](docs/architecture.md) — ディレクトリ構成・設計方針
- [docs/VISION_AUTONOMOUS_ORCHESTRATION.md](docs/VISION_AUTONOMOUS_ORCHESTRATION.md) — 自律オーケストレーションビジョン
- [docs/github-actions.md](docs/github-actions.md) — GitHub Actions executor 詳細
- [docs/runtime-operations.md](docs/runtime-operations.md) — リリース手順・更新運用・互換性ルール
- [docs/STATE_MANAGEMENT.md](docs/STATE_MANAGEMENT.md) — 状態管理詳細

---

## FAQ・トラブルシュート

| 症状 | 対策 |
|------|------|
| `gh: command not found` | GitHub CLI をインストールして `gh auth login` |
| `jq: command not found` | `apt install jq` または `brew install jq` |
| `error: --non-interactive requires --config` | `--config <file>` を必ず併用する |
| ファイルが意図せず上書きされる | プレビューの「上書き予定」欄を必ず確認する |
| milestone/issue が反映されない | `--skip-github` 有無と `gh auth status` を確認する |
- [docs/PACKAGE_DISTRIBUTION.md](docs/PACKAGE_DISTRIBUTION.md) — 配布構成・責務境界・版管理ルール

## Shell テスト

簡易シェルテスト実行:

```bash
bash packages/agent-swarm-framework/tests/run-shell-tests.sh
```

E2E も含める場合:

```bash
RUN_E2E_TESTS=true bash packages/agent-swarm-framework/tests/run-shell-tests.sh
```
