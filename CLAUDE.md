# Claude 実行環境向け入口ファイル

このファイルは Claude 系実行環境向けの入口ファイルです。

## 指示の適用順序

次の順序でルールを適用します（下位から上位へ優先）。

1. `.ai-playbook/shared-ai-rules.md`（全体共通ルール）
2. `.github/project-ai-rules.md`（プロジェクト共通ルール）
3. このファイル（Claude 実行環境固有の最小差分）

## この入口ファイルの責務

- このファイルでロール契約を再定義しません。
- このファイルは最小構成に保ち、実行環境固有の差分のみを扱います。
- プロジェクト層ポリシーの正本は `.github/project-ai-rules.md` とします。
- AI からの質問運用は `.github/project-ai-rules.md` に従い、一問ずつ、質問意図付き、選択肢優先で行います。

## この実行環境の実装機構

規範はここで再定義せず、対応する正本を指します。

- `.claude/skills/intake/SKILL.md`: `/intake` の起動点です。推奨配線を採用済みで、`.gitignore` は `.claude/*` を除外しつつ `!.claude/skills/` で再包含するため追跡対象です。判定基準・票の項目定義は複製せず、`.github/project-ai-rules.md`「intake フロー」と `.ai-playbook/intake/` を参照します。
- `.claude/skills/land/SKILL.md`: `/land` の起動点です。この会話で PR を作ったら、指示を待たずに使います。判定基準は複製せず、`.ai-playbook/review-workflow.md` と `.ai-playbook/task-playbooks/pr-review.md` を参照します。マージ直前の承認を機構で保証する PreToolUse フックは、このリポジトリではまだ配線していません（`.ai-playbook/role-contracts/closer.md`「手動承認は機構で保証する」）。配線するまでは、マージ実行の承認は利用者の手動判断に留まります。
- `.claude/settings.json`: Claude Code のローカル設定（権限許可リスト等）です。`.gitignore` の対象で追跡せず、規範は定義しません。
