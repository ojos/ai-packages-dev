# scripts カタログ

このファイルは `scripts/` 配下の運用対象スクリプト一覧と用途を示す索引です。

## 収録ルール

- `scripts/` 配下の運用対象ファイルを列挙する。
- ファイル追加・削除・改名時は、このファイルを同一コミットで更新する。

## ファイル一覧（運用対象）

| ファイル | 概要 |
|---|---|
| `scripts/second-opinion-review.sh` | 別ベンダーのモデルによる第二意見（クロスモデル二段ゲートの2段目）。`--engine` で実行 CLI（gemini / antigravity）を選ぶ。 |
| `scripts/review-usable.sh` | リモート最終ゲート（`.github/workflows/review-gate.yml`）が、Copilot code review が要求・投稿されただけでなく実際に読めたかを判定する本体。正本は `.ai-playbook/templates/review-usable.sh`（`tests/test-review-usable.sh` が一致を担保）。 |
| `scripts/fix-mount-owner.sh` | 永続 volume のマウント先を remoteUser 所有へ戻す（postCreate の先頭）。 |
| `scripts/install-ai-tools.sh` | AI CLI ツール導入（claude / gemini は npm、agy は配布元のインストーラ）。あわせて agy のテレメトリを既定で無効化する。 |
| `scripts/load-project-env.sh` | プロジェクト .env を source せず安全にパースして export（ホスト env を後勝ちで上書き）。 |
| `scripts/on-attach.sh` | attach 時の初期化処理。 |
| `scripts/post-rebuild-check.sh` | リビルド後チェック。**手動実行専用**（`postCreateCommand` / `postAttachCommand` からは起動しない）。 |
| `scripts/release-packages.sh` | ai-playbook / DCB のリリース実行と監査（`--audit` は公開資産を再取得し SHA256 を再計算して整合性を検証する）。 |
| `scripts/audit-failure-notify.sh` | リリース資産監査の失敗通知。2 回連続の失敗でのみ issue を起票し、同じ失敗の open issue があればコメント追記に留める。 |
| `scripts/setup-git-identity.sh` | global identity の無害化と local identity 適用、credential.helper の gh 固定。 |
| `scripts/acceptance.sh` | このプロジェクトの受け入れ条件（`ci.yml` 5 ジョブ + `identity-guard.yml` の完全ミラー）。プロジェクトが所有・編集する。 |
| `scripts/check-neutrality.sh` | `packages/` と `.ai-playbook/` への固有名詞混入検査。検査対象・除外条件の正本で、CI・`acceptance.sh`・`PROJECT_DEFINITION.md` が共用する。 |
| `scripts/verify.sh` | `acceptance.sh` を非対話実行し、一意な通過信号（`VERIFY_PASS`）を返す接地信号。手前で `check-no-secrets.sh` を実行する。 |
| `scripts/check-no-secrets.sh` | 機密混入の検知ゲート（追跡前 / 追跡済みの 2 経路 + `.env.example` の機密値 + `.env` とのキー整合）。判定の正本で、`verify.sh` と CI が共用する。 |
| `scripts/check-control-chars.sh` | 追跡ファイルへの表示されない制御文字（C0 制御文字と DEL。TAB / LF / CR は除く）混入の検知ゲート。`acceptance.sh` が呼ぶ。 |
| `scripts/check-shell-portability.sh` | 「この環境では通るが BSD 系（macOS）では落ちる」綴りの検知ゲート。追跡している `*.sh` と `*.md`（フェンス内）を走査し、`# bsd-ok: 理由` を逃げ道とする。`acceptance.sh` が呼ぶ。 |
| `scripts/check-table-breaks.sh` | Markdown の表の途中へ段落が差し込まれ、続く行が表として描画されなくなっていないかの検知ゲート。`acceptance.sh` が呼ぶ。 |
| `scripts/loop-gate.sh` | push / PR 前のローカル事前ゲート。commit identity 検証・`verify.sh`・第二意見を直列化する単一入口（`GATE_PASS`）。 |
| `scripts/verify-commit-identity.sh` | コミット履歴の identity 検証（email のみで判定）。CI（identity-guard）と手元で共用。 |
| `scripts/update-release-status.sh` | README のリリース状況更新。 |
| `scripts/measure-agent-usage.sh` | サブエージェントの役割別トークン使用量を集計するレポート（合否判定はしない）。親セッションとサブエージェントの両方の記録を読み、全体内とサブエージェント内の 2 つの分母で比率を出す。 |
| `scripts/confirm-merge-hook.sh` | マージ実行の前に確認を挟む PreToolUse フック（`.claude/settings.json` から `--with-claude` 連動で配線）。`gh pr merge` / REST の merge エンドポイントへの PUT / `mergePullRequest` を検知し `ask` を返す。既定の merge 方針（手動承認）を、呼びかけではなく機構で担保する。 |
| `scripts/CATALOG.md` | `scripts/` 配下の索引（本ファイル）。 |
