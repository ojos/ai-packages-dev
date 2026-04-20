# ai-packages-dev

dotfiles / DevContainer Bootstrap (DCB) / Agent Swarm Framework (ASF) の 3 パッケージを共同開発するためのモノリポジトリです。

各パッケージは独立して配布可能な設計ですが、相互補完することで AI コーディング導入のシナジーを生み出すために、開発は 1 リポジトリに集約します。

## English Summary

This repository is a monorepo for collaborative development of three packages:
dotfiles, DevContainer Bootstrap (DCB), and Agent Swarm Framework (ASF).

Each package is distributable on its own, but they are developed together to reduce AI coding onboarding cost through combined usage.

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

### Package Layout (English)

- `dotfiles/`: shared AI rules and role definitions
- `packages/devcontainer-bootstrap/`: one-command Dev Container generator
- `packages/agent-swarm-framework/`: multi-agent execution framework
- `scripts/`: operational helper scripts

---

## パッケージの役割と関係

| パッケージ | 役割 | 配布先リポジトリ |
|---|---|---|
| dotfiles | AI 開発共通ルールの Source of Truth | ojos/ai-dotfiles |
| devcontainer-bootstrap (DCB) | Dev Container 環境を 1 コマンドで生成 | ojos/devcontainer-bootstrap |
| agent-swarm-framework (ASF) | マルチエージェント並列開発の実行基盤 | ojos/agent-swarm-framework |

**設計思想:**  
1. 新プロジェクトに DCB で Dev Container 環境を構築する  
2. ASF をインストールしてマルチエージェント運用を開始する  
3. dotfiles を参照して AI エージェント間の共通ルールを適用する

各パッケージは独立して利用できるが、3 つを組み合わせることで AI コーディング導入の初期コストを最小化できる。

### Roles And Relationship (English)

1. Build a Dev Container environment with DCB.
2. Install ASF and start multi-agent workflow operations.
3. Apply shared agent rules from dotfiles.

The three packages are intentionally independent but designed to work best together.

---

## dotfiles と ASF の境界判断

結論: `dotfiles` と `ASF` は分離維持を正とする。

判断理由:

- `dotfiles` は AI 開発共通ルールの Source of Truth を担い、実行ランタイムを持たない。
- `ASF` はマルチエージェント実行基盤（状態遷移・実行制御・監査）を担う。
- 役割を分離することで、パッケージ中立性・再利用性・リリース独立性を維持できる。

責務境界:

- `dotfiles` に置くもの:
    - 共通ポリシー、指示テンプレート、役割ガイド
- `ASF` に置くもの:
    - コマンド検証、状態管理、実行ワークフロー、運用スクリプト
- 重複禁止:
    - `dotfiles` 側へ実行制御ロジックを持ち込まない
    - `ASF` 側へプロジェクト固有ポリシーを埋め込まない

### Boundary Decision (English)

Decision: keep `dotfiles` and `ASF` separated.

Rationale:

- `dotfiles` owns shared AI rules and guidance templates, without runtime execution responsibilities.
- `ASF` owns runtime orchestration responsibilities such as command validation, state transitions, and workflow operations.
- Separation preserves package neutrality, reuse, and independent release cadence.

Boundary rules:

- Keep in `dotfiles`:
    - Shared policy, instruction templates, role guidance
- Keep in `ASF`:
    - Command validation, state handling, execution workflow, operational scripts
- Do not duplicate:
    - Runtime control logic in `dotfiles`
    - Project-specific policy values in `ASF`

---

## 開発ルール

- **ブランチ:** `main` への直 push 禁止。1 タスク 1 feature ブランチ + PR 経由で行う
- **スクリプト互換:** macOS bash 3.2+ 互換を維持する（`bash -n` で構文確認）
- **リリース:** 各パッケージは独立してタグを打ち、専用リリースリポジトリへ配布する
- **秘匿情報:** トークン・シークレットはファイルに保存しない（環境変数または CLI 認証を使う）

### Development Rules (English)

- No direct push to `main`; use feature branch and PR.
- Keep macOS bash 3.2+ compatibility and validate with `bash -n`.
- Release each package independently to its dedicated release repository.
- Never store secrets in files; use environment variables or CLI auth.

---

## ASF 強制適用の運用

本リポジトリでは ASF ワークフロー遵守を Git フックで強制する。

- VS Code Dev Container: 接続時に `postAttachCommand` から `scripts/on-attach.sh` が実行され、`.githooks` 設定が自動適用される。
- 非IDE（ターミナル）: 初回に `bash scripts/gate/install-git-hooks.sh` を実行し、commit/push 前に `bash scripts/asf-workflow.sh preflight` を実行する。
- 強制対象: `pre-commit` と `pre-push`。

### ASF Enforcement Operations (English)

ASF workflow compliance is enforced by Git hooks in this repository.

- VS Code Dev Container: `postAttachCommand` runs `scripts/on-attach.sh` and installs `.githooks` automatically.
- Non-IDE terminal: run `bash scripts/gate/install-git-hooks.sh` once per clone, then run `bash scripts/asf-workflow.sh preflight` before commit/push.
- Enforcement scope: `pre-commit` and `pre-push` only.

---

## リリースリポジトリとの関係

このセクションは `bash scripts/update-release-status.sh` で更新する。
リリース実施後は必ず同スクリプトを実行し、README の更新をコミットする。

<!-- RELEASE_STATUS:START -->
| パッケージ | 配布状態 |
|---|---|
| devcontainer-bootstrap | ojos/devcontainer-bootstrap で v0.1.11 まで公開済み |
| agent-swarm-framework | ojos/agent-swarm-framework で v0.1.3 まで公開済み |
| dotfiles | ojos/ai-dotfiles で v0.1.2 まで公開済み |

リリース実行手順は各パッケージの `docs/` または `.github/workflows/` を参照する。

### Release Status (English)

- `devcontainer-bootstrap`: published up to `v0.1.11` at `ojos/devcontainer-bootstrap`
- `agent-swarm-framework`: published up to `v0.1.3` at `ojos/agent-swarm-framework`
- `dotfiles`: published up to `v0.1.2` at `ojos/ai-dotfiles`
<!-- RELEASE_STATUS:END -->

---

