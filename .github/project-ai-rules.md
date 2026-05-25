# プロジェクト共通 AI ルール

このリポジトリは、パッケージ中立性を厳密に維持します。

## 常時適用

- `.github/PROJECT_DEFINITION.md` をプロジェクト固有の最上位定義として読み、必ず従います。
- 汎用ルール（言語方針・命名規則）は `dotfiles/ai/common/shared-ai-rules.md` を参照します。
- packages 構造・ASF ワークフロー規則の汎用雛形は `packages/agent-swarm-framework/template-project/files/.github/PROJECT_DEFINITION.md` を参照します。
- ASF 汎用運用規則（実装委譲、@intake、終了時整理、運用厳格度）の正本は上記 template-project 側とします。
- 利便性のための編集よりも、上記ポリシーを優先します。
- `packages/**` に固有名詞を混入し得る編集は、ユーザー確認なしで実施しません。

## 必須挙動

- パッケージ層（`packages/**`）は汎用・再利用可能に保ちます。
- 固有値はプロジェクト層ファイルにのみ配置します。
- Dev Container のプロファイル名対応では、パッケージ既定値変更ではなく、プロジェクト層設定と実行時オプションを優先します。
- 本リポジトリでの開発運用は ASF ワークフローを標準とし、原則として `scripts/gate/workflow.sh` または `scripts/asf-workflow.sh` を使用します。
- ASF 実行時は前提チェック（設定ファイル・スクリプト・`gh auth`）を満たしていることを確認します。
- 主要ドキュメント更新時は、日本語での一貫性を維持します。

### ドキュメント分離運用

- `packages/**/README.md` を正本として扱います。
- README は `README.md` を単一の正本として運用します。
- `packages/agent-swarm-framework/docs/*.md` も同様に正本を優先し、翻訳は任意で運用します。
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

## ASF ワークフロー: 実装委譲パターン

このエージェントは ASF ワークフローに従い、実装作業は line worker への委譲を原則とします。

### 実装委譲の判定

**委譲対象**:
- GitHub issue が作成され、実装スコープが明記されている
- Issue title が `implementation:` / `feature:` で始まる
- コード生成・変更を伴う作業（新規作成、既存コード修正）
- GitHub issue の code review が必要な場合

**自分で実装してよい対象**:
- ドキュメント作成・編集（README、ガイド、方針文書など）
- 設計・意思決定作業（Q&A、分析、reason_code 定義など）
- 小規模テスト・検証（既存テスト実行、簡単な動作確認）
- ユーザーが明示的に直接実装を指示した場合

### ユーザーコマンド解釈

| コマンド | 意図 | エージェント動作 |
|---|---|---|
| 進めて下さい | ASF workflow に沿って次フェーズへ | Issue 作成 → 委譲判定 → （line worker または自実装） |
| やってしまえ | 直接実装する | 委譲をスキップして直接実装 |
| 確認して | 分析・レビューのみ | 委譲なしで実施 |
| #N を実装して | 特定 issue の実装 | Issue scope 確認後、委譲判定 |

### 委譲フロー

```
設計完了
  ↓
GitHub issue 作成（実装スコープ明記）
  ↓
実行可能な line task へ変換（scripts/worker/delegate-issue-implementation.sh）
  ↓
GitHub issue へ runtime delegation 記録
  ↓
Line worker の PR を待機
  ↓
Code review + approval
  ↓
Merge
```

### 実行委譲の標準経路

Issue 作成やコメント追加だけでは line worker は実行を開始しません。
実装 issue を line worker が実行可能なタスクに変換するには次を使用します。

```bash
bash scripts/worker/delegate-issue-implementation.sh \
  --issue-number <N> \
  --line auto-001 \
  --task-command "<shell-command>"
```

### 条件付き自動 enqueue

- `implementation:` / `feature:` issue で `line-task` + `auto-enqueue` ラベルが付与され、
  日本語要約 / 受け入れ条件 / `task_command:` が定義されている場合、
  auto-enqueue worker が実行可能タスクへ自動変換します。
- 安全条件を満たさない issue は自動実行しません（手動委譲を使用）。

### Issue クローズ方針

- Issue をクローズする際は、必ずクローズ理由をコメントで明示します。
- クローズ理由は `completed`, `superseded`, `duplicate`, `invalid`, `deferred` のいずれかに分類します。
- `superseded` / `duplicate` では置き換え先 issue 番号を明記します。
- 実装系 issue のクローズ時は、検証結果（テスト/実行結果）を最低1行含めます。
- 標準化されたクローズ処理は `scripts/worker/close-issue-with-policy.sh` を使用します。

### 終了時整理方針

- 実行中は `issue:PR:merge` が一時的に 1:1:1 でなくても許容します。
- ただし作業終了時には、未採用 PR・実装済み Issue・キュー残件を必ず整理してクリーン状態へ戻します。
- 実装済み issue は理由と検証結果を付けてクローズします。
- 採用 PR はマージし、不要 PR は理由付きでクローズします。
- 終了前に open issue / open PR / pending queue / dead-letter の状態を確認します。
- 最終判定の基準は「再開可能かつ追跡可能なクリーン状態」です。

