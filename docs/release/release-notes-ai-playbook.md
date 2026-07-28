# ai-playbook Release Notes

新世代（2026-07-17 リポジトリ再作成後）のリリースノートです。

> このファイルは配布リポジトリへ `CHANGELOG.md` として配布されます。配布先には `docs/` 階層が存在しないため、リポジトリ内の相対リンクを書かないでください（配布先で解決できないリンクになります）。

## v0.1.5

### Summary
- **導入手順が新規プロジェクトで必ず失敗する不具合を修正した**（issue #167）。手順 2 と 4 の `cp` が出力先ディレクトリの事前作成を前提にしており、`.github/` や `scripts/` が無い状態では `cp: cannot create regular file` で止まっていた。
- 配布先で解決しない参照を除去した（#167）。開発リポジトリでは成立するが、このパッケージを取り込んだ先では解決しない記述が複数あった。
- 自パッケージの構成表・命名規則・管理対象一覧の自己不整合を解消した（#168）。
- 役割契約・雛形の内部不整合と、ベンダー中立宣言に反する実装固有名の混入を解消した（#169）。
- `LICENSE`（MIT）と `CHANGELOG.md` を配布物へ追加した（#177）。あわせて README へ配布専用である旨を明記した。
- 後方互換。**ファイル名・参照パスは変えていない**ため、既存の取り込みは壊れない。

### Highlights

- **導入手順の `mkdir -p` 欠落（#167）**: 手順 5 だけが `mkdir -p` を持ち、手順 2 と 4 が持っていなかった。空プロジェクトで手順を順に実行する再現スクリプトを書いて確認しており、修正前は手順 2 で exit 1、修正後は全手順が exit 0 になる。
- **配布先で解決しない参照（#167）**: `intake/intake-template.md` が「Step 6 で明記した上で通過する」と書いていたが、この Step 1〜9 の番号体系は利用側プロジェクトのルール文書にしか存在せず、配布先には無い。`templates/project-ai-rules.md` は記入欄であるべき項目に `bash scripts/loop-gate.sh` を断定形で書いており、これは DevContainer Bootstrap の生成物であってこのパッケージは配布しない。`templates/gemini-review.sh` のエラーメッセージも同様に生成物のスクリプトを案内していた。README の「このパッケージ単独で完結します」という宣言とも矛盾していたため、依存関係を正確に書き直した。
- **構成表と実体の不一致（#168）**: `shared-ai-rules.md` 13 章の構成表に `loop-coding-guide.md` が無く、README 側の表とも食い違っていた。README の `templates/` 説明は 4 種しか挙げておらず、5 件目の `copilot-review.yml` が未記載で、導入手順にも配置手順が無かった（DevContainer Bootstrap を使わない利用者はリモート最終ゲートを配線できなかった）。
- **規範文書の位置の記述（#168）**: 「規範文書の位置は `.github/` 配下」と書かれていたが、実際の規範はこのパッケージ配下にあり、`.github/` に置かれるのは利用側のプロジェクト共通ルールである。
- **命名規則の分類定義を改めた（#168）**: 8 章は「ポリシー・仕様・契約文書は `UPPER_SNAKE_CASE`」としていたが、自パッケージの規範・契約文書（`review-workflow.md` / `loop-workflow.md` / `role-contracts/*.md`）がこれに従っていなかった。実体を見ると `UPPER_SNAKE_CASE` が機能しているのは `intake/REASON_CODES.md` だけで、実際の区別軸は「規範かどうか」ではなく「**値の定義表か、通読する文書か**」だった。規則の側を実態に合わせ、判断基準へ「規範であること自体は大文字化の理由にならない」を明記した。**ファイル改名は行っていない**（改名は参照リンクを壊す破壊的変更になるため）。
- **節見出し参照の壊れ（#169）**: `task-playbooks/plan-breakdown.md` と `role-contracts/implementer.md` が、`loop-workflow.md` に存在しない節名を参照していた。リンク先ファイルは実在するため、ファイル実在のみを見る検査では検出できない種類の壊れ。
- **契約とテンプレートの不一致（#169）**: `role-contracts/consult-facilitator.md` の最小記録項目に `blocking` が無く、`intake/consult-template.md` の必須フィールドおよび同契約自身の完了定義と食い違っていた。
- **ベンダー中立違反（#169）**: `review-workflow.md` は「特定のベンダーに依存しません」と明示しているにもかかわらず、本文に Gemini 実装固有の環境変数名と CLI フラグが焼き込まれていた。中立表現へ改め、具体的な変数名はプロジェクト層の責務とした。
- **取り込み版の記録（#169）**: 取り込みを機構化した場合に生成される `.ai-playbook/VERSION`（`version` / `source` の `key=value`）の存在・形式・意味を文書化した。

