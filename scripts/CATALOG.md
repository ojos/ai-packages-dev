# scripts カタログ

このファイルは `scripts/` 配下の運用対象スクリプト一覧と用途を示す索引です。

## 収録ルール

- `scripts/` 配下の運用対象ファイルを列挙する。
- ファイル追加・削除・改名時は、このファイルを同一コミットで更新する。

## ファイル一覧（運用対象）

| ファイル | 概要 |
|---|---|
| `scripts/second-opinion-review.sh` | 別ベンダーのモデルによる第二意見（クロスモデル二段ゲートの2段目）。`--engine` で実行 CLI（gemini / antigravity / codex）を選ぶ。 |
| `scripts/fix-mount-owner.sh` | 永続 volume のマウント先を remoteUser 所有へ戻す（postCreate の先頭）。 |
| `scripts/install-ai-tools.sh` | AI CLI ツール導入（claude / gemini は npm、agy は配布元のインストーラ）。あわせて agy のテレメトリを既定で無効化する。 |
| `scripts/load-project-env.sh` | プロジェクト .env を source せず安全にパースして export（ホスト env を後勝ちで上書き）。 |
| `scripts/on-attach.sh` | attach 時の初期化処理。 |
| `scripts/post-rebuild-check.sh` | リビルド後チェック。**手動実行専用**（`postCreateCommand` / `postAttachCommand` からは起動しない）。 |
| `scripts/release-packages.sh` | ai-playbook / DCB / devcontainer-host（`--host-version`。`dev.sh` と `dev-up@.service` を個別の資産として添付し、`dev.sh` へ版を書き込む）のリリース実行と監査（`--audit` は公開資産を再取得し SHA256 を再計算して整合性を検証する）。 |
| `scripts/audit-failure-notify.sh` | リリース資産監査の失敗通知。2 回連続の失敗でのみ issue を起票し、同じ失敗の open issue があればコメント追記に留める。 |
| `scripts/setup-git-identity.sh` | global identity の無害化と local identity 適用、credential.helper の gh 固定。 |
| `scripts/acceptance.sh` | このプロジェクトの受け入れ条件（`ci.yml` 8 ジョブ + `identity-guard.yml` の完全ミラー）。プロジェクトが所有・編集する。 |
| `scripts/check-neutrality.sh` | `packages/` と `.ai-playbook/` への固有名詞混入検査。検査対象・除外条件の正本で、CI・`acceptance.sh`・`PROJECT_DEFINITION.md` が共用する。 |
| `scripts/verify.sh` | `acceptance.sh` を非対話実行し、一意な通過信号（`VERIFY_PASS`）を返す接地信号。手前で `check-no-secrets.sh` を実行する。 |
| `scripts/check-no-secrets.sh` | 機密混入の検知ゲート（追跡前 / 追跡済みの 2 経路 + `.env.example` の機密値 + `.env` とのキー整合）。判定の正本で、`verify.sh` と CI が共用する。 |
| `scripts/check-control-chars.sh` | 追跡ファイルへの表示されない制御文字（C0 制御文字と DEL。TAB / LF / CR は除く）混入の検知ゲート。`acceptance.sh` が呼ぶ。 |
| `scripts/check-doc-links.sh` | 追跡している Markdown の相対リンクが、追跡対象として実在することの検知ゲート。`DOC_LINKS_EXCLUDE`（コロン区切りのパスプレフィックス）でスキャン対象の文書を除外できる。`acceptance.sh` が呼ぶ。 |
| `scripts/check-shell-portability.sh` | 「この環境では通るが BSD 系（macOS）では落ちる」綴りの検知ゲート。追跡している `*.sh` と `*.md`（フェンス内）を走査し、`# bsd-ok: 理由` を逃げ道とする。`acceptance.sh` が呼ぶ。 |
| `scripts/check-table-breaks.sh` | Markdown の表の途中へ段落が差し込まれ、続く行が表として描画されなくなっていないかの検知ゲート。`acceptance.sh` が呼ぶ。 |
| `scripts/check-release-commit-verified.sh` | 配ろうとしているコミットの CI が緑で完了しているかを、実行の一覧から決定的に判定する。`release.yml` が副作用へ到達する前に呼ぶ。標準入力を受けるだけで API は叩かない。 |
| `scripts/loop-gate.sh` | push / PR 前のローカル事前ゲート。commit identity 検証・`verify.sh`・第二意見を直列化する単一入口（`GATE_PASS`）。第二意見の出力は `second-opinion-record.sh` へ記録を残す。 |
| `scripts/second-opinion-record.sh` | 第二意見の生の出力を記録し、head SHA 付きの PR コメントとして投稿する。`loop-gate.sh` が push 前に呼ぶ。正本は `.ai-playbook/templates/second-opinion-record.sh`。 |
| `scripts/second-opinion-gate-exempt.sh` | 第二意見の記録を求めない PR（Dependabot 等）かを判定する本体。`.github/workflows/second-opinion-gate.yml` が呼ぶ。正本は `.ai-playbook/templates/second-opinion-gate-exempt.sh`（`tests/test-second-opinion-gate-exempt.sh` が表で確かめる）。 |
| `scripts/verify-commit-identity.sh` | コミット履歴の identity 検証（email のみで判定）。CI（identity-guard）と手元で共用。 |
| `scripts/verify-commit-identity-selftest.sh` | `verify-commit-identity.sh` の判定そのものを、仕込みのリポジトリで確かめる自己試験。`identity-guard.yml` / `acceptance.sh` が検証の前に呼ぶ。 |
| `scripts/check-repo-security.sh` | 脆弱性の報告と通知に関わるリポジトリ設定（Private vulnerability reporting・Dependabot alerts・security updates）が有効かを照合する。管理者権限のトークンが要るので CI には入れず、持ち主が手元で回す（`.github/project-ai-rules.md`「脆弱性の報告と通知」。`tests/test-check-repo-security.sh` が偽物の gh で確かめる）。 |
| `scripts/terraform-refuse-destroy.sh` | 公開リポジトリ（`github_repository`）を消す・作り直す Terraform の plan を、apply の前に落とす。`prevent_destroy` が外されたときの 2 枚目で、`.github/workflows/terraform.yml` の plan / apply が呼ぶ（`tests/test-terraform-refuse-destroy.sh` が偽物の terraform で確かめる）。 |
| `scripts/update-release-status.sh` | README のリリース状況更新。 |
| `scripts/measure-agent-usage.sh` | サブエージェントの役割別トークン使用量を集計するレポート（合否判定はしない）。親セッションとサブエージェントの両方の記録を読み、全体内とサブエージェント内の 2 つの分母で比率を出す。 |
| `scripts/confirm-merge-hook.sh` | マージ実行の前に確認を挟む PreToolUse フック（`.claude/settings.json` から `--with-claude` 連動で配線）。`gh pr merge` / REST の merge エンドポイントへの PUT / `mergePullRequest` を検知し `ask` を返す。既定の merge 方針（手動承認）を、呼びかけではなく機構で担保する。 |
| `scripts/session-coord-hook.sh` | 並行セッションの共有台帳を操作の直前に確かめる Claude Code 用フック（`--with-claude` 連動。SessionStart・PreToolUse の Bash と Edit\|Write・PostToolUse の Bash・SessionEnd から呼ぶ）。マージ・リリース、同じ作業ツリーでの git 操作、重いゲートの同時起動を拒否し、同じ issue への着手と他セッションが登録している文書の編集を警告する。台帳の不具合は警告して通す。このリポジトリも `.claude/settings.json` へ同じ配線を持つ（配線済み。`tests/test-claude-mirror.sh` が雛形との一致を検査する）。 |
| `scripts/session-peers.sh` | 同じプロジェクトで動くほかの Claude Code セッションの一覧（`list`）・宛先の解決（`resolve`。番号・名前・`#issue`・作業ツリー名から宛先名 1 件へ）・送信元の署名（`whoami`）。`~/.claude/sessions/*.json` を読み、同じ `pidDomain`・生きている PID・同じ `git-common-dir` のものだけを出す。json は公開された仕様ではないため、読めなければ警告して `ListAgents` を案内する。`--with-claude` 連動で、実行環境に依存しない `session-ledger.sh` とは分ける。呼び出し口は `/peers` スキル（`packages/devcontainer-bootstrap/tests/test-session-peers.sh` が確かめる）。 |
| `scripts/claude-session-wrapper.sh` | Claude Code のセッションの宛先名へ、場所と作業ツリーを自動で含める起動ラッパー（`--with-claude` 連動。VS Code の `claudeCode.claudeProcessWrapper` は、作業ツリーの外の起動役 `~/.local/bin/claude-session-launcher`（`on-attach.sh` が接続のたびに冪等に設置する。ラッパーが無ければ引数をそのまま exec する）に配線する）。`.env` の `SESSION_HOST_LABEL` があれば、`CLAUDE_CODE_SESSION_NAME` を `<ラベル>-<作業ツリー名>-<PID の 16 進>` にして `exec "$@"` する。ラベルなし・設定済み・計算の失敗では何も変えずに `exec "$@"` する（`packages/devcontainer-bootstrap/tests/test-claude-session-wrapper.sh` が確かめる）。 |
| `scripts/session-ledger.sh` | 同じホストで並行して動く AI セッションの共有台帳（claim / release / list / check）。置き場所は `git rev-parse --git-common-dir` の配下で、セッションごとに別ファイルへ追記する。衝突を種類ごとに警告・拒否として返し、持ち主の PID が消えた登録は失効させる。実行環境には依存しない（規範は `.ai-playbook/shared-ai-rules.md`「セッション間の協調」。`packages/devcontainer-bootstrap/tests/test-session-ledger.sh` が確かめる）。 |
| `scripts/CATALOG.md` | `scripts/` 配下の索引（本ファイル）。 |