### 運用厳格度方針

- `production` / `mainline` 向けの作業では、Issue 管理に milestone / GitHub Project の更新を必須とします。
- `spike` / `hotfix` / 小規模タスクでは、実行中の milestone / Project 更新は任意とします。
- 任意運用を選んだ場合でも、作業終了時には終了時整理方針に従って必ず正規化します。
- 途中の簡略運用を行った場合は、クローズ時コメントに「後追い正規化」の実施結果を明記します。

### 自実装の記録

自分で実装する場合も Consult log に記録します。

```bash
bash scripts/gate/command-dispatch.sh \
  --issuer [agent-name] \
  --action /delegate \
  --scope "issue:#N" \
  --options '{
    "decision": "self_implement",
    "reason": "document_edit|trivial_fix|no_worker_available",
    "scope_description": "[簡潔な説明]"
  }'
```

### エラーハンドリング

- Line worker が不可用な場合: ユーザーに通知し、委譲できないことを報告します。
- Issue scope が不明確な場合: 委譲前にユーザーへ scope 確認を求めます。
- Code review が必要だが reviewer 不在の場合: consult log に escalate flag を設定します。

## @intake コマンド

ユーザーが `@intake` をメッセージ先頭に付けた場合、Intake Manager フローを起動します。

### トリガー条件

- メッセージが `@intake` で始まる場合のみ起動します。
- `@intake` なしの通常会話には適用しません（探索的会話を妨げないため）。

### 実行フロー

```
Step 1: 要件テキストの確定
  - @intake <テキスト> の形式なら、<テキスト> をそのまま使用
  - @intake のみで要件テキストがない場合、要件を対話で引き出す

Step 2: 意図の解釈・確認（インプット確認）
  - 入力テキストの内容を解釈し、以下をユーザーに提示して確認する:
      - 解釈した目的（何を実現したいか）
      - 想定する変更の範囲・種別（新機能/修正/設計変更 等）
      - 不明点があれば質問する
  - ユーザーが「合っている」と確認するまで次へ進まない

Step 3: Consult Facilitator による設計妥当性確認（条件付き）
  - 以下のいずれかに該当する場合のみ /consult を起動する:
      - 設計方針に曖昧さ・矛盾がある
      - スコープ境界が不明確（何が in/out か判断できない）
      - 責務・型契約に影響する懸念がある
      - 優先順位の判断が難しい
  - 上記に該当しない場合はスキップしてよい
  - /consult 結論は goal/scope.in/acceptance に反映してから次へ進む
  - 相談記録は consult-log.jsonl に残す

Step 4: conversation-entry.sh を dry-run で実行
  bash scripts/gate/conversation-entry.sh \
    --input-text "<要件テキスト>" \
    --intent-type "implement" \
    --channel-type "vscode_chat" \
    --dry-run true

Step 5: INTAKE_CONFIRMATION_BLOCK をユーザーに提示・確認
  - goal / scope.in / scope.out / acceptance / priority をチャット上で表示
  - ユーザーが修正・承認するまで次へ進まない

Step 6: 計画整合性レビュー（必須）
  - INTAKE_CONFIRMATION_BLOCK の内容に対して以下を審査する:
      - goal と acceptance の整合性（acceptance が goal を検証できるか）
      - scope.in と scope.out の境界が明確か
      - acceptance が検証可能な形式か（曖昧な完了条件を検出する）
      - 依存関係・前提条件の漏れがないか
  - 矛盾・漏れを発見した場合は指摘内容を提示し、Step 5 へ差し戻す
  - 問題がなければ「レビュー通過」を明示してから次へ進む

Step 7: 最終意図確認（実行前ゲート）
  - issue 化・ASF フロー開始の直前に、以下を要約してユーザーへ確認する:
      - 作成予定の issue タイトルと内容サマリー
      - 実行される ASF アクション（/intake dispatch）
      - 「この内容で進めてよいか？」を明示的に確認する
  - ユーザーが承認するまで issue を作成しない

Step 8: ユーザー承認後に issue 化 + /intake dispatch
  bash scripts/gate/conversation-entry.sh \
    --input-text "<要件テキスト>" \
    --intent-type "implement" \
    --channel-type "vscode_chat" \
    --draft-fields '<承認済みフィールドJSON>' \
    --issue-title "<タイトル>" \
    --confirm true

Step 9: ASF フローへ自動移行
  - issue 作成完了後、通常の ASF delegation フローへ引き継ぐ
```

### 制約

- Step 7（ユーザー承認）なしに issue を作成してはなりません。
- intake issue は `type: orchestrator-intake` ラベルを必ず持ちます。
- intake-manager スキルの権限境界（`agent-skills/files/.multi-agent/role-contracts/intake-manager.md`）に従います。
