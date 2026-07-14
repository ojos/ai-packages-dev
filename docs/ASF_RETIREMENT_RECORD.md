# ASF 退役・dotfiles 統合 記録

Agent Swarm Framework（ASF）を廃止し、保全価値のある規範を dotfiles へ、配布経路を DCB へ移した上で、リポジトリを 2 パッケージ体制へ再編しました。

本文書は計画として起案し、実施記録として完結させたものです。

- 起案日: 2026-07-14
- 完了日: 2026-07-14
- 状態: **完了**

## 実施結果

| フェーズ | 状態 | 証跡 |
|---|---|---|
| 0. ポリシーと強制の解除 | 完了 | `f34ba72` |
| 1. 正本の確定 | 完了 | `a18ed11` |
| 2. 規範の dotfiles 移植 | 完了 | `83395fb`、`5486c0e` |
| 3. 配布経路の DCB 移植 | 完了 | `d88c582` |
| 4. ASF 退役 | 完了 | `49d8ba4`（298 ファイル / −47,744 行）、PR #64 を `77d5805` でマージ |
| 5. 公開処理 | 完了 | `ojos/ai-dotfiles` v0.3.0、`ojos/devcontainer-bootstrap` v0.2.1、`ojos/agent-swarm-framework` を削除 |

退役対象のソースは、削除コミットの親（`49d8ba4^`）に 210 ファイルすべてが保全されています。

```bash
git checkout 49d8ba4^ -- packages/agent-swarm-framework/
```

## 実施中に判明した、計画との相違

| 計画の記述 | 実際 |
|---|---|
| ロール契約が二重管理されている（6.1 節） | 二重管理ではなく移行漏れだった。`role-contracts` は `skills` の strict superset で、固有の内容はゼロ。削除のみで解消 |
| `install.sh` の dotfiles 配布は約 150 行 | 配布対象が 1 ファイルから 17 ファイルの木構造へ変わったため、単純移植では不足。木構造のコピーへ拡張した |
| 参照実装からの取り込みは 5 規範 | 「機密の取り扱い」と「作業状況の記録」の 2 節を取りこぼしていた。指摘を受けて追加（`5486c0e`） |
| 論点 A のラッパーは「保全対象」 | 規範のみ移植し実装を作っていなかった。指摘を受けて DCB の生成物として実装（`5486c0e`） |

## 公開時の事故

v0.2.0 として公開した DCB に、URL 経由で規範が 1 件も配置されない不具合があった。エラーにならず完了扱いになるため、存在しないファイルを参照する入口ファイルだけが残る壊れ方だった。

原因はセルフレビューでの修正が生んだリグレッション。一時ディレクトリ削除の EXIT トラップを、コマンド置換内で実行される関数に登録したため、パスを返した直後に展開先が消えていた。URL 経路を検証せずローカルディレクトリのみで確認したため素通りした。

v0.2.1 で修正済み（`b6b5e81`）。壊れていた v0.2.0 はリリースとタグを削除した。公開履歴は v0.1.15 → v0.2.1 となり、v0.2.0 は欠番。

この事故は、URL 経路の E2E テストが 1 本あれば公開前に検出できた。DCB にはテストがなく、`bootstrap.sh` の 4 経路（URL / ローカルディレクトリ / 隣接チェックアウト / エラー）の検証はすべて手動で、回帰を防ぐ仕組みがない。

## 1. 決定事項

| # | 論点 | 決定 | 決定日 |
|---|---|---|---|
| A | マルチベンダー性を残すか | **gemini レビューのラッパーのみ小さく残す**。`engine-routing.json` と `agentEngines` 相当の汎用ルーティング機構は廃止 | 2026-07-14 |
| B | ASF を独立パッケージとして存続させるか | **dotfiles へ統合し ASF を廃止**。2 パッケージ体制（dotfiles + DCB）へ | 2026-07-14 |
| C | dotfiles の配布経路 | **DCB へ引き継ぐ**。DCB = 配布機構 / dotfiles = 正本。dotfiles の installer 非提供方針は維持 | 2026-07-14 |
| D | 退役後の状態面 | **原則のみ規範化し、実装はプロジェクト層へ委ねる**。GitHub / ファイルの選択は強制しない | 2026-07-14 |
| E | 公開リポジトリの畳み方 | **`ojos/agent-swarm-framework` を削除**（実測: stars 0 / forks 0 / issue 0） | 2026-07-14 |

