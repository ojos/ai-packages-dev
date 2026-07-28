# プロジェクト共通 AI ルール

このリポジトリは、パッケージ中立性を厳密に維持します。

## 参照先

- 全体共通ルール: `.ai-playbook/shared-ai-rules.md`
- プロジェクト固有の最上位定義: `.github/PROJECT_DEFINITION.md`
- ロール責務: `.ai-playbook/role-contracts/`
- タスク手順: `.ai-playbook/task-playbooks/`
- レビュー運用: `.ai-playbook/review-workflow.md`
- ループ運用（受け入れ検証の機械ゲート化・収束）: `.ai-playbook/loop-workflow.md`
- intake 規律・判定根拠: `.ai-playbook/intake/`

実行環境の入口ファイル（`CLAUDE.md` / `.github/copilot-instructions.md`）はこのファイルを参照し、最小差分のみを記述します。

## 常時適用

- `.github/PROJECT_DEFINITION.md` をプロジェクト固有の最上位定義として読み、必ず従います。
- 汎用ルール（言語方針・命名規則）は `.ai-playbook/shared-ai-rules.md` を参照します。
- 利便性のための編集よりも、上記ポリシーを優先します。
- `packages/**` に固有名詞を混入し得る編集は、ユーザー確認なしで実施しません。

## 必須挙動

- パッケージ層（`packages/**`）は汎用・再利用可能に保ちます。
- 固有値はプロジェクト層ファイルにのみ配置します。
- Dev Container の環境差は、パッケージ既定値の変更ではなく、プロジェクト層（`.env` / `.devcontainer/`）の設定で吸収します。ホスト OS の資格情報を運ぶ生成時オプションは廃止済みで、指定すると `bootstrap.sh` が停止します（`--github-profiles` / `--gemini-key-env`）。
- 主要ドキュメント更新時は、日本語での一貫性を維持します。

## このプロジェクト固有の値

固有値の正本は `.github/PROJECT_DEFINITION.md` です。値をこのファイルへ複製しません。

- パッケージ中立性のクイック検証コマンドと期待結果: `.github/PROJECT_DEFINITION.md`「クイック検証（パッケージ中立性）」。同じ判定は `.github/workflows/ci.yml` の `neutrality` ジョブと `scripts/acceptance.sh` の `(neutrality)` 検査が持ちます。
- git identity の値（`GIT_IDENTITY_NAME` / `GIT_IDENTITY_EMAIL`）: `.env`（下記「Git identity」）。
- Git フックによるワークフロー強制は行いません。push 前のゲートは `scripts/loop-gate.sh`、リモート側は CI と `.github/workflows/` の各ワークフローが担います。

## 機密の具体化

共通規範「機密の取り扱い」（`.ai-playbook/shared-ai-rules.md`）を、このリポジトリで具体化します。

- 機密の読み取り元: `.env`（`scripts/load-project-env.sh` が読み込む）、および GitHub CLI の認証情報
- 追跡除外: `.env` および `.env.*`（`.gitignore` 済み）
- 共有する雛形: 値のない `.env.example` のみ
- ホスト OS の資格情報をコンテナへ注入しません。`devcontainer.json` の `remoteEnv` が運ぶのは `LOCAL_WORKSPACE_FOLDER` のみで、CI の `Self devcontainer credential isolation` ジョブがこれを検査します
- GitHub の認証はコンテナ内で `gh auth login` を実行し、状態は `gh-storage` volume に残します。トークンを**私たちが**ファイルや環境変数へ保存しません（gh 自身は `~/.config/gh/hosts.yml` に保持します。それを volume の外へ写さない、という意味です）
- リリース実行時、シークレットの値をリリース資産へ含めません

## 生成物の具体化

共通規範「生成物の取り扱い」（`.ai-playbook/shared-ai-rules.md`）を、このリポジトリで具体化します。

コミットしない生成物:

