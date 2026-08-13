# ai-playbook

全プロジェクト共通の AI 開発設定を管理するためのリポジトリです。

このリポジトリは、AI コーディングにおける共通ルールと運用方針の正本として扱います。
各プロジェクトはこのリポジトリの内容を参照し、必要に応じて固定版を取り込んで利用します。

## 役割

このリポジトリは、プロジェクト横断で再利用する共通設定を管理します。

対象は以下です。

- 共通開発ルール
- 共通のバージョン運用ルール

各プロジェクト固有の要件、設計、引き継ぎ、運用詳細は、それぞれのプロジェクト側で管理してください。

## 責務の範囲

このパッケージは、**AI エージェント運用の規範の正本**です。実行ランタイムは持ちません。

- 担うもの: 共通 AI 記述ルール、ロール責務の契約、タスク手順、レビュー運用、intake 規律と判定根拠
- 担わないもの: エージェントの実行、状態管理、ベンダー固有の機構

規範がどう実行されるかは、利用側の実行環境に委ねます。このパッケージは、実行基盤・状態面・ベンダーの選択を強制しません。

## 管理対象

| 対象 | 内容 |
|---|---|
| `shared-ai-rules.md` | 共通規範（コーディング規約・機密・作業状況・テスト・コミット・命名・質問運用・重複排除ゲート・機構化の判断基準） |
| `role-contracts/` | ロール責務の契約 7 種（目的・入力・出力・禁止事項・エスカレーション条件・完了定義） |
| `task-playbooks/` | タスク手順 4 種（issue triage / 計画分解 / PR レビュー / issue クローズ方針） |
| `review-workflow.md` | クロスモデル二段ゲートによるレビュー運用 |
| `loop-workflow.md` | ループコーディング運用の規範（受け入れ検証の機械ゲート化・verify ランナー契約・収束） |
| `loop-coding-guide.md` | ループコーディングの解説ガイド（従来ワークフローとの違い・考え方。`loop-workflow.md` の解説版） |
| `intake/` | intake テンプレート、相談テンプレート、判定 reason code |
| `templates/` | 導入用の雛形 8 種（`entry.md` 実行環境の入口ファイル / `project-ai-rules.md` プロジェクト共通ルール / `second-opinion-review.sh` 第二意見レビューの実装例 / `copilot-review.yml` リモート最終ゲートの要求側の実装例 / `review-gate.yml` リモート最終ゲートの確認側の実装例 / `claude-skill-intake.md` Claude Code の intake 起点スキル / `claude-agent-explorer.md`・`claude-agent-implementer.md` Claude Code の委譲先エージェント定義） |
| `.gitignore` | このパッケージを開発するときの追跡除外設定。規範ではないため配布・取り込みの対象外（`shared-ai-rules.md` 14 章） |

共通ルールの補足として、AI からの質問は一問ずつ行い、各質問には意図を添え、回答は選択肢優先で提示します。

実行環境の入口ファイル（例: `CLAUDE.md`）は、
この共通ルールを参照しつつ環境固有の最小差分のみを記述する運用を推奨します。

## 基本方針

- このリポジトリは、全プロジェクト共通の AI 開発設定を一元管理する
- プロジェクト名や利用先固有の情報は、このリポジトリのバージョン名やファイル構成に含めない
- 各プロジェクトは、必要な版を明示的に固定して利用する
- main をそのまま追従する運用は推奨しない

## バージョン運用

このリポジトリは SemVer を採用します。

タグ形式は以下とします。

- `vX.Y.Z`

初期リリースは以下です。

- `v0.1.0`

### MAJOR

既存プロジェクトの運用を壊す可能性がある変更に対して更新します。

例:
- ファイルパス構成の変更
- 参照必須ファイルの削除や改名
- 運用前提の大幅な変更

### MINOR

後方互換を保った機能追加やルール追加に対して更新します。

例:
- 新しい共通ガイドの追加
- 運用手順の追加
- 既存ルールを壊さない改善

### PATCH

軽微な修正に対して更新します。

例:
- 誤字修正
- 説明の明確化
- 意味を変えない文面修正

## 利用側プロジェクトへの推奨

このリポジトリを利用する各プロジェクトでは、次の方針を推奨します。

- タグだけでなくコミット SHA も記録する
- 人が見る識別子はタグを使う

## 更新手順

- 共通ルール変更時は、まずこのリポジトリを更新する
- 利用側プロジェクトは submodule、subtree、手動同期のいずれかで取り込む
- 取り込み方法に関わらず、採用したタグとコミット SHA を記録する

### 取り込んだ版の記録（`.ai-playbook/VERSION`）

取り込みを機構化する場合、取り込み側が版の記録ファイルを生成することがあります。
DevContainer Bootstrap（DCB）の `--with-playbook` は、取り込み先の `.ai-playbook/VERSION` に次の内容を書き出します。

