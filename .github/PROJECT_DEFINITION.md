# Project Definition (ojos-ai-packages-dev)

このファイルは、プロジェクト固有の最上位定義です。

> 汎用ルール（言語方針・命名規則・packages構造・ASFワークフロー規則）は以下に移管済み。
> - `dotfiles/ai/common/shared-ai-rules.md` — ドキュメント言語方針・命名規則
> - `packages/agent-swarm-framework/template-project/files/.github/PROJECT_DEFINITION.md` — packages構造・ASFワークフロー規則

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

## ASF 強制適用

- ASF ワークフロー遵守はローカル Git フックで自動強制される。
- `postAttachCommand` は、`core.hooksPath` が独自設定でない限り `scripts/gate/install-git-hooks.sh` を通じて `.githooks` を設定する。
- `pre-commit` と `pre-push` は、`bash scripts/asf-workflow.sh preflight`（または他の ASF サブコマンド）で更新される最新の ASF 実行マーカーを必須とする。

### 非IDE実行

- 非IDE環境（例: 通常のターミナル）では、clone ごとに `bash scripts/gate/install-git-hooks.sh` を1回実行し、commit/push 前に `bash scripts/asf-workflow.sh preflight` を実行する。
- 強制範囲は Git 操作（`pre-commit` と `pre-push`）であり、編集コマンド自体を直接ブロックするものではない。
