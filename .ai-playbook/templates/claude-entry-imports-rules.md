
## 規範の取り込み（Claude Code）

共通規範（`.ai-playbook/shared-ai-rules.md`）の全文は、ここから取り込みません。
`.claude/rules/ai-playbook*.md` が、共通規範を分けて載せます（正本から生成したもの。編集は正本へ行います）。
`paths:` の無い `ai-playbook.md` は起動時に必ず載り、`paths:` 付きの規則は、一致するファイルに触れたときだけ載ります。

次の 1 行で、プロジェクト共通ルールの全文を毎セッションの文脈へ取り込みます（Claude Code の `@パス` の取り込み）。

@.github/project-ai-rules.md
