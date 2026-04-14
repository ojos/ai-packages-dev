# Copilot Workspace Instructions

このリポジトリは、パッケージ中立性を厳密に維持する。
This repository has a strict package-neutrality policy.

## 常時適用 / Always Apply

- `.github/PROJECT_DEFINITION.md` をプロジェクト固有の最上位定義として読み、必ず従う。
- Read and follow `.github/PROJECT_DEFINITION.md` as the project-specific source of truth.
- 汎用ルール（言語方針・命名規則）は `dotfiles/ai/common/shared-ai-rules.md` を参照する。
- For generic rules (language policy, naming convention), refer to `dotfiles/ai/common/shared-ai-rules.md`.
- packages構造・ASFワークフロー規則の汎用雛形は `packages/agent-swarm-framework/template-project/files/.github/PROJECT_DEFINITION.md` を参照する。
- For generic packages structure and ASF workflow rules, refer to `packages/agent-swarm-framework/template-project/files/.github/PROJECT_DEFINITION.md`.
- 利便性のための編集よりも、上記ポリシーを優先する。
- Treat the policy in that file as higher priority than convenience edits.
- `packages/**` に固有名詞を混入し得る編集は、ユーザー確認なしで実施しない。
- If an edit could introduce project-specific proper nouns into `packages/**`, do not proceed without user confirmation.

## 必須挙動 / Required Behavior

- パッケージ層（`packages/**`）は汎用・再利用可能に保つ。
- Keep package layer (`packages/**`) generic and reusable.
- 固有値はプロジェクト層ファイルにのみ配置する。
- Put project-specific values only in project layer files.
- Dev Container のプロファイル名対応では、パッケージ既定値変更ではなく、プロジェクト層設定と実行時オプションを優先する。
- When working on Dev Container profile names, prefer project-layer configuration and runtime options over package default changes.
- 本リポジトリでの開発運用は ASF ワークフローを標準とし、原則として `scripts/gate/workflow.sh` または `scripts/asf-workflow.sh` を使用する。
- Development operations in this repository should default to ASF workflow, using `scripts/gate/workflow.sh` or `scripts/asf-workflow.sh` in principle.
- ASF 実行時は前提チェック（設定ファイル・スクリプト・`gh auth`）を満たしていることを確認する。
- For ASF operations, ensure prerequisite checks pass (config files, scripts, and `gh auth`).
- 主要ドキュメント更新時は、日英併記を維持する。
- When updating major documentation, preserve Japanese-English bilingual content.
- 規範文は英語を残し、日本語は同義の補足として併記する。
- Keep normative statements in English and add equivalent Japanese text as a companion.

### ドキュメント分離運用 / Document Split Operations

- `packages/**/README.md` は英語正本として扱う。
- Package-layer README.md should be treated as the normative version in English.
- `packages/**/README.ja.md` は日本語翻訳版である。
- README.ja.md is the Japanese translation, and should be kept in sync with English updates.- `packages/agent-swarm-framework/docs/*.md` も英語正本として扱う。
- `packages/agent-swarm-framework/docs/*.md` should also be treated as normative English documents.
- 対応する日本語翻訳は `*.ja.md` として分離し、英語更新と同時に同期する。
- Matching Japanese translations should be split as `*.ja.md` and kept synchronized with English updates.- 英語更新後に日本語を必ず追随させる。同期漏れを避けるため、同時に両ファイルを編集する。
- Always update Japanese translation immediately after English updates, editing both files together to prevent sync drift.

## 衝突時の扱い / Conflict Handling

- ユーザー意図とポリシーが衝突する場合、パッケージ編集前に焦点化した確認質問を行う。
- If user intent and policy appear to conflict, ask a focused clarification question before changing package files.
