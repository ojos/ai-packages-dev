# Project Definition (ojos-ai-packages-dev)

このファイルは、プロジェクト固有の最上位定義です。

> 汎用ルール（言語方針・命名規則）は以下に移管済み。
> - `.ai-playbook/shared-ai-rules.md` — ドキュメント言語方針・命名規則
>
> packages 構造・運用規則は `.github/project-ai-rules.md` を参照。

## このプロジェクト固有の値

### クイック検証（パッケージ中立性）

ポリシー影響のある変更をコミット前に、リポジトリルートで次を実行する。

```bash
! grep -rniE 'bascule|ojos' packages/ .ai-playbook/ \
  --include='*.sh' --include='*.md' --include='*.json' --exclude-dir=tests \
  | grep -v 'ojos/devcontainer-bootstrap' \
  | grep -v 'ojos/ai-playbook'
```

期待結果:
- 終了コード 0。ユーザー明示承認の例外がない限り、1 件も出力されないこと。
- 何か出力された場合、その行が中立性違反であり、終了コードは 1 になる。

この判定は次の 2 か所と同一である。いずれかを変更したら、残りも同じ内容へ追随させる。

- `.github/workflows/ci.yml` の `neutrality` ジョブ
- `scripts/acceptance.sh` の `(neutrality)` 検査（`bash scripts/verify.sh` から実行される）

検査対象と除外の理由:

- 検査対象は `packages/`（配布パッケージ層）と `.ai-playbook/`（配布規範層）の `*.sh` / `*.md` / `*.json`。
- `tests/` を除外する: 配布されない層であり、「生成物に固有名詞が残らないこと」を検証する都合上、検査対象語をリテラルで持つ必要があるため。
- `ojos/devcontainer-bootstrap` / `ojos/ai-playbook` を除外する: 配布物が自身の公開リポジトリ名（取得元）として持つ必要があるため。

## 開発運用

- 開発運用の規則は `.github/project-ai-rules.md` を参照する。
- Git フックによるワークフロー強制は行わない。
