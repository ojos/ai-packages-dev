# プロジェクト共通 AI ルール

このリポジトリは、パッケージ中立性を厳密に維持します。

このファイルは常時載る「地図」です。持つのは、禁止事項・既定の動作・ファイルを読まずに実行する場面で要る手順だけです。理由・経緯・実測・詳しい手順は `.claude/rules/` の規則へ置き、`paths:` に一致するファイルに触れたときだけ載せます（規則の中で `@` の取り込みは使いません。`paths:` 付きの規則の中の `@` は起動時から載り、条件付きにならないためです。#676）。

## 参照先

- 全体共通ルール: `.ai-playbook/shared-ai-rules.md`
- プロジェクト固有の最上位定義: `.github/PROJECT_DEFINITION.md`
- ロール責務 `.ai-playbook/role-contracts/` / タスク手順 `.ai-playbook/task-playbooks/` / レビュー運用 `.ai-playbook/review-workflow.md` / ループ運用 `.ai-playbook/loop-workflow.md` / intake 規律 `.ai-playbook/intake/`

実行環境の入口ファイルはこのファイルを参照し、最小差分のみを記述します。

## 常時適用

- `.github/PROJECT_DEFINITION.md` を最上位定義として読み、必ず従います。利便性のための編集よりも優先します。
- 汎用ルール（言語方針・命名規則）は `.ai-playbook/shared-ai-rules.md` を参照します。
- `packages/**` に固有名詞を混入し得る編集は、ユーザー確認なしで実施しません。パッケージ層は汎用・再利用可能に保ち、固有値はプロジェクト層ファイルにのみ置きます（詳細: `.claude/rules/packages-layer.md`）。
- Dev Container の環境差は、パッケージ既定値ではなくプロジェクト層（`.env` / `.devcontainer/`）で吸収します。ホスト OS の資格情報を運ぶ生成時オプションは廃止済みで、指定すると `bootstrap.sh` が停止します（`--github-profiles` / `--gemini-key-env`）。
- 主要ドキュメントの更新時は日本語での一貫性を維持します。Git フックによるワークフロー強制は行いません（push 前のゲートは `scripts/loop-gate.sh`、リモート側は CI）。
- パッケージ中立性の検証コマンドと期待結果は `.github/PROJECT_DEFINITION.md`「クイック検証（パッケージ中立性）」。同じ判定を `ci.yml` の `neutrality` ジョブと `scripts/acceptance.sh` が持ちます。

## 機密の具体化

共通規範「機密の取り扱い」（`.ai-playbook/shared-ai-rules.md`）を、このリポジトリで具体化します。

- 機密の読み取り元: `.env`（`scripts/load-project-env.sh` が読み込む）、および GitHub CLI の認証情報
- 追跡除外: `.env` および `.env.*`（`.gitignore` 済み）
- 共有する雛形: 値のない `.env.example` のみ
- ホスト OS の資格情報をコンテナへ注入しません。`devcontainer.json` の `remoteEnv` が運ぶのは `LOCAL_WORKSPACE_FOLDER` のみで、CI の `Self devcontainer credential isolation` ジョブがこれを検査します
- GitHub の認証だけは例外で、PAT を `.env` の `GH_TOKEN` へ置きます（理由と運用は`.claude/rules/github-auth.md`「GitHub 認証（gh CLI）」）。`GH_TOKEN` を空にし、かつ `GITHUB_TOKEN` も設定しない環境は従来どおり、コンテナ内の `gh auth login` と `gh-storage` volume で動きます。どちらの場合も、gh が `~/.config/gh/hosts.yml` に持つ状態を volume の外へ写しません
- リリース実行時、シークレットの値をリリース資産へ含めません

## 生成物の具体化

共通規範「生成物の取り扱い」（`.ai-playbook/shared-ai-rules.md`）を、このリポジトリで具体化します。

コミットしない生成物:

- 依存・ビルド成果物・キャッシュ（`node_modules/`、`dist/`、`coverage/` など）。列挙の正本は `.gitignore` の DCB 管理セクション（`# >>> devcontainer-bootstrap managed section >>>` 〜 `# <<< devcontainer-bootstrap managed section <<<`）です。
- 機密ファイル `.env` / `.env.*`（`.env.example` のみ追跡。上記「機密の具体化」）
- ローカル引き継ぎメモ `GETTING_STARTED.md`（ワークスペースには残すがコミットしない）
- Claude Code のローカル設定 `.claude/*`（`.claude/skills/`・`.claude/agents/`・`.claude/rules/`・`.claude/settings.json` だけを再包含して追跡します。ローカル設定ではなく規範と機構の配布物のため）

再生成手順:

- `.gitignore` の管理セクション: `packages/devcontainer-bootstrap/bootstrap.sh` が管理セクションのみを冪等に書き換えます（抑止は `--no-gitignore`、テンプレート追加は `--gitignore-targets`）。管理セクション外の記述は手で管理します。
- `.env`: `.env.example` を複製し、値を各自が設定します
- AI CLI（`gemini` 等）: `bash scripts/install-ai-tools.sh`