- 依存・ビルド成果物・キャッシュ（`node_modules/`、`dist/`、`coverage/` など）。列挙の正本は `.gitignore` の DCB 管理セクション（`# >>> devcontainer-bootstrap managed section >>>` 〜 `# <<< devcontainer-bootstrap managed section <<<`）です。
- 機密ファイル `.env` / `.env.*`（`.env.example` のみ追跡。上記「機密の具体化」）
- ローカル引き継ぎメモ `GETTING_STARTED.md`（ワークスペースには残すがコミットしない）
- Claude Code のローカル設定 `.claude/*`（`.claude/skills/` のみ再包含して追跡します。スキルはローカル設定ではなく規範の配布物のため）

再生成手順:

- `.gitignore` の管理セクション: `packages/devcontainer-bootstrap/bootstrap.sh` が管理セクションのみを冪等に書き換えます（抑止は `--no-gitignore`、テンプレート追加は `--gitignore-targets`）。管理セクション外の記述は手で管理します。
- `.env`: `.env.example` を複製し、値を各自が設定します
- AI CLI（`gemini` 等）: `bash scripts/install-ai-tools.sh`

再生成できる大容量の生成物・メディアはリポジトリへ置きません。共有が必要な場合はリポジトリ外の手段を使います。

## Git identity（コミット作者情報）

`ojos/*` リポジトリへのすべての git 操作（commit / tag / リリーススクリプト内の一時クローン含む）は、次の identity で行います。

- `user.name` = `.env` の `GIT_IDENTITY_NAME`（= `Ido`）
- `user.email` = `.env` の `GIT_IDENTITY_EMAIL`（= `ido@ojos.jp`）

順守事項:

- global の identity には依存しません。`scripts/setup-git-identity.sh` が global の `user.name` / `user.email` を削除し、`user.useConfigOnly=true` を立てます。Dev Container はホストの `~/.gitconfig`（別アカウントの identity の場合がある）をコピーするため、そこへ落ちる経路を残しません。
- コンテナ接続時に `scripts/on-attach.sh` が `setup-git-identity.sh` を再適用します（リビルドのたびに ~/.gitconfig が再生成されるため）。`bash scripts/setup-git-identity.sh --check` で状態を検証できます。
- local 設定を持たないリポジトリでは `git commit` が exit 128 で止まります。これは設計どおりです。黙って別名義のコミットが通るより、止まって気づくほうを選びます。
- リポジトリ外の一時クローンでコミットするスクリプトは、`git -c user.name=... -c user.email=...` で identity を明示します（`scripts/release-packages.sh`）。CI の `Self devcontainer credential isolation` ジョブが明示を検査します。
- push / リリース実行の前に `bash scripts/verify-commit-identity.sh` で作者情報を検証します。別 identity を検出した場合は中断し、`bash scripts/setup-git-identity.sh` を適用したうえで該当コミットを `git rebase` で author ごと作り直します。単発の目視確認には `git log -1 --format='%an <%ae>'` を使います。

### commit identity の検証層

判定ロジックは `scripts/verify-commit-identity.sh` に置き、CI と手元で同じコードを走らせます。手元で先に落とせるようにするためです。

```bash
bash scripts/verify-commit-identity.sh              # 既定: origin/main..HEAD（取得できなければ HEAD の全履歴）
bash scripts/verify-commit-identity.sh <range>      # 任意の範囲
bash scripts/verify-commit-identity.sh --full       # HEAD の全履歴
```

