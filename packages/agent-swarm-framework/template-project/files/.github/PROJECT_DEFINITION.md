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