```
# devcontainer-bootstrap が記録した ai-playbook のソース情報。
# version は --playbook-version 指定時のタグ。未指定なら (unspecified)。
version=v0.1.4
source=https://.../v0.1.4.tar.gz
```

| キー | 意味 |
|---|---|
| `version` | 取り込んだタグ。バージョンを明示せずに取り込んだ場合は `(unspecified)` |
| `source` | 解決したソース（タグの tarball URL、任意 URL、ローカルパスのいずれか） |

- 形式は機械可読な `key=value`（`#` で始まる行はコメント）です。
- このファイルはこのパッケージの構成要素ではなく、取り込み側が生成する記録です（`shared-ai-rules.md` 14 章）。
- 生成された環境では、このファイルが「どの版を取り込んだか」の証跡になります。`version` が `(unspecified)` の場合はタグが記録されていないため、`source` とコミット SHA を別途記録してください。

## インストールスクリプト方針

結論: このパッケージにインストール用シェルスクリプトは提供しません。

理由:
- 内容はドキュメント / ルール資産であり、実行ランタイムのセットアップが不要。
- 利用側はタグ + コミット SHA の明示固定で安全に取り込めるため、導入制御は既に満たしている。
- installer を持つと、保守負荷と互換性対応コストが増える割に運用効果が小さい。

推奨導入方法:
- submodule、subtree、または手動同期を使い、必ずバージョン固定する。
- 導入に必要な雛形は `templates/` にある。コピーするだけで 3 層構造が成立する（下記）。

見直しトリガー:
- 実行可能資産が増え、決定的なセットアップ手順が必要になった時点で installer 追加を再検討する。

## 導入手順

このパッケージは特定の言語・コンテナ・実行環境を前提としません。導入に必要な雛形はすべて `templates/` に含まれます。

ただし雛形には、**利用側が用意する実行体を指す記入欄**があります（受け入れ検証・第二意見レビュー・その単一入口など）。
このパッケージは規範と雛形のみを配り、実行ランタイムは持ちません（「責務の範囲」）。記入欄を何で埋めるかは利用側が選びます（手順 3・4）。

### 1. 規範を配置する

submodule / subtree / 手動同期のいずれかで、このパッケージを `.ai-playbook/` へ取り込む（タグと SHA を固定）。

### 2. 3 層構造を配線する

`shared-ai-rules.md` は 3 層の適用順序（全体共通 → プロジェクト共通 → 実行環境入口）を要求します。
その 2 層目と 3 層目の雛形をコピーします。

```bash
# 2 層目: プロジェクト共通ルール
mkdir -p .github
cp .ai-playbook/templates/project-ai-rules.md .github/project-ai-rules.md

# 3 層目: 実行環境の入口ファイル（使う実行環境の数だけ）
cp .ai-playbook/templates/entry.md CLAUDE.md
cp .ai-playbook/templates/entry.md .github/copilot-instructions.md
```

### 3. プロジェクト固有の値を埋める

`.github/project-ai-rules.md` の記入欄（機密の読み取り元、生成物、作業状況の記録先、レビューの起動方法）を埋めます。

### 4. 第二意見レビューを用意する（任意）

`review-workflow.md` のクロスモデル二段ゲートを使う場合、別ベンダーのモデルで実行する手段を配置します。

```bash
mkdir -p scripts
cp .ai-playbook/templates/second-opinion-review.sh scripts/
chmod +x scripts/second-opinion-review.sh
```

雛形は 1 つの実装例です。要件（別ベンダー・非対話・**出力の最後の行に置く一意な判定トークン**）を満たせば別の手段でかまいません。

この雛形は認証手段の違う 2 つの CLI から選べます（`--engine gemini|antigravity`。既定は `gemini`）。どの CLI をどう導入するかはプロジェクト層が決めます。判定ロジックはエンジンによらず 1 か所に集約してあり、エンジンごとに違うのは CLI 名・認証・差分の渡し方だけです。

### 5. intake 起点を配線する（Claude Code を使う場合・任意）

入口ファイルは「読まれる」だけで「起動する」機構を持ちません。Claude Code では skill が起点になるため、実装依頼を受けた瞬間に intake 判定へ入る配線として、規範を参照するだけの薄いスキルを 1 つ置きます。

```bash
# Claude Code の機構はスキル定義ファイル名を SKILL.md に固定するため、
# lower-kebab-case の雛形名から改名して配置する（shared-ai-rules.md 8 章の例外）。
mkdir -p .claude/skills/intake
cp .ai-playbook/templates/claude-skill-intake.md .claude/skills/intake/SKILL.md
```

このスキルは判定基準・`reason_code` 一覧・intake 票の項目定義を複製せず、`.ai-playbook/intake/` と `.ai-playbook/role-contracts/intake-manager.md` を参照するだけです。Copilot 等 skill 機構を持たない実行環境は、同じ規範を各環境の機構で参照する形になります。