- 終了コード 0 = `IDENTITY_PASS` / 1 = `IDENTITY_FAIL`（許可外の identity を検出、または範囲・許可 email を解決できない）。
- 判定は名前ではなく **email** で行います（GitHub の Contributors は既定ブランチのコミット author の email で集計されるため）。対象は author / committer / `Co-Authored-By` の 3 つです。
- committer には `noreply@github.com` を、`Co-Authored-By` にはさらに `noreply@anthropic.com` を追加で許可します（squash merge / web UI コミット、および AI コーディング規約の trailer に対応）。
- 許可 author email の解決順は、`ALLOWED_AUTHOR_EMAILS`（カンマまたは空白区切り）→ `.env` の `GIT_IDENTITY_EMAIL`。どちらでも解決できない場合は「検査対象が無いので通過」にせず、fail-closed で落とします。
- CI の検知層は `.github/workflows/identity-guard.yml` です。`pull_request`（`opened` / `synchronize` / `reopened`）では PR に含まれる全コミットを、`push`（`main`）では main の全履歴を検査します。PR を経由しない直接 push こそが混入の原因なので、後者を省略しません。
- 許可 email は生成物へ焼き込まず、**リポジトリ変数** `ALLOWED_AUTHOR_EMAILS`（Settings > Secrets and variables > Actions > Variables）で渡します。CI には `.env` が無いため、これを設定しないと identity-guard は fail-closed で必ず失敗します。

## GitHub 認証（gh CLI）

gh CLI の認証はコンテナ内で行い、その状態を named volume に残します。ホスト OS からトークンを持ち込みません。

順守事項:

- 認証は `gh auth login` をコンテナ内で 1 度実行します。状態は `gh-storage` volume（`/home/vscode/.config/gh`）に残り、リビルドを跨いで有効です。
- `GH_TOKEN` / `GITHUB_TOKEN` を恒久的に設定しません。gh に登録済みのアカウントより優先され、コンテナ内のログイン状態が無視されるためです。
- git の push 認証は `scripts/setup-git-identity.sh` が global の `credential.helper` を「空 → `!gh auth git-credential`」に固定して gh へ向けます。空文字がヘルパー一覧をリセットするため、`/etc/gitconfig` 側やエディタが注入したヘルパーは応答しません。
- `gh auth status` が失敗した場合は、コンテナ内で `gh auth login` をやり直します。ホスト側の環境変数を触る必要はありません。
- Docker レジストリの資格情報も同様です。ホスト側 VS Code で `dev.containers.dockerCredentialHelper: false` を設定してください。`scripts/on-attach.sh` が接続ごとに `~/.docker/config.json` の `credsStore` と `credHelpers` の両方を除去します（前者はレジストリ横断、後者はレジストリ個別にホストのヘルパーを指すため、片方だけでは塞がりません）。ただし書き込み順序によっては間に合わないため、ホスト側の設定が本体で、この除去は多層防御の 1 枚です。

## 作業状況の記録先

共通規範「作業状況の記録」を、このリポジトリで具体化します。

- 未完了の作業と完了の履歴: GitHub の issue / PR を正とします
- 完了の記録には、クローズ理由と検証結果を含めます（下記「Issue クローズ方針」）
- 単一ファイルへの状況集約は行いません。並列実行時のコンフリクトを避けるためです

## 外部サービスの状態管理

共通規範「外部サービスの状態管理」を、このリポジトリで具体化します。

- 対象の外部状態: 公開リポジトリ（`ojos/*`）、GitHub Release、タグ
- 宣言・適用の手段: `scripts/release-packages.sh`。ソースの反映・タグ付け・Release 作成を冪等に行い、公開済みバージョンの再公開を preflight で拒否します（不変性）
- 手動 `gh` / `git push` は状態確認・調査に留めます。リリースの恒久的操作はスクリプトを通します
- やむを得ず手動で公開状態を変えた場合は、スクリプト側の前提（README の固定バージョン等）へ後追いで反映します
- IaC ツール（Terraform 等）は現状使用しません。GitHub の状態はスクリプトで宣言的に扱います

## レビューの起動方法

共通規範「レビューワークフロー」（`.ai-playbook/review-workflow.md`）のクロスモデル二段ゲートと、「ループ運用」（`.ai-playbook/loop-workflow.md`）のローカル事前ゲートを、このリポジトリで具体化します。

push / PR 作成の前に、次の 3 段を通します。

