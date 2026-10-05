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

- このリポジトリはリモート最終ゲート（Copilot code review の要求・確認）を**置きません**。詳細は `.github/project-ai-rules.md`「リモート最終ゲート（置かない）」です。
- `.github/workflows/second-opinion-gate.yml`: 第二意見（クロスモデル）を回したことの記録が、push した head に紐づいて存在するかを別の契機（PR 更新・定期実行）から確認します。要求はしません。規範の正本は `.ai-playbook/review-workflow.md`（リモート最終ゲート（任意の層）の「常に置く標準の機構層」）です。
