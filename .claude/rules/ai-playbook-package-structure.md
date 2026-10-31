---
paths:
  - ".ai-playbook/**"
---

> 生成物: 正本 `.ai-playbook/shared-ai-rules.md` から生成したものです。編集は正本へ行ってください（ここを直しても、作り直しで消えます）。
> 本文の相対リンクは、このファイルからではなく `.ai-playbook/` からの相対です。

## 14. 構成

この表は、パッケージ直下の実体をすべて列挙します。ファイルを追加・削除・改名した場合は、この表を同一コミットで更新します。

| 対象 | 場所 |
|---|---|
| 共通規範（この文書） | `shared-ai-rules.md` |
| ロール責務 | `role-contracts/` |
| タスク手順 | `task-playbooks/` |
| レビュー運用 | `review-workflow.md` |
| ループ運用の規範（機械ゲート化・verify ランナー契約・収束） | `loop-workflow.md` |
| ループ運用の解説ガイド（`loop-workflow.md` の解説版） | `loop-coding-guide.md` |
| intake 規律・判定根拠 | `intake/` |
| 導入用の雛形 | `templates/` |
| パッケージ自身の説明・導入手順（規範ではない） | `README.md` |
| このパッケージを開発するときの追跡除外設定（規範ではない） | `.gitignore` |

配布経路による差分:

- 規範ファイル（`*.md`）だけを取り込む経路では、`README.md` と `.gitignore` は取り込まれません。どちらも規範ではないためです。取り込み先の追跡除外は、取り込み先の `.gitignore` で管理します。
- 取り込み側の機構が、取り込んだ版を記録するファイル（例: `VERSION`）をパッケージ直下へ生成する場合があります。これは本パッケージの構成要素ではありません。

0 章の 3 層構造は、`templates/` の雛形を次のとおり配置することで配線できます。

| 雛形 | 配置先 |
|---|---|
| `templates/project-ai-rules.md` | `.github/project-ai-rules.md`（2 層目: プロジェクト共通ルール） |
| `templates/entry.md` | 実行環境ごとの入口ファイル（例: `CLAUDE.md`, `AGENTS.md`, `.github/copilot-instructions.md`）（3 層目） |
| `templates/claude-agent-*.md` | 委譲先エージェント定義（実行環境が読む位置。`model` / `tools` を機構で固定する） |

`README.md` を取り込まない経路（上記）でも、この表だけで 3 層構造を配線できます。

## 15. 非目標

- この文書でモデル固有の最適化指示を定義しない。
- この文書でロール固有の責務を定義しない（`role-contracts/` の責務）。
- 実行環境固有の操作手順は runtime entry 側で最小差分として扱う。
- 状態面・実行基盤・ベンダーの選択を強制しない。