### 影響

- 配布物に `LICENSE` と `CHANGELOG.md` が加わる。
- ファイル名・ディレクトリ構成・参照パスは変えていないため、既存の取り込み（submodule / subtree / 手動同期）はそのまま追随できる。
- 命名規則の**分類定義**は変わったが、既存ファイルの改名は伴わない。

---

## v0.1.4

### Summary
- 第二意見レビュー雛形 `templates/gemini-review.sh` に複数回実行と多数決を追加した（`GEMINI_REVIEW_RUNS` / `--runs`。既定 1 で従来と同一挙動）。あわせて `review-workflow.md` へ「第二意見の非決定性」節を追加し、1 回の LGTM が不在の証明ではないこと、主レビューを省略してよい根拠にならないことを明記した（issue #157）。既定の挙動を変えないため後方互換。

### Highlights
- **非決定性への対処（#157）**: 第二意見は同じ差分でも実行のたびに結果が変わる。実測で、同一コミットへの 4 回の実行が LGTM 2 回・指摘あり 2 回に分かれた。gemini CLI に temperature / seed に相当するオプションは無く、フラグでは決定化できない。`GEMINI_REVIEW_RUNS` で実行回数を増やし、指摘を報告した実行が**過半数**（`floor(N/2)+1`）に達したときだけ落とす。N=1 なら閾値 1 で従来と同じ。
- **過半数を採る理由**: 「1 回でも指摘があれば落とす」（fail-closed）にすると、誤検出のたびに反証が必要になり、ゲート自体が無視されるようになる。実際にこの規範を運用した一連の作業で、第二意見の指摘の多くが反証された。トレードオフとして**少数回しか現れない指摘は通過する**。この限界は `review-workflow.md` に明記し、第二意見を「補助」と位置づけて受け入れる。
- **少数意見も出力に残す**: 過半数に届かなかった指摘も、どの実行が何を報告したかとともに出力する。集約結果だけを出すと確認すべき指摘が消えるため。
- **不正な回数は fail-closed**: `--runs` が 0・負数・非数値なら、実行前に停止する。黙って既定へ落とすと、増やしたつもりのゲートが実際には効いていない状態になる。あわせて基数を `10#` で固定した。bash の算術評価は先頭 0 を 8 進数として扱うため、固定しないと `08` / `09` は比較自体がエラーになって検証をすり抜け、`010` は 8 と解釈されて「10 回のつもりが 8 回」になる（閾値も狂う）。
- **`.env` からの解決を修正（付随）**: `.env` ローダーの読み込みが `GEMINI_REVIEW_MODEL` / `GEMINI_REVIEW_RUNS` の既定値解決より後にあり、プロジェクト `.env` に書いた値が効かなかった（不正な値も検証をすり抜けた）。ローダーを既定値解決の前へ移し、優先順位を **CLI 引数 > `.env` > 既定** に確定した。`GEMINI_REVIEW_MODEL` は本件以前からの挙動。
- **引数解析の修正（付随）**: 値を伴わないオプション指定（`--range` / `--model` / `--runs` で終わる）が `set -u` 下で `unbound variable` として落ちていた。何が足りないかを示して停止するよう改めた。`--range` / `--model` は本件以前からの挙動で、同じ引数解析部のためまとめて直した。

