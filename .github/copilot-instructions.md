# Copilot 実行環境向け入口ファイル

このファイルは Copilot 系実行環境向けの入口ファイルです。

## 指示の適用順序

次の順序でルールを適用します（下位から上位へ優先）。

1. `.ai-playbook/shared-ai-rules.md`（全体共通ルール）
2. `.github/project-ai-rules.md`（プロジェクト共通ルール）
3. このファイル（Copilot 実行環境固有の最小差分）

## この入口ファイルの責務

- このファイルでロール契約を再定義しません。
- このファイルは最小構成に保ち、実行環境固有の差分のみを扱います。
- プロジェクト層ポリシーの正本は `.github/project-ai-rules.md` とします。

## この実行環境の実装機構

規範はここで再定義せず、対応する正本を指します。

- `.github/workflows/copilot-review.yml`: PR 作成時（`pull_request: types: [opened]`）に Copilot へレビューを一度だけ自動要求します。更新（synchronize）では再要求しません。fork からの PR はスキップします。トークンは `COPILOT_REVIEW_TOKEN` があればそれを、無ければ `GITHUB_TOKEN` を使います。規範の正本は `.ai-playbook/review-workflow.md`（リモート最終ゲート）です。
