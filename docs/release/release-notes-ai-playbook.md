# ai-playbook Release Notes

新世代（2026-07-17 リポジトリ再作成後）のリリースノートです。

## Unreleased

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
