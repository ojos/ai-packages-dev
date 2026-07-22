# ai-packages-dev

ai-playbook / DevContainer Bootstrap (DCB) の 2 パッケージを共同開発するためのモノリポジトリです。

各パッケージは独立して配布可能な設計ですが、相互補完することで AI コーディング導入のシナジーを生み出すために、開発は 1 リポジトリに集約します。

## パッケージ構成

```
ai-packages-dev/
├── .ai-playbook/                    # AI 運用規範の正本（配布先 ojos/ai-playbook）
│   ├── shared-ai-rules.md           # 共通規範
│   ├── role-contracts/              # ロール責務の契約 7 種
│   ├── task-playbooks/              # タスク手順 4 種
│   ├── review-workflow.md           # レビュー運用
│   ├── intake/                      # intake 規律・判定 reason code
│   └── templates/                   # 導入用の雛形
├── packages/
│   └── devcontainer-bootstrap/      # 環境生成と規範配布
│       ├── bootstrap.sh             # メインスクリプト
│       ├── doctor.sh                # 自己診断スクリプト
│       └── tests/                   # 機能テスト
└── scripts/
    ├── github-account-switch.sh     # GitHub マルチアカウント切替
    ├── release-packages.sh          # 2 パッケージのリリース実行
    └── setup-devcontainer-bootstrap-release-repo.sh  # DCB 公開リポジトリ初期化
```

## パッケージの役割と関係

| パッケージ | 役割 | 配布先リポジトリ |
|---|---|---|
| ai-playbook | AI 運用規範の正本。ランタイムを持たない | ojos/ai-playbook |
| devcontainer-bootstrap (DCB) | Dev Container 環境を 1 コマンドで生成し、規範を配置する | ojos/devcontainer-bootstrap |

**設計思想:**

1. 新プロジェクトに DCB で Dev Container 環境を構築する（`--with-playbook` で規範も同時に配置）
2. 配置された規範に沿って、実行環境のネイティブ機能で運用する

**DCB = 配布機構 / ai-playbook = 正本**という分担です。DCB は規範の内容を定義せず、配置のみを担います。
規範は実行基盤・状態面・ベンダーの選択を強制しません。

## 経緯: Agent Swarm Framework の退役

このリポジトリはかつて 3 パッケージ体制で、Agent Swarm Framework (ASF) がマルチエージェント実行基盤を担っていました。
ASF は 2026-07 に退役しました。

理由は次の 2 点です。

- ASF の実行基盤が担っていた機能（並列サブエージェント、worktree 分離、オーケストレーション、監視、GitHub 連携）が、各 AI ベンダーの標準機能に置き換わった
- 稼働実績が停止していた（全期間で 91 イベント、コマンド履歴は 10 日分、最終稼働 2026-05-25）

保全価値のある規範（ロール契約・intake 規律・reason code）は規範パッケージ（当時 dotfiles、現 ai-playbook）へ、その配布経路は DCB へ移しました。
退役の判断根拠と実施記録は [docs/records/ASF_RETIREMENT_RECORD.md](docs/records/ASF_RETIREMENT_RECORD.md) にあります。

---

## 開発ルール

- **ブランチ:** `main` への直 push 禁止。1 タスク 1 feature ブランチ + PR 経由で行う
- **スクリプト互換:** macOS bash 3.2+ 互換を維持する（`bash -n` で構文確認）
- **リリース:** 各パッケージは独立してタグを打ち、専用リリースリポジトリへ配布する
- **秘匿情報:** トークン・シークレットはファイルに保存しない（環境変数または CLI 認証を使う）

## リリースリポジトリとの関係

このセクションは `bash scripts/update-release-status.sh` で更新する。
リリース実施後は必ず同スクリプトを実行し、README の更新をコミットする。

<!-- RELEASE_STATUS:START -->
| パッケージ | 配布状態 |
|---|---|
| devcontainer-bootstrap | ojos/devcontainer-bootstrap で v0.5.1 まで公開済み |
| ai-playbook | ojos/ai-playbook で v0.1.2 まで公開済み |

リリース実行手順は各パッケージの `docs/` または `.github/workflows/` を参照する。

### リリース状況

- `devcontainer-bootstrap`: `ojos/devcontainer-bootstrap` で `v0.5.1` まで公開済み
- `ai-playbook`: `ojos/ai-playbook` で `v0.1.2` まで公開済み
<!-- RELEASE_STATUS:END -->

---