再生成できる大容量の生成物・メディアはリポジトリへ置きません。共有が必要な場合はリポジトリ外の手段を使います。


## Git identity と GitHub 認証

- 人の操作の名義は `.env` の `GIT_IDENTITY_NAME` / `GIT_IDENTITY_EMAIL`（commit / tag / push のすべて）。bot の名義は公開リポジトリへの release snapshot だけです。global の identity に依存しません。
- push / リリース実行の前に `bash scripts/verify-commit-identity.sh` で作者情報を検証します。別 identity を検出したら中断し、`bash scripts/setup-git-identity.sh` を適用して該当コミットを `git rebase` で作り直します。
- `GITHUB_TOKEN` を手元のシェル・rc・`.env` に置きません。`GH_TOKEN` を設定しているあいだ `gh auth login` を実行しません（OAuth の上限枠を消費し、他環境のトークンを失効させるため）。PAT は fine-grained を使い、値をコミット・issue・PR・ログへ混入させません。
- 詳細: `.claude/rules/git-identity.md` / `.claude/rules/github-auth.md`

## 作業状況の記録先

共通規範「作業状況の記録」を、このリポジトリで具体化します。

- 未完了の作業と完了の履歴: GitHub の issue / PR を正とします
- 完了の記録には、クローズ理由と検証結果を含めます（下記「Issue クローズ方針」）
- 単一ファイルへの状況集約は行いません。並列実行時のコンフリクトを避けるためです

## 外部サービスの状態管理

- リリースは GitHub Actions（`release.yml` の `workflow_dispatch`）でだけ実行し、ローカルから `--execute` しません（`scripts/release-packages.sh` が Actions 外を拒否します）。手動の `gh` / `git push` は状態確認・調査に留めます。
- 公開リポジトリの存在と設定は Terraform（`infra/github/`）で宣言し、apply は `main` の Actions からだけです。公開リポジトリを消す plan は apply しません。
- このモノレポ自身の脆弱性報告の窓口は手で有効にし、設定を変えたときとリリースの前に `bash scripts/check-repo-security.sh` で照合します。
- 詳細（手順・資格情報・脆弱性の通知）: `.claude/rules/external-services.md`

## レビューとゲート

push / PR 作成の前に、次の順で通します。

1. 主レビュー: `/code-review`（セキュリティに関わる差分は `/security-review` も）でステージ済み差分をレビューし、その場で修正する。受け入れ条件を満たした後・主レビューの前に、コードに限り `/simplify` を 1 回だけ使える（Markdown は対象外）。
2. `bash scripts/loop-gate.sh`: commit identity 検証 → `scripts/verify.sh`（受け入れ検証）→ 第二意見（`scripts/second-opinion-review.sh`）を直列化する。終了コード 0 = `GATE_PASS`（push 可）。
3. push 後、PR を作ったら `bash scripts/second-opinion-record.sh post` で記録を投稿し、修正を push し直すたびに打ち直す。PR を作ったら `/land` を使う（マージ直前の承認はフックが保証する）。

- 第二意見のエンジンは `--engine` で渡す（`SECOND_OPINION_ENGINE` の前置は `.env` に負ける）。コマンドの差し替えは `LOOP_GATE_REVIEW_CMD`。範囲は `LOOP_GATE_REVIEW_RANGE` で受ける。
- 却下できるのはレビュー指摘だけ。コマンドと出力をそのまま PR 本文またはコメントへ記録し、第二意見を却下して通すときは記録後に `LOOP_GATE_REVIEW_CMD= bash scripts/loop-gate.sh` で回し、その使用も PR へ記録する。`verify.sh` と CI の失敗は却下せず、`VERIFY_ACCEPTANCE` の差し替えで迂回しない。
- `ci.yml` / `identity-guard.yml` を変更したら `scripts/acceptance.sh` も同じ内容へ追随させる。
- 1 回の `LGTM` は重大な指摘が無いことの証明ではなく、主レビューを省略してよい根拠にもならない。
- 詳細（オプション表・判定方式・限界・リモート最終ゲート）: `.claude/rules/review-gate.md`

## リモート最終ゲート（置かない）

push / PR 作成後のリモート最終ゲート（Copilot code review の要求・確認）は置きません。標準の機構層（第二意見の記録と確認側 `second-opinion-gate.yml`、CI による受け入れ検証の再実行）で運用します。失う性質と受け入れる理由は `.claude/rules/review-gate.md`「リモート最終ゲート（置かない）」にあります。

## ドキュメント・issue・質問

