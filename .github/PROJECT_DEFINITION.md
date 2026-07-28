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
bash scripts/check-neutrality.sh
```

検査対象と除外条件は `scripts/check-neutrality.sh` が持つ。CI（`.github/workflows/ci.yml` の neutrality ジョブ）とローカルゲート（`scripts/acceptance.sh`）も同じスクリプトを呼ぶため、ここに条件を書き写さない。

期待結果:
- 終了コード 0。ユーザー明示承認の例外がない限り、1 件も出力されないこと。
- 何か出力された場合、その行が中立性違反であり、終了コードは 1 になる。

同じスクリプトを次の 2 か所も呼ぶ。判定は 3 か所で常に同一になる。

- `.github/workflows/ci.yml` の `neutrality` ジョブ
- `scripts/acceptance.sh` の `(neutrality)` 検査（`bash scripts/verify.sh` から実行される）

**検査対象・除外条件を変更する場合は `scripts/check-neutrality.sh` だけを直す。** 呼び出し側は条件を持たないため、追随作業は発生しない。以前は 3 か所へ条件を書き写しており、片方だけが古くなる事故が実際に起きた。

除外の理由（条件そのものはスクリプトのコメントを参照）:

- `tests/` を除外する: 配布されない層であり、「生成物に固有名詞が残らないこと」を検証する都合上、検査対象語をリテラルで持つ必要があるため。
- `ojos/devcontainer-bootstrap` / `ojos/ai-playbook` を除外する: 配布物が自身の公開リポジトリ名（取得元）として持つ必要があるため。

## 開発運用

- 開発運用の規則は `.github/project-ai-rules.md` を参照する。
- Git フックによるワークフロー強制は行わない。