## 2. 背景と判断根拠

実行基盤としての ASF は、各 AI ベンダーの標準機能に追い越されました。判断は 2 系統の根拠に基づきます。

### 2.1 稼働実績（実測値）

| 指標 | 実測 |
|---|---|
| 全ワーカーキュー | 0 行（`line-auto-001/002/003`、`orchestrator`、`closer` すべて） |
| 累計イベント数 | line-001: 74 件 / line-002: 9 件 / line-003: 8 件（2026-04-14 以降の全期間） |
| dead-letter | 12 件が未 replay のまま滞留 |
| コマンド履歴 | 最終 2026-05-25。約 3 ヶ月で記録のある日は 10 日 |
| 最終コミット | 2026-06-02 |
| `asf-last-run.json` | 直近は postAttach による `status` 実行のみ（git hook 回避のマーカー更新） |

4〜5 月に line worker 経由の PR マージが実際に成立しており、**基盤は動作した**。その上で使われなくなった、という経緯です。

### 2.2 機能の重複（2026-07 時点で確認）

| ASF の機能 | ネイティブ提供 |
|---|---|
| line-worker 並列実行 | Subagents / Agent Teams |
| git worktree 分離 | `isolation: worktree` |
| ロール契約（Markdown） | `.claude/agents/*.md`（形式まで同一） |
| タスクプレイブック | Skills |
| dispatch / coordinator / queue | Dynamic Workflows（`agent()` / `pipeline()`） |
| monitor 一式 | `/workflows`、Agent View |
| conversation-gate | Hooks（`UserPromptSubmit` / `PreToolUse`）、permission mode |
| GitHub Actions executor | claude-code-action、Code Review |
| ロール別モデル振り分け | subagent の `model` パラメータ |

ネイティブに存在しないのはベンダー横断ルーティングのみで、これは小ラッパーで足ります（論点 A）。CLI 直叩きによるサブスク定額活用という経済的前提も、ネイティブの subagent / workflow が同一サブスク下で動作するため消滅しています。

## 3. 退役対象と保全対象

### 3.1 退役対象

パッケージ全体を廃止します。

| 対象 | 規模 |
|---|---|
| `packages/agent-swarm-framework/` 全体 | runtime-core 8,218 行 / executors 113 行（placeholder）/ `install.sh` 738 行 / `init.sh` 172 行 / `config.schema.json` / `template-project/` / `.preview/` / `tests/` / `docs/` 13 本 |
| `scripts/gate/` `scripts/monitor/` `scripts/worker/` `scripts/orchestration/` | 上記の展開実体とランタイム状態（6.2MB） |
| `scripts/asf` `scripts/asf-workflow.sh` `scripts/release/preflight-check.sh` | ASF 専用 CLI と前提チェック |
| `.githooks/` | 強制対象が消滅 |
| `.multi-agent/` | 規範の移植後に廃止 |
| 公開リポジトリ `ojos/agent-swarm-framework` | 削除（論点 E） |

`install.sh` のうち **dotfiles 配布に関わる約 150 行のみ DCB へ退避**させます（3.2 / 4.2 節）。残り約 590 行（ASF 資産配置・GitHub 連携・カテゴリ確認ループ）は退役します。

### 3.2 保全対象

| 対象 | 移植先 |
|---|---|
| ロール契約 7 種 | dotfiles |
| タスクプレイブック 4 種 | dotfiles |
| intake 規律 / reason code 体系 | dotfiles |
| `intake-template.md` / `consult-template.md` | dotfiles |
| `labels.json`（GitHub 運用規約） | dotfiles（原則として。論点 D により強制はしない） |
| dotfiles 配布ロジック（約 150 行）+ 入口ファイル生成 | DCB（`bootstrap.sh`） |
| パッケージ中立性の方法論 | プロジェクト層に維持 |

## 4. 移植マッピング

### 4.1 規範 → dotfiles

