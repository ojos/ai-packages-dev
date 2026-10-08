# ai-packages-dev

ai-playbook / DevContainer Bootstrap (DCB) / devcontainer-host (devhost) の 3 パッケージを共同開発するためのモノリポジトリです。

各パッケージは独立して配布可能な設計ですが、相互補完することで AI コーディング導入のシナジーを生み出すために、開発は 1 リポジトリに集約します。

## パッケージ構成

```
ai-packages-dev/
├── .ai-playbook/                    # AI 運用規範の正本（配布先 ojos/ai-playbook）
│   ├── shared-ai-rules.md           # 共通規範
│   ├── role-contracts/              # ロール責務の契約 7 種
│   ├── task-playbooks/              # タスク手順 4 種
│   ├── review-workflow.md           # レビュー運用
│   ├── loop-workflow.md             # ループコーディング運用の規範
│   ├── loop-coding-guide.md         # ループコーディングの解説ガイド
│   ├── intake/                      # intake 規律・判定 reason code
│   └── templates/                   # 導入用の雛形
├── packages/
│   ├── devcontainer-bootstrap/      # 環境生成と規範配布
│   │   ├── bootstrap.sh             # メインスクリプト
│   │   ├── doctor.sh                # 自己診断スクリプト
│   │   └── tests/                   # 機能テスト
│   └── devcontainer-host/           # 外部の機械で devcontainer を保つ道具 devhost（配布先 ojos/devcontainer-host）
├── docs/                            # ドキュメント
│   ├── CATALOG.md                   # docs 配下の索引（正本）
│   ├── release/                     # リリース実行手順・履歴・リリースノート
│   ├── records/                     # 判断根拠と実施記録
│   └── archive/                     # 旧世代（参照のみ・更新しない）
└── scripts/                         # 運用スクリプト（一覧と用途は scripts/CATALOG.md が正本）
```

`docs/` と `scripts/` の個々のファイルはここでは列挙しません。索引は [docs/CATALOG.md](docs/CATALOG.md) と [scripts/CATALOG.md](scripts/CATALOG.md) を正本とします（2 箇所へ列挙すると、片方だけ古くなる形で必ずずれるため）。

索引と実体のずれは [.github/workflows/ci.yml](.github/workflows/ci.yml) の `consistency` ジョブが検査します。検査対象は `docs/` 配下の `.md` と `scripts/` 配下の `.sh` に限定され、内容は次の 2 点です。

- 追跡対象の `docs/*.md` / `scripts/*.sh` が、それぞれの CATALOG に列挙されていること
- 各 CATALOG が列挙する `docs/` / `scripts/` のパスが実在すること

`scripts/CATALOG.md` の収録ルールは `scripts/` 配下の運用対象ファイル全般を対象としますが、CI が未記載を検知できるのは `.sh` だけです。`.sh` 以外を追加・削除・改名したときは、同一コミットで CATALOG を手動更新してください。

## パッケージの役割と関係

### 3 パッケージの関係

<!-- package-relations:begin -->
ai-playbook・devcontainer-bootstrap（DCB）・devcontainer-host（devhost）は、それぞれ単体で使えます。DCB を中心に組み合わせると、効果が最大になります。

| パッケージ | 単体での用途 | 配布先 |
|---|---|---|
| ai-playbook | AI 運用の規範（ルール）だけを、プロジェクトへ入れる | ojos/ai-playbook |
| DCB | プロジェクトの devcontainer を 1 コマンドで生成する | ojos/devcontainer-bootstrap |
| devhost | 任意の `devcontainer.json` を持つプロジェクトを、SSH で届く外部の機械で常駐させる | ojos/devcontainer-host |

**DCB が中心です。** DCB は、ほかの 2 つが着地する場所（プロジェクトの devcontainer）を作ります。ai-playbook の規範はその中に置かれ（DCB が配布機構で、正本は ai-playbook です）、devhost はそのコンテナを外部の機械で動かし続けます。

- **DCB と ai-playbook**: DCB が、生成先のプロジェクトへ規範を配置します（`--playbook-version` などで取得元を指定する。新しい版へ移るときは、`--upgrade` に新しい `--playbook-version` を渡す）。DCB は規範の内容を持ちません。
- **DCB と devhost**: DCB の生成物には、devhost が前提にする、または助かるもの（tmux、compose の `init: true`、codex のサンドボックスの設定（`--with-codex` のとき）、UID の合わせ込み）が入っています。devhost は DCB の生成物でなくても使えますが、DCB の生成物ならこれらが最初から揃います。理由と意味は devhost の README の「DCB と一緒に使うと揃うもの」にあります。
- **ai-playbook と devhost**: 今は直接の関係がありません。