1. **主レビュー**: Claude Code の `/code-review`（セキュリティに関わる差分は `/security-review` も）でステージ済み差分をレビューし、その場で修正します。
2. **受け入れ検証**: `scripts/verify.sh` が受け入れ条件を機械判定します。
3. **第二意見**: 別ベンダーのモデル（`scripts/gemini-review.sh`）でクロスチェックします。

2 と 3 は**単一入口** `scripts/loop-gate.sh` が直列化します。push / PR 作成の前にこれを通します。

```bash
bash scripts/loop-gate.sh
```

- 終了コード 0 = `GATE_PASS`（push 可） / 1 = `GATE_FAIL`（いずれかの段が未通過、または実行不能）。
- 第二意見コマンドは環境変数 `LOOP_GATE_REVIEW_CMD` で差し替え（任意のコマンド）・無効化（空文字）できます。未設定のときは `scripts/gemini-review.sh` があれば実行し、無ければスキップします。
- ステージ済み差分が空のときは、`loop-gate.sh` が第二意見の対象を commit 済み範囲へ自動で切り替えます（上流ブランチ → `origin/HEAD` / `origin/main` / `origin/master` → 空ツリー の順に解決）。commit 後にゲートを回すと第二意見が実質スキップされ、偽の緑が出るためです。
- 両段（主レビュー・第二意見）とも対象は致命バグ・脆弱性・型エラー・エッジケースの見落としに限ります。修正は 1 イテレーションで完結させます。

### 受け入れ検証（verify / acceptance）

```bash
bash scripts/verify.sh
```

- 終了コード 0 = `VERIFY_PASS` / 1 = `VERIFY_FAIL`（未達、または受け入れ条件が未定義）。
- 受け入れ条件の実体は `scripts/acceptance.sh`（プロジェクトが所有・編集します）。環境変数 `VERIFY_ACCEPTANCE` で差し替えられます（例: `VERIFY_ACCEPTANCE=scripts/acceptance-fast.sh bash scripts/verify.sh`）。
- `scripts/acceptance.sh` は `.github/workflows/ci.yml` の 5 ジョブを完全ミラーします。「ローカルが緑なら CI も緑」を保つための構成で、部分ミラーは採りません。
- **`ci.yml` を変更したら `scripts/acceptance.sh` も同じ内容へ追随させます。** 追随漏れを機械で検知する仕組みは無く、食い違うとローカルゲートは CI の予行演習でなくなります。

### 第二意見（クロスモデル）

```bash
bash scripts/gemini-review.sh                      # ステージ済み差分
bash scripts/gemini-review.sh --range main..HEAD   # 範囲指定
bash scripts/gemini-review.sh --runs 3             # 実行回数
```

| オプション | 環境変数 | 既定 | 意味 |
|---|---|---|---|
| `--range <git-range>` | — | ステージ済み差分 | レビュー対象の差分範囲 |
| `--model <name>` | `GEMINI_REVIEW_MODEL` | `gemini` CLI の既定 | 使用モデル |
| `--runs <n>` | `GEMINI_REVIEW_RUNS` | `1` | 実行回数（1 以上の整数。不正値は実行前に停止） |

- 優先順位は CLI 引数 > `.env` > 既定です。
- 判定は多数決です。指摘を報告した run が**過半数**（`floor(N/2)+1`）に達したときだけ落とします。既定の `1` では閾値も 1 で、従来と同じ挙動になります。
- 過半数に届かなかった指摘も出力に残ります。誤検出とは限らないため、内容を確認して採否を判断します。
- 終了コード 0 = `LGTM`（指摘を報告した run が閾値未満） / 1 = 重大な指摘あり、または実行不能。
- `GEMINI_API_KEY` が必要です（`scripts/load-project-env.sh` が `.env` から読み込みます）。`gemini` CLI は `scripts/install-ai-tools.sh` が導入します。
- このレビューは非決定的です。1 回の `LGTM` は重大な指摘が無いことの証明ではなく、主レビューを省略してよい根拠にもなりません。

### リモート最終ゲート

