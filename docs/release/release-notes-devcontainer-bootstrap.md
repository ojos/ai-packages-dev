# devcontainer-bootstrap Release Notes

新世代（2026-07-17 リポジトリ再作成後）のリリースノートです。旧世代（〜v0.3.1）は [archive/release-notes-devcontainer-bootstrap.md](../archive/release-notes-devcontainer-bootstrap.md) を参照。

## Unreleased

### Summary
- 開発補助として `tmux`（`ghcr.io/devcontainers-extra/features/tmux-apt-get:1`）を、`ripgrep` と同様に**常時同梱**するようにした（後方互換の機能追加。装備フラグ `--with-*` には追加しない。issue #115）。
- `--with-copilot` 選択時のみ、リモート最終ゲートの雛形を `.github/workflows/copilot-review.yml` として配置するようにした（後方互換の機能追加。雛形は規範パッケージが持ち、DCB は配置先だけを決める。issue #113）。
- 生成する `scripts/acceptance.sh` の既定を「**ルート直下にマニフェストが存在する対象だけ検証し、1 つも実行できなければ失敗する**」形へ変更した（軽微な破壊的変更。生成される既定内容が変わる。issue #112）。
- プロジェクト固有 `.env` を「ホスト由来の環境変数（`remoteEnv`）より後勝ちで上書き」で読み込む層を生成物へ追加した（後方互換の機能追加。issue #109）。
- 生成物に git identity ガード（適用・検証・CI の 3 層）を追加し、local 未設定リポジトリが黙って global へフォールバックしてコミットを通す経路を塞いだ（後方互換の機能追加。生成ファイルが増える。issue #108）。
- `--with-claude` 指定かつ規範導入時に、Claude Code 向け intake 起点スキルを `.claude/skills/intake/SKILL.md` へ配置するようにした（後方互換の機能追加。`--with-claude` 指定時に生成ファイルが 1 つ増える。issue #111）。