### 影響
- `GEMINI_REVIEW_RUNS` を設定しなければ、実行回数・出力・終了コードとも従来どおり。
- 回数を増やすと所要時間は回数に比例する。

---

## v0.1.3

### Summary
- `review-workflow.md`「リモート最終ゲート」の規定を緩和し、要求回数が 1 回に限定される機構であれば自動要求も許容する旨へ改めた。あわせて具体機構の雛形 `templates/copilot-review.yml` を新設（ベンダー中立の規範と、選択式の Copilot 雛形の分離）。規範の緩和方向で後方互換（issue #113）。
- `intake/REASON_CODES.md` に「軽微修正の免除条件」節を追加（6 条件の AND・該当例・非該当例・AND の根拠）。判定基準の追記のみで後方互換（issue #110）。
- 第二意見レビュー雛形 `templates/gemini-review.sh` の冒頭で、プロジェクト `.env` ローダー（`scripts/load-project-env.sh`）を明示 source するよう追随した（DCB 側の `.env` 優先読み込み機能への追随。issue #109）。タグのみ配布想定（Release・資産なし）。
- Claude Code 向けの intake 起点スキル雛形 `templates/claude-skill-intake.md` を追加（規範を複製せず参照だけする薄いスキル）。あわせて `shared-ai-rules.md` 8 章に「実行環境の機構が固定ファイル名を要求する場合はその限りでない」旨の例外を 1 行追記（issue #111）。判定基準の追記・雛形追加のみで後方互換。
- `templates/project-ai-rules.md` の「レビューの起動方法」節に、`bash scripts/loop-gate.sh` を単一入口とする項目（`verify.sh`→第二意見の直列化・`LOOP_GATE_REVIEW_CMD` での差し替え/無効化）と、リモート最終ゲートの記入欄（1 回に限定・参照先明記）を追加した（issue #114）。雛形の記入欄追加のみで後方互換。

### Highlights
- **リモート最終ゲートの緩和（#113）**: 従来「1 回だけ**手動で**要求する」としていた記述を「1 回だけ要求する」へ改め、守るべきは「手動であること」ではなく**要求回数を 1 回に限定すること**だと明示した。回数が 1 回に限定されるなら手動でも機構による自動要求でもよく、機構で自動化する場合は**再要求されないイベントに限定する**（例: `pull_request` の `opened` のみ、`synchronize` では再要求しない）ことを条件として明記した。「2 巡目以降の軽微な指摘は人間が却下する（AI 同士を往復させない）」とは矛盾しない（自動要求は PR 作成時 1 回のみで往復を生まない）。
- **Copilot 雛形の配布（#113）**: 規範はベンダー中立のまま、具体機構は `templates/copilot-review.yml` として提供する。DCB が `--with-copilot` 選択時のみ `.github/workflows/copilot-review.yml` へ配置する分離を守り、他ベンダーのリモートレビュー利用者に強制しない。雛形は `types: [opened]` 限定で「1 回だけ」を機構保証し、フォーク PR をスキップ、トークンは `COPILOT_REVIEW_TOKEN || GITHUB_TOKEN` にフォールバックする。前提（所有者の Copilot code review 有効化が無いと 422）をコメントに明記。
- `SMALL_FIX_EXEMPT_MEETS_CRITERIA` の適用可否を判定する基準が未定義だったギャップを埋めた（免除条件自体がどこにも書かれていなかった）。
- 非該当例に「原因が特定できていない不具合の修正」を明記し、最も起きやすい誤判定を既存の `INVESTIGATE_EXEMPT` へ正しく振り分ける。利用側（`ojos/code-narrative`）で運用実績のある文面を規範側へ還元（issue #110）。
- `gemini-review.sh` は非対話実行（スクリプト直接呼び出し・CI）される。rc 注入だけでは非対話実行に `.env` が効かないため、冒頭で隣接する `load-project-env.sh` を明示的に読み込むよう配線した。ローダーが無い構成（規範のみの単独導入など）でも壊れないよう、存在チェック付きで source する（issue #109）。
- **Claude intake スキル雛形（#111）**: 規範（`intake/`）は「intake の要否をどう判定するか」を定めるが、Claude Code がそれをいつ読むかは skill が起点になる。`templates/claude-skill-intake.md` は判定基準・`reason_code` 一覧・intake 票の項目定義を**一切複製せず**、`intake/REASON_CODES.md` / `intake/intake-template.md` / `role-contracts/intake-manager.md` を参照するだけの薄いスキル。frontmatter に発火条件（実装依頼・バグ修正・機能追加等で使い、質問・説明・調査のみでは使わない）を持ち、「判定に迷えば intake 必須側へ倒す」方針とその根拠（安全側の既定）を明示する。DCB が `--with-claude` 指定時に `.claude/skills/intake/SKILL.md` へ配置する。
- Claude Code の機構はスキル定義ファイル名を `SKILL.md` に固定するため、8 章の `lower-kebab-case.md` 規則と衝突する。これまで各利用側の入口ファイルで毎回宣言していた例外を、8 章へ 1 行足すことで規範側に一本化した（利用側での重複宣言が不要になる）。

