# Project Definition

This file is the project-specific source of truth.
このファイルは、プロジェクト固有の最上位定義です。

## Non-negotiable Policy / 非交渉ポリシー

- Do not add project-specific proper nouns into package code under `packages/**`.
- `packages/**` 配下のパッケージコードには、プロジェクト固有の固有名詞を追加しない。
- Examples of forbidden package-level proper nouns: user names, org names, repository names, account aliases, and customer names.
- 禁止対象の例: ユーザー名、組織名、リポジトリ名、アカウント別名、顧客名。
- Keep package defaults generic and reusable.
- パッケージの既定値は汎用・再利用可能に保つ。
- If project-specific values are needed, put them in project layer files only (for example `.devcontainer/**`, root-level runtime config, or local environment variables).
- 固有値が必要な場合は、プロジェクト層ファイルにのみ配置する（例: `.devcontainer/**`、ルート設定、ローカル環境変数）。

## GitHub Profile Rule / GitHub プロファイル規則

- For Dev Container generation, use the bootstrap option: `--github-profiles <csv>`.
- Dev Container 生成時は bootstrap オプションを使う: `--github-profiles <csv>`
- Do not hard-code profile names into package defaults in `packages/devcontainer-bootstrap/**`.
- `packages/devcontainer-bootstrap/**` の既定値へ、プロファイル名をハードコードしない。
- Profile names in use for this project: *(list your profiles here)*
- 本プロジェクトで使用するプロファイル名: *(ここにプロファイル名を記載する)*

## Safety Rule for AI Changes / AI 変更時の安全規則

- Before changing package files, verify that no project-specific proper noun is introduced.
- パッケージファイルを変更する前に、固有名詞が混入しないことを確認する。
- If a request conflicts with this policy, stop and ask the user before editing package files.
- リクエストがこの方針と衝突する場合、パッケージ編集前に必ずユーザーへ確認する。

## ASF Workflow Rule / ASF ワークフロー規則

- Development operations in this repository must follow the Agent Swarm Framework (ASF) workflow as the default standard.
- 本プロジェクトの開発運用は Agent Swarm Framework (ASF) ワークフローを標準とし、常にこれに従う。
- Workflow operations must be executed via `scripts/gate/workflow.sh` or `scripts/asf-workflow.sh`.
- ワークフロー操作は `scripts/gate/workflow.sh` または `scripts/asf-workflow.sh` を通じて実行する。
- Before ASF operations, validate prerequisites (config files, runtime scripts, and `gh auth`).
- ASF 実行前に前提条件（設定ファイル・実行スクリプト・`gh auth`）を確認する。
- Any exception to ASF workflow must be explicitly approved by the user beforehand.
- 例外運用を行う場合は、事前にユーザー合意を得る。

## Quick Verification / クイック検証

Use this check before committing policy-sensitive changes.
ポリシー影響のある変更をコミット前に、次を実行する。

```bash
# Replace <your-org> with your project's proper nouns
rg -n "<your-org>" packages/
```

Expected result: No matches unless explicitly approved by the user for a package-level exception.
期待結果: ユーザー明示承認の例外がない限り、`packages/` 配下で一致しないこと。

## ASF Workflow: Delegation Pattern / ASF ワークフロー: 実装委譲パターン

This agent follows ASF workflow. **Implementation work should be delegated to line workers** as a principle.
このエージェントは ASF (Agent Swarm Framework) workflow に従う。**実装作業は line worker に委譲する**ことを原則とする。

### When to Delegate Implementation / 実装委譲の判定

Delegate when:
- Issue scope is explicit.
- Issue title starts with `implementation:` or `feature:`.
- The task includes code generation or modification.
- Code review is required.

Do not delegate when:
- The task is documentation-only.
- The task is design/analysis/decision making.
- The task is small-scale validation.
- The user explicitly requests direct implementation.

### Standard Executable Delegation Path / 実行委譲の標準経路

Issue creation/comments alone do not enqueue executable line-worker work.
Issue 作成やコメント追加だけでは line worker は実行を開始しない。

Use the following command to convert an implementation issue into an executable line-worker task:
実装 issue を line worker が実行可能なタスクに変換するには次を使用する:

```bash
bash scripts/worker/delegate-issue-implementation.sh \
	--issue-number <N> \
	--line auto-001 \
	--task-command "<shell-command>"
```

### Conditional Auto-Enqueue / 条件付き自動enqueue

