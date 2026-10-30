---
paths:
  - "packages/**"
  - ".ai-playbook/**"
  - "scripts/*.sh"
---

# パッケージ層の運用

地図（`.github/project-ai-rules.md`）の「常時適用」の詳細です。パッケージ層を汎用に保つこと、`packages/**` へ固有名詞を入れないことは地図が常時持ちます。

## ドキュメント分離運用

- `packages/**/README.md` を正本として扱います。
- README は `README.md` を単一の正本として運用します。
- 翻訳版を追加する場合は、正本更新時に意味の一致を確認します。

## scripts/*.sh の正本

`scripts/*.sh` のうち DCB（`packages/devcontainer-bootstrap`）が生成するものの正本は、`packages/devcontainer-bootstrap/bootstrap.sh` 内のヒアドキュメントです。`scripts/` 側だけを書き換えると、生成物と食い違います（詳細は `packages/devcontainer-bootstrap/README.md` の `get_template_content()` の節）。`tests/test-template-mirror.sh` が両者のバイト一致を照合します。