あわせて、委譲先のエージェント定義を置きます。`model` と `tools` を frontmatter で固定するのが目的で、**指示文による呼びかけは迂回できますが、実行環境が読む機構は迂回できません**（`shared-ai-rules.md` 12 章）。

```bash
mkdir -p .claude/agents
cp .ai-playbook/templates/claude-agent-explorer.md .claude/agents/explorer.md
cp .ai-playbook/templates/claude-agent-implementer.md .claude/agents/implementer.md
```

**定義だけを置いても役割は使われません。** 判定の導線は `shared-ai-rules.md` 13 章「実装委譲パターン」が持ちます。プロジェクト層には、置いた定義と対応する役割・モデルの一覧を書き、実体と機械照合できる形にしてください（同 12 章「一覧の複製は機械照合で担保する」）。

`tools` から編集系を外しても、調査に必要なコマンド実行を残す限り書き込みは完全には塞げません。境目は各定義に書いてあります。

### 6. リモート最終ゲートを配線する（GitHub を使う場合・任意）

`review-workflow.md` のリモート最終ゲートを機構で自動要求する場合、要求が 1 回に限定される雛形と、要求されたことを確認する雛形を配置します。

```bash
mkdir -p .github/workflows
cp .ai-playbook/templates/copilot-review.yml .github/workflows/copilot-review.yml
cp .ai-playbook/templates/review-gate.yml .github/workflows/review-gate.yml
```

**2 本で 1 組です。** `copilot-review.yml` が要求し、`review-gate.yml` が要求されたことを別の契機（PR 更新・定期実行）から確認します（規範「要求されたことを別の契機で確認する」）。要求側の契機が届かないと最終ゲートが黙って抜けるため、確認側だけを省くと、この節で塞ごうとしている穴がそのまま残ります。確認側は要求しません。

雛形は 1 つの実装例です。規範が要求するのは「要求回数を 1 回に限定すること」と「別の契機で確認すること」で、同じ性質を満たせば別の手段でかまいません。前提条件（レビュー機構の有効化・トークン）は雛形の冒頭コメントに記載しています。`review-gate.yml` は required check にしません（理由は規範側）。

### 新規プロジェクトの場合

新規に環境ごと立ち上げる場合は、DevContainer Bootstrap（DCB）の `--with-playbook` が上記の手順の大半を実施します。
対応は次のとおりです。

| 上記の手順 | DCB の扱い |
|---|---|
| 1. 規範を配置する | 実施する（`*.md` のみ。`README.md` と `CHANGELOG.md` は規範ではないため配布対象外） |
| 2. 3 層構造を配線する | 実施する（`.github/project-ai-rules.md` と入口ファイル 2 種） |
| 3. プロジェクト固有の値を埋める | **実施しない。** 内容の判断が必要で自動化できないため、生成後に手で埋める |
| 4. 第二意見レビューを用意する | 実施する（`scripts/second-opinion-review.sh` を実行可能属性付きで配置） |
| 5. intake 起点を配線する | Claude Code の装備を選んだ場合のみ実施する |
| 6. リモート最終ゲートを配線する | 該当のレビュー機構を選んだ場合のみ実施する |

DCB は雛形の内容を持たず、このパッケージの `templates/` をコピーするだけです。正本はこのパッケージ側にあります。
DCB はあわせて `.ai-playbook/VERSION` を生成し、取り込んだ版の出所を記録します（「取り込んだ版の記録」）。

DCB は devcontainer と特定言語（node / go / python / php / rust / ruby）を前提とするため、それ以外の環境では上記の手順を使ってください。

## ファイル同期ルール

- `README.md` をこのパッケージの正本として扱う
- 追加言語版を作成する場合は、`README.md` と意味を一致させる

## ライセンスと配布

配布リポジトリのルートには次の 2 ファイルを置きます。

| ファイル | 内容 |
|---|---|
| `LICENSE` | MIT License |
| `CHANGELOG.md` | 版ごとの変更点。公開しなかった版がある場合も、その事実とともに記録しています |

いずれもこのパッケージの規範ではないため、DCB の `--with-playbook` による取り込み対象からは外れます（`README.md` と同じ扱い）。

**配布リポジトリは配布専用です。** 開発は別リポジトリで行い、リリースのたびに配布リポジトリの内容を全置換します。配布リポジトリへ直接 Pull Request を出しても次のリリースで失われるため、受け付けていません。不具合や要望は配布リポジトリの issue でお知らせください。

## ドキュメント

詳細な共通 AI ルールは次を参照してください。

- [shared-ai-rules.md](shared-ai-rules.md)

ループコーディングのワークフローについては次を参照してください。

- [loop-coding-guide.md](loop-coding-guide.md) — 従来ワークフローとの違い・考え方の解説
- [loop-workflow.md](loop-workflow.md) — 規範（受け入れ検証の機械ゲート化・verify ランナー契約・収束）