- README は `packages/**/README.md` を単一の正本とし、翻訳版を足すときは意味の一致を確認する。GitHub issue（実装委譲 issue `implementation:` / `feature:` を含む）は日本語で統一し、規範・判定基準・受け入れ条件は日本語で明確に書く。
- AI からの確認事項は、一問ずつ・質問意図付き・選択肢優先（推奨順、最後に自由入力欄）で行う。
- ユーザー意図とポリシーが衝突するときは、パッケージ編集前に焦点化した確認質問を行う。
- ディレクトリ構造（`src` / `docs` / `tests` など）は新規生成時の推奨で、既存プロジェクトには強制せず非破壊で運用する。サブディレクトリ構造は強制しない。既定と異なる生成が要るときは理由を明示して最小変更で対応する。適用はレビューで担保し、設定ファイルやウィザードの機構は持たない。
- 作業終了時は、実装済み issue を理由と検証結果付きでクローズし、採用 PR はマージ、不要 PR は理由付きでクローズして、open の issue / PR を確認する。`production` / `mainline` 向けは milestone / Project の更新を必須とし、`spike` / `hotfix` / 小規模タスクでは実行中の更新を任意とする。任意運用や簡略運用をしたら、終了時に正規化し、クローズ時コメントに「後追い正規化」の結果を明記する（詳細: `.claude/rules/issue-operations.md`）。
- Issue scope が不明確なとき、レビューの要否や判定に迷うときは、独断で進めずユーザーへ確認・エスカレーションする。

## Issue クローズ方針

- Issue をクローズする際は、必ずクローズ理由をコメントで明示します。
- クローズ理由は `completed`, `superseded`, `duplicate`, `invalid`, `deferred` のいずれかに分類します。
- `superseded` / `duplicate` では置き換え先 issue 番号を明記します。
- 実装系 issue のクローズ時は、検証結果（テスト/実行結果）を最低1行含めます。

## 実装委譲パターン

判定の正本は `.ai-playbook/shared-ai-rules.md` 13 章「実装委譲パターン」です（ここでは複製しません）。

| コマンド | 意図 | エージェント動作 |
|---|---|---|
| 進めて下さい | 次フェーズへ | 委譲判定 →（サブエージェントまたは自実装） |
| やってしまえ | 直接実装する | 委譲をスキップして直接実装 |
| 確認して | 分析・レビューのみ | 委譲なしで実施 |
| #N を実装して | 特定 issue の実装 | Issue scope 確認後、委譲判定 |

委譲先のモデルとツールは `.claude/agents/` の frontmatter で固定します。次の表はその写しで、`tests/test-subagent-roles.sh` が機械照合します。

| 役割 | model | tools | 契約の正本 |
|---|---|---|---|
| `explorer` | `haiku` | 編集系を外す | プロジェクト層で定義（共有層の契約は未整備） |
| `implementer` | `sonnet` | 編集系を含む | `.ai-playbook/role-contracts/implementer.md` |

- 「編集系を外す」は「編集できない」ではありません（`Bash` 経由の書き込みは塞げません）。
- intake-manager / orchestrator / closer / consult-facilitator / planner / reviewer は親セッションが担い、サブエージェントにしません。
- 実装を伴うサブエージェントへ並列委譲するときは、親が `isolation: "worktree"` を指定します。並列実装を統合したら、統合後のツリーで各レーンの受け入れ条件を再実行します。
- 詳細（親が担う理由・統合検証）: `.claude/rules/delegation.md`

## intake フロー

起動経路は 2 つです。起動手段は実行環境に依存し（Claude Code では `/intake` スキル）、この節は起動後の挙動だけを規定します。

- **明示起動**: ユーザーが起動を明示要求したら、確認なしに直ちに起動する。
- **自動提案**: 実装・変更を伴う「やりたいこと」が具体的に述べられたと判断したら、「これは要件定義（intake）として進めますか？」の 1 問だけを選択肢つきで提案する。承認された場合のみ Step 1 へ進み、承認されなければ通常会話を続ける。
- **提案しない**: 質問・調査・説明依頼・雑談、既存コードの読解・レビュー・分析のみの依頼、実現したいことが未確定で発散させている段階。一度見送られた要件は、明確な再要求があるまで再提案しない。迷うときは起動せず提案に留め、可否はユーザーが決める。
- 起動したら（自動提案で承認された場合も）`/intake` スキルで進める。`/intake` が `.ai-playbook/intake/` を読むので、Step 1〜9 の規則が載る。
- Step 2 で、解釈した目的と変更の範囲をユーザーが「合っている」と確認するまで次へ進まない。intake 票は Step 5 で承認を得て、Step 6 で計画のレビュー（`.ai-playbook/task-playbooks/plan-review.md` の観点 A）を通す。
- Step 7（ユーザー承認）なしに issue を作成しない。ループ対象の作業は、Step 6 で機械判定できる acceptance を確定してから実装委譲へ移す。
- 詳細（Step 1〜9 と制約）: `.claude/rules/intake-flow.md`
