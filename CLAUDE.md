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
- `.claude/skills/land/SKILL.md`: `/land` の起動点です。この会話で PR を作ったら、指示を待たずに使います。判定基準は複製せず、`.ai-playbook/review-workflow.md` と `.ai-playbook/task-playbooks/pr-review.md` を参照します。マージ直前の承認は `scripts/confirm-merge-hook.sh`（`.claude/settings.json` の PreToolUse フックとして配線済み）が機構で保証します（`.ai-playbook/role-contracts/closer.md`「手動承認は機構で保証する」）。
- `.claude/settings.json`: 追跡しています（`.gitignore` は `!.claude/settings.json` で再包含。#312）。マージの確認フック（`scripts/confirm-merge-hook.sh`）とセッション協調フック（`scripts/session-coord-hook.sh`）の配線を持ちます。権限許可リストは持たず（追跡しない `settings.local.json` 側）、規範は定義しません。

## 規範の取り込み

次の 2 行で、規範の全文を毎セッションの文脈へ取り込みます（Claude Code の `@パス` の取り込み。#441）。パスを挙げるだけでは、エージェントが自分から読みにいかない限り規範が文脈に載りません。

@.ai-playbook/shared-ai-rules.md
@.github/project-ai-rules.md
