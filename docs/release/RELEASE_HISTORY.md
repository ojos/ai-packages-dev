# リリース履歴（正本）

配布リポジトリの世代と公開バージョンの正本です。過去の詳細記録は [archive/](../archive/) に保存しています。

## 現行世代（正本）

2026-07-17 に配布リポジトリ 2 つを削除・同名再作成し、クリーンな履歴で v0.1.0 から配布をやり直しました。
**現行の正本はこの世代の v0.1.0 以降です。**

| パッケージ | リポジトリ | 現行バージョン | 配布形態 |
|---|---|---|---|
| devcontainer-bootstrap | `ojos/devcontainer-bootstrap` | v0.7.0 | GitHub Release + 3 資産 |
| ai-playbook | `ojos/ai-playbook` | v0.1.3 | git タグのみ |

### 新世代の版更新

| パッケージ | 版 | 公開日 | 要点 |
|---|---|---|---|
| devcontainer-bootstrap | v0.7.0 | 2026-07-27 | **破壊的変更**。生成物からホスト資格情報の注入経路（`remoteEnv` の `${localEnv:...}`）を全廃し、認証をコンテナ内で行い named volume で永続化する構造へ移行（#129）。`--github-profiles` / `--gemini-key-env` と `GITHUB_TOKEN_*` 等の環境変数契約を撤去（#130）、永続 volume を gh/aws/gcloud へ拡張し実マウントを検査（#131）、所有権修復を `fix-mount-owner.sh` へ独立（#132）、credsStore 打ち消し・identity の `.env` 化・`credential.helper` の gh 固定・`.env.example` 追加（#133 / #141） |
| devcontainer-bootstrap | v0.6.0 | 2026-07-26 | 生成物に git identity ガード（適用・検証・CI の 3 層。#108）、プロジェクト `.env` 優先読み込み（#109）、`--with-claude` での Claude intake 起点スキル配置（#111）、`--with-copilot` でのリモート最終ゲート雛形配置（#113）、tmux 常時同梱（#115）を追加。あわせて `acceptance.sh` の生成既定を「存在する対象だけ検証し 0 件なら失敗」へ変更（**軽微な破壊的変更**。#112） |
| ai-playbook | v0.1.3 | 2026-07-26 | `REASON_CODES.md` に軽微修正の免除条件を追加（#110）、`review-workflow.md` のリモート最終ゲートを「1 回に限定される機構なら自動要求可」へ緩和し `templates/copilot-review.yml` を新設（#113）、Claude Code 向け intake 起点スキル雛形 `templates/claude-skill-intake.md` を追加し 8 章へ固定ファイル名の例外を追記（#111）、`templates/project-ai-rules.md` のレビュー節に loop-gate 単一入口とリモート最終ゲート欄を追加（#114）、`templates/gemini-review.sh` を `.env` ローダーへ追随（#109） |
| devcontainer-bootstrap | v0.5.1 | 2026-07-22 | 取り込んだ ai-playbook の出所を生成先 `.ai-playbook/VERSION` に記録（後方互換）。書き込みは規範と同じ衝突ポリシーに従う（自己診断 F-7） |
| ai-playbook | v0.1.2 | 2026-07-22 | 入口雛形 `templates/entry.md` から「導入時の調整」節を削除（生成物へのメタ指示残置を解消。自己診断 F-6） |
| devcontainer-bootstrap | v0.5.0 | 2026-07-22 | **破壊的変更**。Claude 認証を OAuth トークン注入から作業前 `/login` 既定へ変更（`--claude-token-env` / `CLAUDE_CODE_OAUTH_TOKEN` 自動注入を廃止）。あわせて AI ツール永続 volume の `root:root` 所有によるログイン不能を修正（`fix_owner` を postCreate に追加） |
| devcontainer-bootstrap | v0.4.2 | 2026-07-21 | バグ修正: playbook 取得失敗時に部分生成せず書き込み前にアトミック停止。`--playbook-version` の `v` 抜けヒント |
| devcontainer-bootstrap | v0.4.1 | 2026-07-21 | `--playbook-version <tag>` 追加（URL 冗長の解消）。ソース指定時は `--with-playbook` 省略可 |
| devcontainer-bootstrap | v0.4.0 | 2026-07-21 | **破壊的変更**。`--mode` を廃止し装備を `--with-*`（cloud/AI ツール）へ分解。docker 標準化・AI 永続化の mode 非依存化・自動導入廃止 |
| devcontainer-bootstrap | v0.3.1 | 2026-07-21 | ループコーディング支援（`verify.sh` / `acceptance.sh` / `loop-gate.sh`）を生成に追加。`--with-playbook` 取得元を ai-playbook v0.1.1 へ更新 |
| ai-playbook | v0.1.1 | 2026-07-21 | ループコーディング規範 `loop-workflow.md` / `loop-coding-guide.md` を追加、既存規範を追随更新 |

> 注: 新世代 DCB は v0.1.0 で初回公開後、v0.2.0 / v0.3.0 / v0.3.1 / v0.4.0 / v0.4.1 / v0.4.2 / v0.5.0 / v0.5.1 を経て v0.6.0 に至る（README のバージョン固定が正本）。v0.4.0 は `--mode` 廃止、v0.5.0 は Claude 認証 login-first 化の破壊的変更。v0.5.1 は非破壊の機能追加（playbook 出所記録）。v0.6.0 は機能追加（identity ガード / `.env` 優先読み込み / Claude skill / Copilot 雛形 / tmux）に加え `acceptance.sh` 生成既定の軽微な破壊的変更を含む。

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