| 移植元 | 移植先 | 備考 |
|---|---|---|
| `role-contracts/*.md`（7 種） | dotfiles の規範 + `.claude/agents/*.md` の雛形 | 契約構造（目的・入力・出力・禁止事項・エスカレーション条件・完了定義）を保持 |
| `task-playbooks/*.md`（4 種） | dotfiles の規範 + Skills 雛形 | issue-triage / plan-breakdown / pr-review / issue-close-policy |
| `conversation-gate.sh`（497 行）の判定ポリシー | reason code 定義 Markdown（+ 任意で `UserPromptSubmit` hook 雛形） | 実装は大幅縮小、reason code 体系は維持 |
| `engine-routing.json` | gemini レビュー用の小ラッパー | 論点 A。実装と別ベンダーでレビューする**思想はロール契約に記述**し、機構としては持たない |
| `stateBackend` | 原則の記述のみ | 論点 D。「状態面は並行更新に耐えること」「単一ファイルを全エージェントが更新する設計は並列化と衝突する」を記述し、GitHub / ファイルの選択は委ねる |

dotfiles は現在 `shared-ai-rules.md` 1 ファイルです。統合により内容が大幅に増えるため、**「軽量に保つ」方針の再定義が必要**です（論点 B の帰結）。ただし installer 非提供方針は論点 C により維持されます。

### 4.2 配布経路 → DCB

**調査結果: DCB は dotfiles を一切参照していません**（パッケージ全体で 0 ヒット）。dotfiles を配布していたのは ASF の `install.sh` でした。

- `--with-dotfiles` / `--dotfiles-from <path|url>` / `--dotfiles-conflict-policy <skip|overwrite|prompt>`
- ローカルパス・ディレクトリ・アーカイブ URL から `shared-ai-rules.md` を探索して配置（`install.sh:222-274`）
- **入口ファイル（`CLAUDE.md` / `.github/project-ai-rules.md` / `.github/copilot-instructions.md`）を生成し、3 層の優先順位テキストを書き込む**（`install.sh:356-368`）

つまり dotfiles の「installer 非提供方針」は、**隣のパッケージが installer を代行していたから成立していました**。ASF 廃止に伴い、この約 150 行を `bootstrap.sh` へ移します。DCB の役割定義（環境生成のみ）と README の設計思想は拡張が必要です。

### 4.3 参照実装

先行する別プロジェクトが、本計画の目標形にあたる運用を約 100 行の `CLAUDE.md` のみで実施しています（2026-07-14 に内容を確認）。**本計画の実現可能性は、この実例によって裏付けられます。**

特に、**implementer=claude / reviewer=gemini のクロスモデル二段ゲートを、ルーティング機構なしの散文だけで運用**しています。push 前に `/code-review`（Claude）→ 別モデルによる第二意見を通すという規約だけで成立しており、ASF の `engine-routing.json` + `orchestrate-task.sh`（924 行）が解こうとした問題は機構を必要としませんでした。論点 A の決定はこの実例と整合します。

#### 採用する規範

| 規範 | 内容 | ASF 側の扱い |
|---|---|---|
| クロスモデル二段ゲート | push 前に `/code-review` → 別モデルの第二意見。対象は致命バグ・脆弱性・型エラー・エッジケース見落としのみ | `reviewer` ロール契約を**置き換える** |
| レビュー往復の打ち切り | 修正は 1 イテレーションで完結。指摘外の自律的リファクタリングを禁止。2 巡目以降の軽微な指摘は人間が却下 | `closer` ロール契約に統合。無限ループ防止は現行契約にない知見 |
| リモートレビューは最終ゲート 1 回 | push ごとの自動フルレビューに依存しない | 同上 |
| 並列前提のタスク分解 | 着手前に依存関係を洗い出し、独立単位へ分割 | `planner` ロール契約に統合 |
| worktree による作業分離 | 親セッションが `isolation: "worktree"` を指定し、機構で分離を保証 | `implementer` ロール契約に統合 |

#### ASF 側が補完するもの

参照実装には**ロール分離が存在せず**、単一の未分化なエージェントを前提としています。人間とエージェントの境界も規定されていません。3.2 節の保全対象は、この欠落とほぼ一致します。

- ロール契約の構造（目的・入力・出力・**禁止事項**・**エスカレーション条件**・**完了定義**）
- intake 規律（作業着手前の構造化された起票、人間との窓口の一本化）
- reason code 体系（bypass の分類と判定根拠の記録）

移植は一方向の取り込みではなく、**相互補完**として設計します。

#### 取り込まない / 修正して取り込む点

| 事象 | 対応 |
|---|---|
| 月次ログのパスが本文にハードコードされ、月替わりで陳腐化する | 索引のみリンクし、月次ファイルは規約で示す |
| 別モデルレビューの起動方法（実体・所在）が未定義 | 移植時に呼び出し方法を明記する |
| 単一の状態ファイルを全エージェントが更新する規約が並列化と衝突する | 論点 D の原則として記述し、実装は委ねる |