### Highlights
- **tmux の常時同梱（#115）**: `devcontainer.json` の features に `tmux` を追加した。既に開発補助として `ripgrep` を常時同梱している前例に整合させ、装備フラグ `--with-*`（cloud/AI ツール）へは入れない（`--mode` 廃止時に整理した `--with-*` の意味論を広げないため）。`devcontainers-extra` 名前空間は `ripgrep` で既に使用しており、新たな依存先は増えない。生成される `devcontainer.json` は妥当な JSON を保つ。
- **リモート最終ゲート雛形の配置（#113）**: `--with-copilot` を選び、かつ規範（playbook）を配置する構成のときだけ、規範パッケージの `templates/copilot-review.yml` を `.github/workflows/copilot-review.yml` へコピーする。`--with-copilot` 未指定、または規範を配置しない構成では置かない。DCB は内容を持たず配置先だけを決める（正本は規範パッケージ）。ワークフローは PR 作成時（`pull_request: types: [opened]`）に一度だけ Copilot へレビューを要求し、`synchronize` では再要求しないため「1 回だけ」を機構で保証する。フォークからの PR はスキップし、トークンは `COPILOT_REVIEW_TOKEN || GITHUB_TOKEN` へフォールバックする。既存ファイルには既存の衝突ポリシー（`skip`/`overwrite`/`prompt`）に従う。`--dry-run` の plan 出力にも copilot 選択時のみ含める。
- **acceptance.sh のマニフェスト検出ガード（#112）**: 生成する `scripts/acceptance.sh` を、選択言語ごとに**ルート直下のマニフェスト**（`node`→`package.json`、`go`→`go.mod`、`python`→`pyproject.toml`/`requirements.txt`、`php`→`composer.json`、`rust`→`Cargo.toml`）の実在を確認してから慣習的テストを実行する形へ変更した。マニフェストが無い言語は理由を出して**スキップ**し失敗させない。マニフェストはあるがツールが無い場合は**導入手順を添えて非 0 で終了**する（「スキップ」と「実行できなかった」を混同しない）。`ran_any` ガードで、1 つも検証を実行できなければ「受け入れ条件が未定義」と出力して**非 0 で終了**する（全スキップで誤って緑になり、検証していないことを合格と報告する事故を防ぐ）。スクリプト位置からルートを解決し、起動時 CWD に依存しない。従来はどこにマニフェストが無くても選択言語のテストコマンドを無条件に直列実行していたため、monorepo・未実装段階で生成直後が必ず「テストが無くて赤い」状態になっていた。新しい既定でも生成直後は赤いままだが、「受け入れ条件が未定義だと明示して落ちる」に変わり、失敗メッセージで受け入れ条件の定義を促せる。`verify.sh` は本 issue のスコープ外で変更しない。
- **プロジェクト `.env` の優先読み込み（#109）**: 中立名の `scripts/load-project-env.sh` を常時生成する。`.env` を **`source` せず** `KEY=VALUE` のみ安全にパースして `export` するため、任意コードを実行しない（壊れた `.env` が対話シェルの初期化ごと落とす事故を防ぐ）。CWD 非依存でスクリプト位置から `.env` を解決し、bash / zsh の双方で動作する。CRLF・`export KEY=VALUE`・`KEY = VALUE`・クォート囲みを吸収し、冪等。`PROJECT_ENV_FILE` で対象ファイルを差し替え可能。生成される `scripts/on-attach.sh` が `~/.bashrc` / `~/.zshrc` へマーカー付きで**冪等に**注入し、対話シェルから起動する CLI（`gemini` 等）にも `.env` の値を効かせる（rc 不在なら `touch` で作成、参照は絶対パス）。
- **git identity ガード（#108）**: `scripts/setup-git-identity.sh` を追加。global の `user.name` / `user.email` を削除して `user.useConfigOnly=true` を立て、local 未設定リポジトリでの `git commit` を exit 128 で停止させる。当リポジトリの local には先頭 profile（`--github-profiles` の 1 つ目）の `GIT_AUTHOR_*_<PROFILE>` を適用する。冪等で `--check` が状態を検証し、`credential.helper` は壊さない。`scripts/on-attach.sh` が毎接続で再適用する（VS Code の `copyGitConfig` がリビルドごとに `~/.gitconfig` を再生成するため）。**失敗しても on-attach 全体は落とさず**、WARN と手動確認コマンドの案内に留める。
- **git identity 検証（#108）**: `scripts/verify-commit-identity.sh` を追加。コミット履歴の identity を **email のみ**で検証する（CI と手元で共用）。許可 author email は環境変数 `ALLOWED_AUTHOR_EMAILS` を最優先し、無ければ先頭 profile の `GIT_AUTHOR_EMAIL_<PROFILE>` へフォールバック。どちらも無ければ fail-closed。committer は `noreply@github.com`、Co-Authored-By は加えて `noreply@anthropic.com` を許可。`.github/workflows/identity-guard.yml` を追加し、`pull_request` と `push`(main) の 2 系統で検証を強制する。許可 author email は生成物に焼き込まず、利用側のリポジトリ変数 `ALLOWED_AUTHOR_EMAILS`（`vars.ALLOWED_AUTHOR_EMAILS`）から渡す。判定はシェル側にあり、ワークフローは呼ぶだけ。利用側は GitHub の **Settings → Secrets and variables → Actions → Variables** に `ALLOWED_AUTHOR_EMAILS` を設定する（README「Git identity ガード」参照）。
- **Claude intake 起点スキルの配置（#111）**: `--with-claude` を選び、かつ規範（ai-playbook）を導入する場合に限り、`.claude/skills/intake/SKILL.md` を配置する。雛形の内容は DCB では持たず、規範パッケージの `templates/claude-skill-intake.md` を `require_playbook_template` で要求して置くだけにする（内容の正本を 1 つに保ち、規範側の更新に追随させる）。Claude Code の機構がスキル定義ファイル名を `SKILL.md` に固定するため、`lower-kebab-case` の雛形名から改名して配置する。`--with-claude` を指定しない、または規範を導入しない場合は `.claude/` を生成しない。雛形を持たない古い ai-playbook をソースにすると、書き込み前に `require_playbook_template` が失敗する。配置は既存の衝突ポリシー（`--playbook-conflict-policy`）に従い、`--dry-run` の plan 出力にも含める。

### Breaking Changes
- **軽微（#112）**: 生成される `scripts/acceptance.sh` の既定内容が変わる。既存の生成物は衝突ポリシー（`skip`/`overwrite`/`prompt`）により上書きされないため、再生成しない限り影響しない。
- その他はなし（後方互換の機能追加）。git identity ガードで生成ファイルが 3 つ増え、`--with-claude` 指定時にさらに `.claude/skills/intake/SKILL.md` が 1 つ増える。既存の生成物に対しては既存の衝突ポリシー（`skip`/`overwrite`/`prompt`）に従う。

