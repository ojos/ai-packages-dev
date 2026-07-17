# docs カタログ

このファイルは `docs/` 配下のドキュメント一覧と用途を示す索引です。

## 収録ルール

- `docs/` 配下の追跡対象ファイルを全件列挙する。
- ローカル除外（`.git/info/exclude` 等）でリポジトリに含まれないファイルは列挙しない。
- ファイル追加・削除・改名時は、このファイルを同一コミットで更新する。

## ファイル一覧

| ファイル | 概要 |
|---|---|
| `docs/ASF_RETIREMENT_RECORD.md` | ASF を廃止し dotfiles / DCB へ統合した退役の判断根拠と実施記録。 |
| `docs/RELEASE_EXECUTION_RUNBOOK.md` | リリース実行時の運用手順書。 |
| `docs/RELEASE_HISTORY.md` | リリース履歴の正本。現行世代（v0.1.0〜）と旧世代の要約メモ。 |
| `docs/release-notes-ai-playbook.md` | ai-playbook リリースノート（新世代）。 |
| `docs/release-notes-devcontainer-bootstrap.md` | DCB リリースノート（新世代）。 |
| `docs/CATALOG.md` | `docs/` 配下の索引（本ファイル）。 |

## アーカイブ（`docs/archive/`）

旧世代配布（〜2026-07-17 のリポジトリ再作成前）の記録。参照のみで更新しない。

| ファイル | 概要 |
|---|---|
| `docs/archive/RELEASE_PROCESS_RECORD.md` | 旧世代リリース作成の構造的な問題と決着した論点の記録。 |
| `docs/archive/RENAME_TO_AI_PLAYBOOK_PLAN.md` | 規範パッケージ改名（dotfiles → ai-playbook）の計画記録（実施済み）。 |
| `docs/archive/release-notes-devcontainer-bootstrap.md` | DCB 旧世代（v0.1.15〜v0.3.1）のリリースノート。 |