- For `implementation:` / `feature:` issues, auto-enqueue may run only when `line-task` + `auto-enqueue` labels exist and required fields are present.
- `implementation:` / `feature:` issue で `line-task` + `auto-enqueue` が付与され、必要フィールドが揃う場合のみ自動実行する。

### Issue Closure Policy / Issue クローズ方針

- Always add an explicit closure reason comment before closing an issue.
- Issue をクローズする際は必ずクローズ理由をコメントで明示する。
- Classify closure reason as one of: `completed`, `superseded`, `duplicate`, `invalid`, `deferred`.
- クローズ理由は `completed` / `superseded` / `duplicate` / `invalid` / `deferred` のいずれかに分類する。
- For `superseded` / `duplicate`, include replacement issue numbers.
- `superseded` / `duplicate` では置き換え先 issue 番号を明記する。
- For implementation issues, include at least one line of verification outcome.
- 実装系 issue のクローズ時は検証結果（テスト/実行結果）を最低 1 行含める。
- Use `scripts/worker/close-issue-with-policy.sh` for standardized closure operations.
- 標準化されたクローズ処理は `scripts/worker/close-issue-with-policy.sh` を使用する。

### End-State Cleanup Policy / 終了時整理方針

- During execution, temporary deviation from 1:1:1 mapping among issue/PR/merge is allowed.
- 実行中は `issue:PR:merge` が一時的に 1:1:1 でなくても許容する。
- At completion, always normalize by resolving stale PRs, implemented issues, and runtime queue leftovers.
- 作業終了時には未採用PR・実装済みIssue・キュー残件を必ず整理しクリーン状態へ戻す。
- Merge accepted PRs and close unnecessary PRs with explicit reasons.
- 採用PRはマージし、不要PRは理由付きでクローズする。
- Verify open issue / open PR / pending queue / dead-letter status before completion.
- 終了前に open issue / open PR / pending queue / dead-letter の状態を確認する。
- Completion criterion: clean, restartable, and auditable repository/runtime state.
- 最終判定の基準は「再開可能かつ追跡可能なクリーン状態」とする。

### Operational Strictness Policy / 運用厳格度方針

- For `production` / `mainline` work, milestone and GitHub Project updates are mandatory.
- `production` / `mainline` 向け作業では milestone / GitHub Project の更新を必須とする。
- For `spike` / `hotfix` / small tasks, milestone/Project updates are optional during execution.
- `spike` / `hotfix` / 小規模タスクでは実行中の milestone / Project 更新を任意とする。
- Even in optional mode, end-state normalization is mandatory.
- 任意運用を選んだ場合でも終了時正規化は必須とする。
- If simplified mode was used, closure comments must include post-normalization result.
- 簡略運用を行った場合はクローズ時コメントに後追い正規化結果を明記する。

### Error Handling / エラーハンドリング

- If line worker is unavailable, notify the user and report delegation failure.
- Line worker が不可用な場合はユーザーへ通知し、委譲不能を報告する。
- If issue scope is unclear, request clarification before delegation.
- Issue scope が不明確な場合は委譲前に確認する。
- If review is required but no reviewer is available, set escalate flag in consult log.
- review が必要だが reviewer 不在の場合は consult log に escalate flag を設定する。

## @intake Command / @intake コマンド

When a user message starts with `@intake`, trigger the Intake Manager flow.
ユーザーが `@intake` でメッセージを開始した場合、Intake Manager フローを起動する。

### Trigger Condition / トリガー条件

- Activate only when the message starts with `@intake`.
- メッセージが `@intake` で始まる場合のみ起動する。
- Do not apply to normal conversation without `@intake`.
- `@intake` なしの通常会話には適用しない。

### Execution Flow / 実行フロー

```bash
Step 1: 要件テキストの確定
Step 2: 意図の解釈・確認
Step 3: Consult Facilitator による設計妥当性確認（条件付き）
Step 4: conversation-entry.sh を dry-run で実行
Step 5: INTAKE_CONFIRMATION_BLOCK を提示・確認
Step 6: 計画整合性レビュー（必須）
Step 7: 最終意図確認（実行前ゲート）
Step 8: issue 化 + /intake dispatch
Step 9: ASF フローへ自動移行
```

### Constraints / 制約

- Do not create an issue without explicit user approval at Step 7.
- Step 7（ユーザー承認）なしに issue を作成してはならない。
- Intake issues must carry `type: orchestrator-intake` label.
- intake issue は `type: orchestrator-intake` ラベルを必ず持つ。
- Follow intake-manager authority boundary.
- intake-manager の権限境界に従う。