push / PR 作成後の最終ゲートを、このリポジトリで具体化します（`.ai-playbook/review-workflow.md`「リモート最終ゲート」）。

- 手段: `.github/workflows/copilot-review.yml` が、PR 作成時に `copilot-pull-request-reviewer[bot]` をレビュアーとして自動で要求します（`gh api --method POST repos/<repo>/pulls/<number>/requested_reviewers`）。
- **要求は 1 回だけ**: 契機を `pull_request` の `types: [opened]` に限定し、PR 更新（`synchronize`）では再要求しません。これが「1 回だけ」を運用者の記憶に頼らず機構で保証している実体です。
- **fork からの PR はスキップ**: `github.event.pull_request.head.repo.full_name == github.repository` のときだけジョブを実行します。fork の PR は書き込みトークンを持たないためです。
- **トークンのフォールバック**: `secrets.COPILOT_REVIEW_TOKEN || secrets.GITHUB_TOKEN`。既定の `GITHUB_TOKEN` で要求できない場合、リポジトリ Secrets に `COPILOT_REVIEW_TOKEN`（pull-requests 書き込み権限を持つ PAT）を設定すれば自動で切り替わります。
- **前提**: リポジトリ所有者の Copilot サブスクリプションで「Copilot code review」が有効であること。無効だと reviewers 要求が 422 で失敗します。
- 指摘の打ち切りは `.ai-playbook/review-workflow.md` の収束規則に従います。2 巡目以降の軽微な指摘は人間が却下し、AI 同士を往復させません。

### ドキュメント分離運用

- `packages/**/README.md` を正本として扱います。
- README は `README.md` を単一の正本として運用します。
- 翻訳版を追加する場合は、正本更新時に意味の一致を確認します。

### Issue 言語運用

- GitHub issue は日本語で統一します。
- 実装委譲 issue（`implementation:` / `feature:`）も日本語で統一します。
- 規範・判定基準・受け入れ条件は日本語で明確に記述します。

### AI からの質問運用

- AI からの確認事項は、一度に複数件を並べず、一問ずつ質疑応答で進めます。
- 各質問には、質問文と質問意図を必ずセットで示します。
- 回答は選択肢を優先して提示し、選択肢は推奨順に並べます。
- 選択肢の最後には、自由入力で答えられる欄を必ず用意します。

## 衝突時の扱い

- ユーザー意図とポリシーが衝突する場合、パッケージ編集前に焦点化した確認質問を行います。

## ディレクトリ構造テンプレート方針

- トップレベル構造（例: `src` / `docs` / `tests`）は推奨として扱います。
- 推奨構造は「新規生成時」に適用し、既存プロジェクトには強制しません。
- 既存プロジェクト適用時は既存ディレクトリ構造を優先し、非破壊で運用します。
- サブディレクトリ構造（`src/features` など）は細かく強制せず、オプションの推奨に留めます。
- 既定構造と異なる生成が必要な場合は、理由を明示して最小変更で対応します。

### 設定ウィザード

ディレクトリ構造テンプレートの設定は次のウィザードで作成します。

```bash
bash scripts/setup-ai-directory-policy.sh
```

出力先:

- `.github/ai-directory-policy.json`

運用モード:

- `recommended`: 推奨トップレベル構造を生成時に適用
- `reference-only`: 推奨を参照のみ（警告中心）

## 実装委譲パターン

実装作業は、独立して進められる単位へ分解し、サブエージェントへ委譲することを原則とします。

### 実装委譲の判定

**委譲対象**:
- 実装スコープが明記されている作業
- コード生成・変更を伴う作業（新規作成、既存コード修正）
- 独立して並列実行できる作業

**自分で実装してよい対象**:
- ドキュメント作成・編集（README、ガイド、方針文書など）
- 設計・意思決定作業（Q&A、分析、reason_code 定義など）
- 小規模テスト・検証（既存テスト実行、簡単な動作確認）
- ユーザーが明示的に直接実装を指示した場合

### ユーザーコマンド解釈