### 4.4 機構化の判断基準

参照実装は「`CLAUDE.md` の指示文に頼るのではなく、機構で保証する」という原則を明示しています。本計画もこれを採用しますが、**無条件には適用しません。**

ASF の pre-commit hook がその反例です。「`asf-workflow.sh` を実行したか」を `asf-last-run.json` の鮮度で強制した結果、**postAttach が `status` を 1 回叩いてマーカーを更新するだけの儀式**に退化しました（2.1 節）。実質は誰も検査していません。

- **機構化してよい**: 機構が結果そのものを生むもの。worktree 分離は、機構が実際に分離された作業ツリーを生成するため迂回できない
- **機構化してはいけない**: 実質を検査できず、儀式のみを検査できるもの。「状態を更新したか」はファイル差分で検査できるが、「意味のある更新か」は検査できない。空更新で通過するルールは、規範ではなく手続きコストになる

後者は規範（散文）として残し、レビューで担保します。

## 5. 実施順序

**フェーズ 0 を最初に行う必要があります。** 現行の `pre-commit` / `pre-push` は `asf-last-run.json` の鮮度（既定 12 時間）を要求するため、これを外さないと退役作業自体のコミットがブロックされます。

| フェーズ | 内容 | 完了条件 |
|---|---|---|
| **0. ポリシーと強制の解除** | 5.1 節のポリシー条項を削除。`.githooks/` と `asf-enforcement-check.sh` を撤去し `core.hooksPath` を既定へ戻す。`postAttachCommand` の hook 導入呼び出しを解除 | 通常のコミットが通り、ポリシー文書と実態が一致する |
| **1. 正本の確定** | ロール契約の二重管理を解消（6.1 節） | 7 ロールの正本が 1 箇所 |
| **2. 規範の dotfiles 移植** | 4.1 / 4.3 の相互補完を反映。dotfiles の「軽量維持」方針を再定義 | ネイティブ機能のみで intake → 実装 → レビューが 1 周する |
| **3. 配布経路の DCB 移植** | 4.2 の約 150 行を `bootstrap.sh` へ。DCB の役割定義と README を拡張 | 新規プロジェクトで DCB 単体からルール配置まで到達する |
| **4. ASF 退役** | `packages/agent-swarm-framework/` と展開実体を削除。公開 URL 参照 27 箇所を修正（特に `dotfiles/README.md:24,29`） | `rg -n "agent-swarm-framework"` で意図しない参照が残らない |
| **5. 公開処理** | dotfiles / DCB をリリース。`ojos/agent-swarm-framework` を削除（実行前に最終確認） | 2 パッケージ体制で導線が成立 |

フェーズ 2 と 3 の完了を**フェーズ 4 の着手条件**とします。移植先が機能することを確認する前に退役させません。

### 5.1 ポリシー文書との衝突（フェーズ 0 の必須項目）

本計画は現行のプロジェクトポリシーと直接矛盾します。**先にポリシーを改訂しないと、退役作業自体がルール違反になります。**

| 文書 | 矛盾する条項 | 対応 |
|---|---|---|
| `.github/project-ai-rules.md` | 「開発運用は ASF ワークフローを標準とし、原則として `scripts/gate/workflow.sh` または `scripts/asf-workflow.sh` を使用します」 | 削除。ネイティブ機能ベースの運用に置き換える |
| `.github/project-ai-rules.md` | 「ASF 実行時は前提チェック（設定ファイル・スクリプト・`gh auth`）を満たしていることを確認します」 | 削除 |
| `.github/project-ai-rules.md` | 「ASF ワークフロー: 実装委譲パターン」節（line worker への委譲判定・委譲フロー） | 全面改訂。委譲先を line worker からネイティブ subagent へ |
| `.github/PROJECT_DEFINITION.md` | 「ASF 強制適用」節（`postAttachCommand` による hook 導入、preflight マーカー必須） | 削除 |
| `CLAUDE.md` / `.github/copilot-instructions.md` | 3 層の優先順位のみを述べる最小の入口ファイル | 改訂不要の見込み（要確認） |

## 6. 着手前に解消すべき既存の不整合

### 6.1 ロール契約の二重管理 — **解消済み（2026-07-14）**

7 つのロール契約が 2 箇所に存在していました。

