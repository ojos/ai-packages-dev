# Project Definition (ojos-ai-packages-dev)

このファイルは、プロジェクト固有の最上位定義です。

> 汎用ルール（言語方針・命名規則）は以下に移管済み。
> - `.ai-playbook/shared-ai-rules.md` — ドキュメント言語方針・命名規則
>
> packages 構造・運用規則は `.github/project-ai-rules.md` を参照。

## このプロジェクト固有の値

### GitHub プロファイル

- 本プロジェクトで使用するプロファイル名: `bascule,ojos`

### クイック検証

ポリシー影響のある変更をコミット前に、次を実行する。

```bash
rg -n "bascule|ojos" packages/
```

期待結果:
- ユーザー明示承認の例外がない限り、`packages/` 配下で一致しないこと。

## 開発運用

- 開発運用の規則は `.github/project-ai-rules.md` を参照する。
- Git フックによるワークフロー強制は行わない。