| コマンド | 意図 | エージェント動作 |
|---|---|---|
| 進めて下さい | 次フェーズへ | 委譲判定 →（サブエージェントまたは自実装） |
| やってしまえ | 直接実装する | 委譲をスキップして直接実装 |
| 確認して | 分析・レビューのみ | 委譲なしで実施 |
| #N を実装して | 特定 issue の実装 | Issue scope 確認後、委譲判定 |

### 並列実行時の作業分離

- 着手前にタスク間の依存関係を洗い出し、独立して進められる単位へ分割します。
- 実装を伴うサブエージェントへ並列委譲する場合、親セッションが `isolation: "worktree"` を指定し、機構でエージェント単位の作業ツリー分離を保証します。
- 指示文による呼びかけに頼りません。機構が結果そのものを生む場合は、機構を使います。
- 読み取り専用の調査エージェントには不要です。

### Issue クローズ方針

- Issue をクローズする際は、必ずクローズ理由をコメントで明示します。
- クローズ理由は `completed`, `superseded`, `duplicate`, `invalid`, `deferred` のいずれかに分類します。
- `superseded` / `duplicate` では置き換え先 issue 番号を明記します。
- 実装系 issue のクローズ時は、検証結果（テスト/実行結果）を最低1行含めます。

### 終了時整理方針

- 実行中は `issue:PR:merge` が一時的に 1:1:1 でなくても許容します。
- ただし作業終了時には、未採用 PR・実装済み Issue を必ず整理してクリーン状態へ戻します。
- 実装済み issue は理由と検証結果を付けてクローズします。
- 採用 PR はマージし、不要 PR は理由付きでクローズします。
- 終了前に open issue / open PR の状態を確認します。
- 最終判定の基準は「再開可能かつ追跡可能なクリーン状態」です。

### 運用厳格度方針

- `production` / `mainline` 向けの作業では、Issue 管理に milestone / GitHub Project の更新を必須とします。
- `spike` / `hotfix` / 小規模タスクでは、実行中の milestone / Project 更新は任意とします。
- 任意運用を選んだ場合でも、作業終了時には終了時整理方針に従って必ず正規化します。
- 途中の簡略運用を行った場合は、クローズ時コメントに「後追い正規化」の実施結果を明記します。

### エラーハンドリング

- Issue scope が不明確な場合: 委譲前にユーザーへ scope 確認を求めます。
- レビューの要否や判定に迷う場合: 独断で進めず、ユーザーへエスカレーションします。

## @intake コマンド

Intake Manager フローには 2 つの起動経路があります。

1. **明示起動**: ユーザーが `@intake` をメッセージ先頭に付けた場合、確認なしにフローを起動します。
2. **自動提案**: 要件らしい発話を検出した場合、エージェントが intake 化を提案し、ユーザーの承認を得てからフローを起動します。

### トリガー条件（明示起動）

- メッセージが `@intake` で始まる場合、直ちに起動します。

### トリガー条件（自動提案）

- 会話内容から、実装・変更を伴う「やりたいこと」（新機能／修正／設計変更 等）が具体的に述べられたと判断した場合、`@intake` が無くても intake 化を提案します。
- 提案は「これは要件定義（intake）として進めますか？」の 1 問に留め、選択肢を提示します（`.github/project-ai-rules.md` の質問運用に従う）。
- ユーザーが承認した場合のみ Step 1 以降へ進みます。直近のユーザー発話を要件テキストとして使用します。
- 承認されない場合は通常会話を継続し、フローには入りません。

### 提案しない条件（探索的会話の保護）

- 以下は要件確定を目的としないため、自動提案しません（探索的会話を妨げないため）:
  - 質問・調査・説明依頼・雑談
  - 既存コードの読解・レビュー・分析のみの依頼（「確認して」等）
  - 実現したいことが未確定で、対話で発散させている段階
- 一度提案して見送られた要件については、ユーザーの明確な再要求があるまで再提案しません（過剰提案の抑制）。
- 判断に迷う場合は、フローを起動せず提案に留めます。起動の可否はユーザーが決めます。

