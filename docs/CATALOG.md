# docs カタログ

このファイルは `docs/` 配下のドキュメント一覧と用途を示す索引です。

## 収録ルール

- `docs/` 配下の追跡対象ファイルを全件列挙する。
- ローカル除外（`.git/info/exclude` 等）でリポジトリに含まれないファイルは列挙しない。
- ファイル追加・削除・改名時は、このファイルを同一コミットで更新する。

## 分類方針

2 軸で分類する。

- **状態**: `現行`（参照・更新する正本）／ `アーカイブ`（旧世代・参照のみで更新しない、`docs/archive/`）。
- **種別**: `索引` / `運用手順` / `履歴・記録` / `リリースノート` / `計画`。種別はディレクトリで表す（`release/`・`records/`・`plans/`）。

## 現行

### 索引（`docs/`）

| ファイル | 概要 |
|---|---|
| `docs/CATALOG.md` | `docs/` 配下の索引（本ファイル）。 |

### リリース（`docs/release/`）

運用手順・履歴・リリースノートなどリリース系の正本。

| ファイル | 種別 | 概要 |
|---|---|---|
| `docs/release/RELEASE_EXECUTION_RUNBOOK.md` | 運用手順 | リリース実行時の運用手順書。 |
| `docs/release/RELEASE_HISTORY.md` | 履歴・記録 | リリース履歴の正本。現行世代（v0.1.0〜）と旧世代の要約メモ。 |
| `docs/release/release-notes-ai-playbook.md` | リリースノート | ai-playbook リリースノート（新世代）。 |
| `docs/release/release-notes-devcontainer-bootstrap.md` | リリースノート | DCB リリースノート（新世代）。 |

### 記録（`docs/records/`）

完了済みの意思決定・実施記録の正本。

| ファイル | 種別 | 概要 |
|---|---|---|
| `docs/records/ASF_RETIREMENT_RECORD.md` | 履歴・記録 | ASF を廃止し dotfiles / DCB へ統合した退役の判断根拠と実施記録。 |
| `docs/records/INTAKE_AUTO_SUGGEST_LOOP_RECORD.md` | 履歴・記録 | `@intake` の自動提案経路追加と、intake をループコーディング入口として機械判定ゲート化した判断根拠と実施記録。 |

### 計画（`docs/plans/`）

これから着手する作業の仕様・計画。進捗の正本は issue / PR。実装完了後は `docs/records/` へ移動または archive 化する。

| ファイル | 種別 | 概要 |
|---|---|---|
| `docs/plans/DCB_RUST_SUPPORT.md` | 計画 | DCB の `--languages` へ rust を追加する仕様・作業計画。 |
| `docs/plans/DCB_MODE_REMOVAL_WITH_FLAGS.md` | 計画 | DCB の `--mode` を廃止し装備を `--with-*` フラグ（cloud/AI ツール）へ分解する仕様・作業計画。 |

## アーカイブ（`docs/archive/`）

旧世代配布（〜2026-07-17 のリポジトリ再作成前）の記録。参照のみで更新しない。

| ファイル | 種別 | 概要 |
|---|---|---|
| `docs/archive/RELEASE_PROCESS_RECORD.md` | 履歴・記録 | 旧世代リリース作成の構造的な問題と決着した論点の記録。 |
| `docs/archive/RENAME_TO_AI_PLAYBOOK_PLAN.md` | 履歴・記録 | 規範パッケージ改名（dotfiles → ai-playbook）の計画記録（実施済み）。 |
| `docs/archive/release-notes-devcontainer-bootstrap.md` | リリースノート | DCB 旧世代（v0.1.15〜v0.3.1）のリリースノート。 |
