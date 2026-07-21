# リリース履歴（正本）

配布リポジトリの世代と公開バージョンの正本です。過去の詳細記録は [archive/](../archive/) に保存しています。

## 現行世代（正本）

2026-07-17 に配布リポジトリ 2 つを削除・同名再作成し、クリーンな履歴で v0.1.0 から配布をやり直しました。
**現行の正本はこの世代の v0.1.0 以降です。**

| パッケージ | リポジトリ | 現行バージョン | 配布形態 |
|---|---|---|---|
| devcontainer-bootstrap | `ojos/devcontainer-bootstrap` | v0.4.2 | GitHub Release + 3 資産 |
| ai-playbook | `ojos/ai-playbook` | v0.1.1 | git タグのみ |

### 新世代の版更新

| パッケージ | 版 | 公開日 | 要点 |
|---|---|---|---|
| devcontainer-bootstrap | v0.4.2 | 2026-07-21 | バグ修正: playbook 取得失敗時に部分生成せず書き込み前にアトミック停止。`--playbook-version` の `v` 抜けヒント |
| devcontainer-bootstrap | v0.4.1 | 2026-07-21 | `--playbook-version <tag>` 追加（URL 冗長の解消）。ソース指定時は `--with-playbook` 省略可 |
| devcontainer-bootstrap | v0.4.0 | 2026-07-21 | **破壊的変更**。`--mode` を廃止し装備を `--with-*`（cloud/AI ツール）へ分解。docker 標準化・AI 永続化の mode 非依存化・自動導入廃止 |
| devcontainer-bootstrap | v0.3.1 | 2026-07-21 | ループコーディング支援（`verify.sh` / `acceptance.sh` / `loop-gate.sh`）を生成に追加。`--with-playbook` 取得元を ai-playbook v0.1.1 へ更新 |
| ai-playbook | v0.1.1 | 2026-07-21 | ループコーディング規範 `loop-workflow.md` / `loop-coding-guide.md` を追加、既存規範を追随更新 |

> 注: 新世代 DCB は v0.1.0 で初回公開後、v0.2.0 / v0.3.0 / v0.3.1 / v0.4.0 / v0.4.1 を経て v0.4.2 に至る（README のバージョン固定が正本）。v0.4.0 は `--mode` 廃止の破壊的変更。

- 再作成の理由: コミット作者情報に別アカウントが混入した痕跡を、GitHub 内部キャッシュも含め完全に除去するため。
- 新世代 v0.1.0 の機能は、旧世代の最終版（DCB v0.3.1 / 旧 ai-playbook v0.1.0）の内容をすべて含みます。
- **旧世代のタグ・Release・固定 URL・コミット SHA はすべて無効です。** 利用側は取得手順の `TAG` と固定 SHA を新世代へ更新してください。

## 旧世代の記録（メモ）

旧世代（リポジトリ作成 2026-04-09 〜 削除 2026-07-17）の公開バージョンの要約です。

### devcontainer-bootstrap（旧 v0.1.15 〜 v0.3.1）

| 版 | 公開日 | 要点 |
|---|---|---|
| v0.1.15 | 2026-04 | 初期安定ライン |
| v0.2.1 | 2026-07-14 | `.env` 自動読み込み、GitHub アカウント自動選択のフォールバック |
| v0.3.0 | 2026-07-16 | 規範パッケージ改名（dotfiles → ai-playbook）へ追随。`--with-playbook` / `.ai-playbook/` 配置 |
| v0.3.1 | 2026-07-16 | ai-playbook 配布 tarball の構造検出を修正（v0.3.0 のリグレッション） |

### ai-playbook（旧 v0.1.0）

| 版 | 公開日 | 要点 |
|---|---|---|
| v0.1.0 | 2026-07-16 | 初回公開。規範 18 件、タグのみ配布（Release・資産なし） |

### 旧世代で決着した設計原則（現行にも適用）

- 公開リポジトリ = 成果物置き場。CI / テスト / ビルドロジックを置かない（v0.2.1 の検証チェーン破壊の教訓）
- `SHA256SUMS` は利用者が実際にダウンロードするファイルのみを対象にする（`SUMS_TARGETS`）
- 公開済みバージョンは不変。やり直しは版を上げる
- リリースの恒久的操作は `scripts/release-packages.sh` を唯一の経路とする

詳細: [archive/RELEASE_PROCESS_RECORD.md](../archive/RELEASE_PROCESS_RECORD.md) /
[archive/release-notes-devcontainer-bootstrap.md](../archive/release-notes-devcontainer-bootstrap.md) /
[archive/RENAME_TO_AI_PLAYBOOK_PLAN.md](../archive/RENAME_TO_AI_PLAYBOOK_PLAN.md)