**入れ方は 2 段です。** 置く場所と単位が違うため、DCB のオプションでは devhost は入りません（DCB が書き込むのは生成先のプロジェクトの中だけで、外部の機械のホームやユーザーの systemd には書き込みません）。

1. プロジェクトごとに、プロジェクトの中へ DCB で devcontainer（と、必要なら規範）を生成する。
2. 外部の機械ごとに、外部の機械のホームへ devhost を入れ、設定ファイル（`projects`）にそのプロジェクトを 1 行足す。
<!-- package-relations:end -->

`packages/devcontainer-host/`（devhost）は、SSH で届く外部の機械の上で devcontainer を保つための道具一式です。
DCB のリリースには同梱せず、独自の版を持つ公開リポジトリ `ojos/devcontainer-host` のリリースで配ります（最初の版は v0.1.0 の予定。公開前は下の「リリース状況」が「未公開」になります）。

**設計思想:**

1. 新プロジェクトに DCB で Dev Container 環境を構築する（`--with-playbook` で規範も同時に配置）
2. 配置された規範に沿って、実行環境のネイティブ機能で運用する

**DCB = 配布機構 / ai-playbook = 正本**という分担です。DCB は規範の内容を定義せず、配置のみを担います。
規範は実行基盤・状態面・ベンダーの選択を強制しません。

### 規範は中立、機構は Claude Code を優先する

規範（ai-playbook の文書）は特定の実行環境に依存しません。一方、規範を実行環境で動かす機構（スキル・委譲先エージェント・フック）は、Claude Code 向けだけを用意しています。主な利用者が Claude Code を使うためで、ほかの実行環境向けの機構は現時点では用意していません。実行環境ごとの対応範囲は次のとおりです（配布機構 devcontainer-bootstrap で規範を配置したときの生成物）。

| 実行環境 | 入口ファイル | スキル | 委譲先エージェント | フック | 第二意見のエンジン |
|---|---|---|---|---|---|
| Claude Code | `CLAUDE.md` | あり（`.claude/skills/intake` / `land`。`--with-claude` 指定時） | あり（`.claude/agents/explorer.md` / `implementer.md`。`--with-claude` 指定時） | あり（マージ前の確認フック。`--with-claude` 指定時） | 実行環境とは独立（下記） |
| GitHub Copilot | `.github/copilot-instructions.md` | なし | なし | なし | 実行環境とは独立（下記） |
| `AGENTS.md` を読む実行環境（Codex など） | `AGENTS.md` | なし | なし | なし | 実行環境とは独立（下記） |

- 入口ファイルは 3 つとも同じ雛形（`templates/entry.md`）の写しで、プロジェクト共通ルールを経由して 3 層構造へつながります。規範を置かない生成では、どれも作りません。
- 第二意見のエンジンは、実行環境ではなく `scripts/second-opinion-review.sh --engine` で選びます（`gemini`（既定）/ `antigravity` / `codex`）。第二意見は主レビューと別ベンダーのモデルで取ることが前提です。エンジンは実行環境から自動では決まらず、選び方の検査もしないため、**主レビューと同じベンダーのエンジンを選ばないでください**（例: Codex で実装するなら `codex` 以外）。
- GitHub Copilot のリモートレビュー要求（`--with-copilot-review`）は、リモート最終ゲートの選択制の機構です。入口ファイルの有無とは別です。

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

このセクションのブロックは `bash scripts/update-release-status.sh` が生成する。
リリースは GitHub Actions で実行するため、`scripts/release-packages.sh` がリリース処理の最後に行う自動更新は runner 側の作業ツリーにしか残らない。
リリース後は手元で同スクリプトを実行し、差分をコミットする（[RELEASE_EXECUTION_RUNBOOK](docs/release/RELEASE_EXECUTION_RUNBOOK.md) の「事後確認」）。

<!-- RELEASE_STATUS:START -->
| パッケージ | 配布状態 |
|---|---|
| devcontainer-bootstrap | ojos/devcontainer-bootstrap で v0.17.0 まで公開済み |
| devcontainer-host | ojos/devcontainer-host は未公開（Release なし） |
| ai-playbook | ojos/ai-playbook で v0.8.1 まで公開済み |

リリース実行手順は [docs/release/RELEASE_EXECUTION_RUNBOOK.md](docs/release/RELEASE_EXECUTION_RUNBOOK.md) を参照する。

### リリース状況

- `devcontainer-bootstrap`: `ojos/devcontainer-bootstrap` で `v0.17.0` まで公開済み
- `devcontainer-host`: `ojos/devcontainer-host` は未公開（Release なし）
- `ai-playbook`: `ojos/ai-playbook` で `v0.8.1` まで公開済み
<!-- RELEASE_STATUS:END -->

---

