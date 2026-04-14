# Project Definition (ojos-ai-packages-dev)

このファイルは、プロジェクト固有の最上位定義です。
This file is the project-specific source of truth.

> 汎用ルール（言語方針・命名規則・packages構造・ASFワークフロー規則）は以下に移管済み。
> Generic rules (language policy, naming convention, packages structure, ASF workflow) have been moved to:
> - `dotfiles/ai/common/shared-ai-rules.md` — ドキュメント言語方針・命名規則
> - `packages/agent-swarm-framework/template-project/files/.github/PROJECT_DEFINITION.md` — packages構造・ASFワークフロー規則

## このプロジェクト固有の値 / Project-specific Values

### GitHub プロファイル / GitHub Profiles

- 本プロジェクトで使用するプロファイル名: `bascule,ojos`
- This project uses profile names `bascule,ojos` at the project layer only.

### クイック検証 / Quick Verification

ポリシー影響のある変更をコミット前に、次を実行する。
Use this check before committing policy-sensitive changes:

```bash
rg -n "bascule|ojos" packages/
```

期待結果 / Expected result:
- ユーザー明示承認の例外がない限り、`packages/` 配下で一致しないこと。
- No matches unless explicitly approved by the user for a package-level exception.
