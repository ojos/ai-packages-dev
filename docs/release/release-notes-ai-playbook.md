# ai-playbook Release Notes

新世代（2026-07-17 リポジトリ再作成後）のリリースノートです。

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
