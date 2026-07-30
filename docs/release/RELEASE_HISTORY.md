# リリース履歴（正本）

配布リポジトリの世代と公開バージョンの正本です。過去の詳細記録は [archive/](../archive/) に保存しています。

## 現行世代（正本）

2026-07-17 に配布リポジトリ 2 つを削除・同名再作成し、クリーンな履歴で v0.1.0 から配布をやり直しました。
**現行の正本はこの世代の v0.1.0 以降です。**

| パッケージ | リポジトリ | 現行バージョン | 配布形態 |
|---|---|---|---|
| devcontainer-bootstrap | `ojos/devcontainer-bootstrap` | v0.8.0 | GitHub Release + 資産 5 点（配布スクリプト 2: `bootstrap.sh` / `doctor.sh`、生成物 3: `SHA256SUMS` / `RELEASE-MANIFEST.json` / `PACKAGE_ARCHIVE.tar.gz`） |
| ai-playbook | `ojos/ai-playbook` | v0.1.6 | git タグのみ |

### 新世代の版更新

| パッケージ | 版 | 公開日 | 要点 |
|---|---|---|---|
| devcontainer-bootstrap | v0.8.0 | 2026-07-30 | `--languages` に **`ruby` を第 6 の選択肢として追加**した（#206）。既存 5 言語と同等の生成・検査・診断・文書体験を提供する。`ghcr.io/devcontainers/features/ruby:1` を feature として配線し、`.gitignore` へ `Ruby` テンプレートを取り込み、`doctor.sh` と生成物 `post-rebuild-check.sh` の検査対象に含め、選択時のみ `Shopify.ruby-lsp` を配線する。`ruby` は feature 名と実行ファイル名が一致するため `rust`→`cargo` のような写像分岐は持たない。acceptance は Minitest / RSpec を決め打ちせず `bundle exec rake` で `Rakefile` の default タスクへ委譲する（マニフェストは `Gemfile`、ツール可用性は `bundle` で判定）。あわせて対応言語の README 追随漏れを機械で落とす**両方向の集合照合**を追加した（個別言語の取りこぼし検査は書いた言語しか守れないため）。後方互換 |
| ai-playbook | v0.1.6 | 2026-07-29 | 並列実装後の統合検証を規範へ追加した（#199）。レーン単体の受け入れ検証が緑でマージの衝突検査も無言のまま統合欠陥が残る構造（8 レーン並列で 3 件、3 レーン並列で 5 件の実測）に対し、統合ツリーで各レーンの受け入れ条件を再実行する工程を `review-workflow.md` へ明記。あわせて `shared-ai-rules.md` 12 章へ「文書が実装の一覧を書き写している箇所は実装の出力と機械照合できる形にする」判断軸を追加した。規範の追加のみで後方互換 |
| devcontainer-bootstrap | v0.7.4 | 2026-07-29 | 生成される `loop-gate.sh` で、**push 済みブランチ（HEAD == 上流）だと第二意見が一度も差分を見ないまま `GATE_PASS` になる**経路を塞いだ（#198）。v0.7.2 が塞いだ穴と同じ構造の残穴で、切り替え先の範囲が空になる場合を見ていなかった。範囲は「解決できたか」ではなく実際に差分があるかで選び、上流との差分が空なら既定ブランチの追跡枝との**分岐点**まで戻してブランチ全体を対象にする。分岐点まで戻しても差分が無い場合は `no reviewable diff` を明示したうえで通過する（空を一律 FAIL にすると差分の無い状態でのゲート実行が落ちる）。空ツリーへの後退は remote が無い場合に限定。後方互換 |
| devcontainer-bootstrap | v0.7.3 | 2026-07-28 | README と実装の乖離を解消（#170 / #171）。未記載だった `--dry-run` / `--force` / `-h`、実行前提コマンド、rust 対応を追加し、生成物一覧・doctor 節・リリース資産の説明を実装と一致させた。`bootstrap.sh` / `doctor.sh` の usage が開発リポジトリと公開配布物のどちらか一方でしか解決しないパスを示していた問題を修正（#174 / #182）。`LICENSE`（MIT）と `CHANGELOG.md` を配布物へ追加（#177）。**生成物への影響は `.ai-playbook/CHANGELOG.md` を取り込まなくなる 1 点のみ。** 後方互換 |
| ai-playbook | v0.1.5 | 2026-07-28 | **導入手順が新規プロジェクトで必ず失敗する不具合を修正**（#167。手順 2・4 の `cp` に `mkdir -p` が無かった）。配布先で解決しない参照を除去（#167）、構成表・命名規則・管理対象の自己不整合を解消（#168）、契約・雛形の内部不整合とベンダー中立違反を解消（#169）、`LICENSE`（MIT）と `CHANGELOG.md` を配布物へ追加（#177）。命名規則は分類定義のみ改め、**ファイル改名は行っていない**ため既存の取り込みは壊れない。後方互換 |
| devcontainer-bootstrap | v0.7.2 | 2026-07-27 | 生成される `loop-gate.sh` で、ステージ済み差分が空のときに第二意見が実質スキップされる経路を塞いだ（#152）。空のときだけ commit 済み範囲へ切り替える。既定ブランチ名は決め打ちせず、起点が無ければ空ツリーを使う（`HEAD` だと `git diff` が作業ツリー比較になり素通りが復活する）。git リポジトリでない場合は従来どおり引数なしで呼ぶ。**v0.7.1（#149）の内容を含む。** 後方互換 |
| devcontainer-bootstrap | v0.7.1（未公開） | — | **タグ未公開。v0.7.2 へ統合。** 生成される `verify-commit-identity.sh` で、許可 author email の解決からパス名展開（glob）を除去（#149）。クォートなしの配列代入により、許可 email に `*` / `?` が含まれると許可リストが検査対象リポジトリのファイル名で変わっていた。`read -r -a` へ改め、回帰テストで「ファイルの有無で判定が変わらないこと」を検証する。後方互換 |
| devcontainer-bootstrap | v0.7.0 | 2026-07-27 | **破壊的変更**。生成物からホスト資格情報の注入経路（`remoteEnv` の `${localEnv:...}`）を全廃し、認証をコンテナ内で行い named volume で永続化する構造へ移行（#129）。`--github-profiles` / `--gemini-key-env` と `GITHUB_TOKEN_*` 等の環境変数契約を撤去（#130）、永続 volume を gh/aws/gcloud へ拡張し実マウントを検査（#131）、所有権修復を `fix-mount-owner.sh` へ独立（#132）、credsStore 打ち消し・identity の `.env` 化・`credential.helper` の gh 固定・`.env.example` 追加（#133 / #141） |
| devcontainer-bootstrap | v0.6.0 | 2026-07-26 | 生成物に git identity ガード（適用・検証・CI の 3 層。#108）、プロジェクト `.env` 優先読み込み（#109）、`--with-claude` での Claude intake 起点スキル配置（#111）、`--with-copilot` でのリモート最終ゲート雛形配置（#113）、tmux 常時同梱（#115）を追加。あわせて `acceptance.sh` の生成既定を「存在する対象だけ検証し 0 件なら失敗」へ変更（**軽微な破壊的変更**。#112） |
| ai-playbook | v0.1.4 | 2026-07-27 | `templates/gemini-review.sh` に複数回実行と多数決を追加（#157）。第二意見は非決定的で、同一コミットへの 4 回の実行が LGTM 2 回・指摘あり 2 回に分かれた。`GEMINI_REVIEW_RUNS` で回数を増やし、指摘を報告した実行が過半数に達したときだけ落とす。既定 1 で従来と同一挙動。`review-workflow.md` へ「第二意見の非決定性」節を追加 |
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
