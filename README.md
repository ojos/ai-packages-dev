# ai-packages-dev

dotfiles / DevContainer Bootstrap (DCB) / Agent Swarm Framework (ASF) の 3 パッケージを共同開発するためのモノリポジトリです。

各パッケージは独立して配布可能な設計ですが、相互補完することで AI コーディング導入のシナジーを生み出すために、開発は 1 リポジトリに集約します。

---

## パッケージ構成

```
ai-packages-dev/
├── dotfiles/                        # Layer 1: AI 共通ルール・役割定義
│   └── ai/common/
│       ├── shared-ai-rules.md       # 全エージェント共通ルール
│       ├── claude-instructions.md   # 実装担当向け指示
│       └── gemini-instructions.md   # レビュー担当向け指示
├── packages/
│   ├── devcontainer-bootstrap/      # Layer 2: Dev Container 一括生成ツール
│   │   ├── bootstrap.sh             # メインスクリプト
│   │   ├── doctor.sh                # 自己診断スクリプト
│   │   └── .github/workflows/
│   │       └── release.yml          # タグ連動リリース workflow
│   └── agent-swarm-framework/       # Layer 3: マルチエージェント実行基盤
│       ├── install.sh               # エントリポイント
│       ├── init.sh                  # プロジェクト初期化 CLI
│       ├── config.schema.json       # 設定スキーマ
│       ├── runtime-core/            # 実行基盤スクリプト
│       ├── agent-skills/            # ロール別スキル定義
│       ├── executors/               # リモート実行アダプタ
│       ├── template-project/        # プロジェクト雛形
│       ├── tests/                   # E2E テスト
│       ├── docs/                    # パッケージドキュメント
│       └── VERSION                  # バージョンファイル (現在: 0.1.0)
└── scripts/
    ├── github-account-switch.sh     # GitHub マルチアカウント切替
    └── setup-devcontainer-bootstrap-release-repo.sh  # DCB 公開リポジトリ初期化
```

---

## パッケージの役割と関係

| パッケージ | 役割 | 配布先リポジトリ |
|---|---|---|
| dotfiles | AI 開発共通ルールの Source of Truth | 専用リリースリポジトリ（未作成） |
| devcontainer-bootstrap (DCB) | Dev Container 環境を 1 コマンドで生成 | ojos/devcontainer-bootstrap |
| agent-swarm-framework (ASF) | マルチエージェント並列開発の実行基盤 | 専用リリースリポジトリ（未作成） |

**設計思想:**  
1. 新プロジェクトに DCB で Dev Container 環境を構築する  
2. ASF をインストールしてマルチエージェント運用を開始する  
3. dotfiles を参照して AI エージェント間の共通ルールを適用する

各パッケージは独立して利用できるが、3 つを組み合わせることで AI コーディング導入の初期コストを最小化できる。

---

## 開発ルール

- **ブランチ:** `main` への直 push 禁止。1 タスク 1 feature ブランチ + PR 経由で行う
- **スクリプト互換:** macOS bash 3.2+ 互換を維持する（`bash -n` で構文確認）
- **リリース:** 各パッケージは独立してタグを打ち、専用リリースリポジトリへ配布する
- **秘匿情報:** トークン・シークレットはファイルに保存しない（環境変数または CLI 認証を使う）

---

## リリースリポジトリとの関係

| パッケージ | 配布状態 |
|---|---|
| devcontainer-bootstrap | ojos/devcontainer-bootstrap で v0.1.5 まで公開済み |
| agent-swarm-framework | 専用リリースリポジトリ 未作成（次工程） |
| dotfiles | 専用リリースリポジトリ 未作成（次工程） |

リリース実行手順は各パッケージの `docs/` または `.github/workflows/` を参照する。

---