### 実行フロー

```
Step 1: 要件テキストの確定
  - @intake <テキスト> の形式なら、<テキスト> をそのまま使用
  - @intake のみで要件テキストがない場合、要件を対話で引き出す
  - 自動提案から承認された場合、承認の根拠となった直近のユーザー発話を要件テキストとして使用する

Step 2: 意図の解釈・確認（インプット確認）
  - 入力テキストの内容を解釈し、以下をユーザーに提示して確認する:
      - 解釈した目的（何を実現したいか）
      - 想定する変更の範囲・種別（新機能/修正/設計変更 等）
      - 不明点があれば質問する
  - ユーザーが「合っている」と確認するまで次へ進まない

Step 3: 設計妥当性の相談（条件付き）
  - 以下のいずれかに該当する場合のみ相談を起動する:
      - 設計方針に曖昧さ・矛盾がある
      - スコープ境界が不明確（何が in/out か判断できない）
      - 責務・型契約に影響する懸念がある
      - 優先順位の判断が難しい
  - 上記に該当しない場合はスキップしてよい
  - 相談の結論は goal / scope.in / acceptance に反映してから次へ進む
  - 進行と記録は consult-facilitator ロール契約に従う

Step 4: intake 票の下書き
  - .ai-playbook/intake/intake-template.md の必須構造を埋める
  - 必須: goal / scope.in / acceptance / priority
  - 任意: scope.out / constraints

Step 5: intake 確認ブロックをユーザーに提示・確認
  - goal / scope.in / scope.out / acceptance / priority をチャット上で表示
  - ユーザーが修正・承認するまで次へ進まない

Step 6: 計画整合性レビュー（必須）
  - 確認ブロックの内容に対して以下を審査する:
      - goal と acceptance の整合性（acceptance が goal を検証できるか）
      - scope.in と scope.out の境界が明確か
      - acceptance が検証可能な形式か（曖昧な完了条件を検出する）
      - acceptance が「非対話で実行でき、合否が終了コードで判定できる」形か
        （ループコーディングの入口要件。少なくとも 1 つの実行可能な検証を持つか。
         .ai-playbook/loop-workflow.md「前提: 完了条件は機械が検証できる形にする」）
      - 依存関係・前提条件の漏れがないか
  - 矛盾・漏れを発見した場合は指摘内容を提示し、Step 5 へ差し戻す
  - acceptance が機械判定できる形に達しない場合の扱い:
      - 原則は Step 5 へ差し戻し、機械判定できる acceptance を再定義する。
      - 本質的に機械判定を持てない作業（例: 純粋な設計相談・ドキュメント合意）は、
        「ループコーディング非対象」であることを intake 票に明記した上で通過してよい。
        この場合、完了は人の判断で確定し、自律反復のループには載せない。
  - 問題がなければ「レビュー通過」を明示してから次へ進む

Step 7: 最終意図確認（実行前ゲート）
  - issue 化の直前に、以下を要約してユーザーへ確認する:
      - 作成予定の issue タイトルと内容サマリー
      - 「この内容で進めてよいか？」を明示的に確認する
  - ユーザーが承認するまで issue を作成しない

Step 8: ユーザー承認後に issue 化

Step 9: 実装委譲へ移行
  - issue 作成完了後、「実装委譲パターン」へ引き継ぐ
```

### 制約

- Step 7（ユーザー承認）なしに issue を作成してはなりません。
- intake の要否判定と、その根拠の分類は `.ai-playbook/intake/REASON_CODES.md` に従います。
- intake-manager の権限境界（`.ai-playbook/role-contracts/intake-manager.md`）に従います。
- intake はループコーディングの入口フェーズを担います。ループ対象の作業は、Step 6 で機械判定できる acceptance を確定してから実装委譲へ移します（`.ai-playbook/loop-workflow.md`）。ループ非対象と判定した作業は、その旨を intake 票に明記します。