### Verification
- [ ] preflight 全通過（DCB テストスイート、`test-env-loader.sh` / `test-git-identity.sh` を含む全ファイル green、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.5.1

### Summary
- 取り込んだ ai-playbook の出所を、生成先の `.ai-playbook/VERSION` に記録するようにした（後方互換の機能追加）。

### Highlights
- `--playbook-version` などでバージョンを指定しても、生成後の環境に「どの版の playbook を取り込んだか」の on-disk 証跡が残らず、後から照合できなかった（devcontainer 自己診断 F-7）。
- 規範を配置するとき `.ai-playbook/VERSION` を生成し、`version`（`--playbook-version` のタグ。未指定は `(unspecified)`）と `source`（解決済みソース。隣接チェックアウトは `<adjacent checkout>`）を `key=value` で記録する。`--dry-run` の plan 出力にも含める。
- 書き込みは規範ファイルと同じ衝突ポリシー（`skip`/`overwrite`/`prompt`）に従う（`apply_file_with_policy` を再利用）。既存を `skip` した on-disk 規範を温存したまま `VERSION` だけ無条件上書きすると、記録が実際の規範とずれて出所が嘘になるため。

### Breaking Changes
- なし（後方互換の機能追加）。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.5.0

### Summary
- Claude 認証を OAuth トークン注入から作業前 `/login` 既定へ変更（**破壊的変更**）。
- AI ツール永続 volume の所有権を修正し、`/login` 不能を解消（バグ修正）。

### Breaking Changes
- `--with-claude` の生成物で `remoteEnv` へ `CLAUDE_CODE_OAUTH_TOKEN` を**無条件注入する挙動を廃止**。OAuth トークンは権限スコープが限定されフルスペック操作が許可されないため、作業前に `/login` する方式を既定にした。`~/.claude` は named volume で永続するため、一度 `/login` すればリビルドをまたいで有効。
- `--claude-token-env` フラグ / `CLAUDE_TOKEN_ENV` 変数 / `__CLAUDE_TOKEN_ENV__` の sed 置換を除去。
- CI 等でトークン運用が必要な場合は、生成された `.devcontainer/devcontainer.json` の `remoteEnv` へ手動で 1 行追記する（手順は README に記載）。

### Fixes
- AI ツール用の永続 named volume（`claude-storage:/home/vscode/.claude` 等）を空の状態で初回マウントすると、マウントポイントを Docker デーモン（root）が `root:root` で作成するため、`remoteUser`（vscode）が書き込めず AI CLI のログイン/設定書き込みが失敗していた。
- `postCreateCommand`（`install-ai-tools.sh`）に `fix_owner` を追加し、選択した AI ツールの設定ディレクトリの所有者が現ユーザーと異なる場合のみ `sudo chown -R` で復旧する（冪等）。`sudo` 不在・`chown` 失敗のいずれも `set -euo pipefail` 下で postCreate を止めず、WARN を出して CLI 導入まで到達させる。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.4.2

### Summary
- playbook 取得失敗時に devcontainer を部分生成してから遅延失敗する不具合を修正（バグ修正）。

### Fixes
- 存在しないタグ（例: `--playbook-version` の `v` 抜け）や URL の 404、壊れたアーカイブでも、従来は devcontainer を全ファイル書き込んでから `no rule files found` で失敗していた。README が約束する「取得元が解決できなければ 1 つも書き込まず終了」に反していた。
- 原因は `detect_playbook_dir` が `curl` / `tar` の失敗を明示検査せず `set -e` に依存していたが、`PLAYBOOK_DIR="$(...)"` の代入コマンド置換では `set -e` が発火しないこと。`curl` / `tar` の明示検査、代入コマンド置換の終了コード捕捉、規範 0 件の書き込み前検査で**アトミックに停止**するよう修正。
- `--playbook-version` 使用時の取得失敗には `v` 接頭辞のヒント（例: `v0.1.1`）を表示。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.4.1

### Summary
- ai-playbook ソース指定の使い勝手を改善（後方互換の追加）。