### Breaking Changes
- なし（判定基準の追記・後方互換の雛形追加。コードの改名・削除を伴わない）。

### Verification
- [ ] preflight 全通過（規範のリンク検査、タグ不変性）
- [ ] archive tarball から規範一式が取得できることをリリース経路で確認

## v0.1.2

### Summary
- 入口ファイル雛形 `templates/entry.md` から「導入時の調整」節を削除。タグのみ配布（Release・資産なし）。

### Highlights
- 「導入時の調整」節は「調整が済んだら削除してよい」という自己削除指示付きの補足で、規範を `.ai-playbook` 以外へ再配置する場合の案内だった。この節が入口ファイル（`CLAUDE.md` / `.github/copilot-instructions.md`）へそのまま複製され、生成物にメタ指示が残置していた（devcontainer 自己診断 F-6）。
- DCB は規範を常に `.ai-playbook` へ標準配置するため調整の余地がなく、当該節を削除した。

### Breaking Changes
- なし（後方互換の雛形整理）。

### Verification
- [ ] preflight 全通過（規範のリンク検査、タグ不変性）
- [ ] archive tarball から規範一式が取得できることをリリース経路で確認

## v0.1.1

### Summary
- ループコーディングのワークフロー規範を追加し、既存規範を追随更新。タグのみ配布（Release・資産なし）。

### Highlights
- 新規: `loop-workflow.md`（ループコーディングの正本規範。受け入れ検証の機械ゲート化・収束規律・verify ランナー契約）、`loop-coding-guide.md`（従来との違い・運用の解説ガイド）。
- 更新: `shared-ai-rules.md`・`review-workflow.md`・`intake/intake-template.md`・`role-contracts/implementer.md`・`task-playbooks/plan-breakdown.md`・`README.md` をループ入口ゲート／自動提案経路へ追随。

### Breaking Changes
- なし（後方互換の規範追加・更新）。

### Verification
- [ ] preflight 全通過（規範のリンク検査、タグ不変性）
- [ ] archive tarball から規範一式が取得できることをリリース経路で確認

## v0.1.0

### Summary
- 配布リポジトリをクリーンな履歴で再作成した、新世代の初回リリース。タグのみ配布（Release・資産なし）。

### Highlights
- 内容は旧世代 v0.1.0 と同一（shared-ai-rules、role-contracts、task-playbooks、review-workflow、intake の規範一式）。
- 履歴・タグを新規に作成。コミット作者情報は `Ido <ido@ojos.jp>` に統一。

### Breaking Changes
- 旧世代のタグ v0.1.0 とコミット SHA は無効。submodule / subtree / tarball で固定している場合は参照 SHA・タグ取得先を新世代へ更新する。

### Verification
- [x] preflight 全通過（規範のリンク検査、タグ不変性）
- [x] archive tarball から規範一式が取得できることをリリース経路で確認
- [x] コミット作者・コントリビューターが単一 identity であることを確認