- `packages/agent-swarm-framework/agent-definitions/files/.multi-agent/role-contracts/*.md`（パッケージ層）
- `.multi-agent/skills/*.md`（プロジェクト層、最終更新 2026-05-22）

**実測の結果、二重管理ではなく移行漏れでした。** `role-contracts` は `skills` の strict superset であり、`skills` に固有の内容は 1 行も存在しませんでした（差分 3 行はすべて表記揺れ）。

| ロール | skills の行数 | role-contracts に不在の行 |
|---|---|---|
| closer / consult-facilitator / intake-manager / orchestrator / planner | 13〜30 | 0 |
| implementer | 13 | 1（「上書き設定」→「overrides」の表記差のみ。`implementer.md:4` に同義の記述あり） |
| reviewer | 12 | 2（「高/中/低」→「High/Medium/Low」の表記差のみ） |

加えて `packages/agent-swarm-framework/docs/operational-pr-review-checklist.md:47` が「7. 旧パス参照が残っていないか / `.multi-agent/skills` の参照が残っていない。」とレビュー項目に定めており、**skills の廃止はプロジェクトが既に決定済み**でした。2026-05-25 の命名統一（`d9bb2ed` / `0878a98`）で `role-contracts` へ移行した際、ディレクトリの削除のみが漏れていたものです。

**正本 = `role-contracts`（パッケージ層）**として確定し、`.multi-agent/skills/` を削除しました。

### 6.2 移植時に戻すべき言語の後退

命名統一の際、日本語だった記述の一部が英語へ置き換わっています。`shared-ai-rules.md` は日本語を正本と定めているため、**フェーズ 2 の移植時に日本語へ戻します**。

| 箇所 | 現状 | 移植時 |
|---|---|---|
| `role-contracts/implementer.md:4` | 「project 固有要件は導入先の overrides を参照する。」 | 「プロジェクト固有要件は導入先の上書き設定を参照する。」 |
| `role-contracts/reviewer.md` | 「High/Medium/Low の観点で整理する。」 | 「高/中/低 の観点で整理する。」 |

### 6.3 修正しない既知バグ

以下は退役対象の層にあるため**修正しません**。

- `scripts/worker/closer-worker.sh:6` の `source` 先が不在（実行時即失敗）
- `scripts/gate/workflow.sh:10-12` の worker スクリプト参照パス誤り
- `scripts/asf-workflow.sh` がパッケージに未同梱（導入先で `asf doctor` が必ず失敗）

これらが 3 ヶ月間検出されなかったこと自体が、退役判断の根拠の一部です。

### 6.4 陳腐化した計画文書の扱い

以下は本計画と矛盾します。フェーズ 4 でアーカイブまたは削除します。

| 文書 | 矛盾 |
|---|---|
| `docs/PACKAGE_RELEASE_PLAN.md` | 3 パッケージ v1.0.0 一斉公開前提 |
| `docs/WORK_PLAN_2026-04-20_PRIORITY_SHEET.md` | #17 remote automation を最優先と規定（退役により不要） |
| `docs/RELEASE_EXECUTION_RUNBOOK.md` | ASF を含む 3 リポジトリ前提 |
| `docs/PACKAGE_BOUNDARY_REVIEW.md` | Option A 推奨。**論点 B により Option C 採用として決着**させ、未クローズの Decision Point を閉じる |
| `docs/DESIGN_SUMMARY_CONVERSATION_GATE.md` | ASF 公開リポジトリの reason code guide を参照 |

## 7. 残る論点

### 論点 F: dotfiles / DCB のバージョニング

dotfiles は規範を大量に取り込むため v0.2.1 → v0.3.0 相当、DCB は配布機構を獲得するため v0.1.15 → v0.2.0 相当が妥当と考えます（提案であり未決）。タグ規約は `docs/RELEASE_EXECUTION_RUNBOOK.md` の prefixed 方式（`dotfiles/vX.Y.Z`）を踏襲します。

## 8. 本計画が意味しないこと

- runtime-core の技術的品質の否定ではありません。flock による排他、dead-letter、worktree 分離、issue コメント順序を用いた mesh-pull の分散ロックはいずれも妥当な実装です。プラットフォームに追い越されたことは設計の失敗ではありません。
- ASF の思想の否定ではありません。ロール分離、intake 境界、状態面の並行更新耐性はいずれも保全対象です。退役するのは**配送手段**であって、規範ではありません。