### Highlights
- `--playbook-version <tag>` を追加。既定ソース `ojos/ai-playbook` のタグ tarball（`.../archive/refs/tags/<tag>.tar.gz`）へ内部展開し、長い URL を打たずに版だけで指定できる。`--playbook-from` とは相互排他。
- ソース（`--playbook-from` / `--playbook-version`）を指定した場合、`--with-playbook` を省略しても規範を配置する。判定順は「明示 opt-out（`--without-playbook`）> 明示 opt-in（`--with-playbook`）> ソース指定あり」。

### Breaking Changes
- なし。`--playbook-from` 単体は従来「無視」だったが「配置」になる（silent no-op の解消）。`--without-playbook` は最優先で従来どおり配置しない。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.4.0

### Summary
- `--mode <minimal|standard|full>` を廃止し、装備を `--with-*` フラグへ分解した**破壊的変更**。

### Highlights
- `--mode` 廃止（未知オプションとしてエラー）。3 mode 別テンプレを 1 つのパラメータ化テンプレへ集約し重複を解消。
- docker のリッチさ（buildx + compose-switch）を全生成物で標準化。
- cloud: `--with-aws` / `--with-gcp` を追加。Terraform はいずれかの cloud 指定時に暗黙同梱（両指定でも 1 回、cloud 無指定なら無し）。
- AI ツール: `--with-claude` / `--with-gemini` / `--with-copilot` を追加。トークンによる自動導入を廃止し明示 opt-in のみ。各フラグは CLI + VS Code 拡張 + 設定の永続化（compose named volume）を同型で実施。
- AI 認証の永続化を mode 非依存化（旧 full 限定を撤廃）。
- `doctor.sh` に cloud CLI（aws/gcloud/terraform）可用性検査を追加。

### Breaking Changes
- **`--mode` を削除**。旧 `--mode standard` は概ね `--with-aws`、旧 `--mode full` は `--with-aws --with-gcp --with-claude --with-gemini --with-copilot` に相当。移行対応表は DCB README「mode オプションからの移行」を参照。
- AI CLI（claude/gemini）の**トークンによる自動導入を廃止**。今後は `--with-<ai>` の明示指定が必要。
- docker のリッチさが全生成物で標準になったため、旧 `minimal` 相当でも buildx 等が入る。

### 予定（未実装）
- `--with-codex`（OpenAI Codex）/ `--with-sakura`（さくらのクラウド）/ `--with-cloudflare`（Cloudflare）は拡張点の枠のみ。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.3.1

### Summary
- ループコーディング支援の実行体を生成に追加。全モードで生成し、外部パッケージの導入を前提にせず単体で動作する。

### Highlights
- 生成物に `scripts/verify.sh`（受け入れ条件を非対話実行し一意な通過信号 `VERIFY_PASS` を返す接地信号）、`scripts/acceptance.sh`（プロジェクト所有の受け入れ条件。選択言語の慣習的テストコマンドを既定配置）、`scripts/loop-gate.sh`（push / PR 前のローカル事前ゲート。`verify.sh` と任意の第二意見レビューを直列化）を追加。
- `doctor.sh` がループスクリプト 3 種の存在・構文・実行権限を検査。
- README に「ループコーディング支援」節を追加。ワークフローの正本は ai-playbook の `loop-workflow.md` / 解説は `loop-coding-guide.md` を参照。`--with-playbook` の取得元を ai-playbook `v0.1.1` へ更新。

### Breaking Changes
- なし（後方互換の機能追加）。

### Verification
- [ ] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [ ] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）

## v0.1.0

### Summary
- 配布リポジトリをクリーンな履歴で再作成した、新世代の初回リリース。

### Highlights
- 機能は旧世代最終版（v0.3.1）の内容をすべて含む: `--with-playbook --playbook-from <ai-playbook タグ tarball>`、`.ai-playbook/` 配置、GitHub archive 形式の構造検出、`.env` 自動読み込み、アカウント自動選択フォールバック。
- 履歴・タグ・Release を新規に作成。コミット作者情報は `Ido <ido@ojos.jp>` に統一。

### Breaking Changes
- 旧世代のタグ（v0.1.15〜v0.3.1）と Release の固定 URL は無効。取得手順の `TAG` を `v0.1.0` へ更新する。

### Verification
- [x] preflight 全通過（DCB テストスイート、README / 規範のリンク検査、バージョン不変性）
- [x] 資産監査 OK（`RELEASE-MANIFEST.json` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz` / `bootstrap.sh` / `doctor.sh`）
- [x] コミット作者・コントリビューターが単一 identity であることを確認
