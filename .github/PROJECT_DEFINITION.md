# Project Definition (ojos-ai-packages-dev)

このファイルは、プロジェクト固有の最上位定義です。
This file is the project-specific source of truth.

## 非交渉ポリシー / Non-negotiable Policy

- `packages/**` 配下のパッケージコードには、プロジェクト固有の固有名詞を追加しない。
- Do not add project-specific proper nouns into package code under `packages/**`.
- 禁止対象の例: ユーザー名、組織名、リポジトリ名、アカウント別名、顧客名。
- Examples of forbidden package-level proper nouns: user names, org names, repository names, account aliases, and customer names.
- パッケージの既定値は汎用・再利用可能に保つ。
- Keep package defaults generic and reusable.
- 固有値が必要な場合は、プロジェクト層ファイルにのみ配置する（例: `.devcontainer/**`、ルート設定、ローカル環境変数）。
- If project-specific values are needed, put them in project layer files only (for example `.devcontainer/**`, root-level runtime config, or local environment variables).

## GitHub プロファイル規則 / GitHub Profile Rule

- Dev Container 生成時は bootstrap オプションを使う: `--github-profiles <csv>`
- For Dev Container generation, use the bootstrap option: `--github-profiles <csv>`.
- `packages/devcontainer-bootstrap/**` の既定値へ、プロファイル名をハードコードしない。
- Do not hard-code profile names into package defaults in `packages/devcontainer-bootstrap/**`.
- 本プロジェクトでは `bascule,ojos` をプロジェクト層でのみ使用する。
- This project currently uses profile names `bascule,ojos` at the project layer only.

## AI 変更時の安全規則 / Safety Rule for AI Changes

- パッケージファイルを変更する前に、固有名詞が混入しないことを確認する。
- Before changing package files, verify that no project-specific proper noun is introduced.
- リクエストがこの方針と衝突する場合、パッケージ編集前に必ずユーザーへ確認する。
- If a request conflicts with this policy, stop and ask the user before editing package files.

## ドキュメント言語方針 / Documentation Language Policy

- 本リポジトリの主要ドキュメントは、原則として日英併記を推奨する。
- For major documents in this repository, Japanese-English bilingual text is recommended.
- 実働上の規範文は英語を保持し、日本語は同義の補足として併記する。
- Keep normative statements in English for operational consistency, and add equivalent Japanese text for readability.
- 日英で意味をずらさない。更新時は両言語を同時に更新する。
- Keep Japanese and English semantically aligned, and update both together.

### ドキュメント形式の使い分け

**規範文書（指示・ポリシー層）:**  
- 形式: 1ファイル内で日英併記  
- 位置: `.github/` 配下  
- 理由: AI解釈のズレを避けるため、同一コンテキストで両言語を保持  

**利用ガイド（パッケージドキュメント層）:**  
- 形式: 言語別に分離（`README.md` = 英語正本 / `README.ja.md` = 日本語）  
- 位置: `packages/**/` 配下  
- 理由: トークン効率と読みやすさ、翻訳運用性のため  
- 正本: 英語（`README.md`）を正本として扱う  
- 同期: 更新時は英語更新後に日本語を追随させる（同時更新必須）

## クイック検証 / Quick Verification

ポリシー影響のある変更をコミット前に、次を実行する。
Use this check before committing policy-sensitive changes:

```bash
rg -n "bascule|ojos" packages/
```

期待結果 / Expected result:
- ユーザー明示承認の例外がない限り、`packages/` 配下で一致しないこと。
- No matches unless explicitly approved by the user for a package-level exception.
