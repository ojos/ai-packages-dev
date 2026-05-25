# Operational PR Review Checklist

このチェックリストは、role-contracts と task-playbooks の責務分離を運用で維持するための実務チェック項目です。

## 目的

- 設計意図の逸脱を早期検出する。
- レビュー観点のばらつきを減らす。
- 変更時の見落としを減らし、判断速度を上げる。

## 対象

- role-contracts を追加・更新する PR
- task-playbooks を追加・更新する PR
- 参照ドキュメント、テスト、スクリプトを伴う構造変更 PR

## 使い方

- PR ごとに全項目を確認する。
- 該当しない項目は N/A と明記する。
- 未充足がある場合は修正または理由を記録してから承認する。

## チェック項目

1. 変更分類は明確か
- role-contracts の変更か、task-playbooks の変更か、または両方かを明記している。

2. 配置先は正しいか
- role-contracts は .multi-agent/role-contracts 配下にある。
- task-playbooks は .multi-agent/task-playbooks 配下にある。

3. role-contracts の必須セクションは揃っているか
- 目的、入力、出力、禁止事項、エスカレーション条件、完了定義が存在する。

4. task-playbooks の必須セクションは揃っているか
- 目的、入力、手順、出力、注意事項が存在する。

5. 責務混在がないか
- role-contracts に逐次実装手順を埋め込んでいない。
- task-playbooks に権限境界やロール判定ロジックを埋め込んでいない。

6. 参照関係は妥当か
- role-contracts 側の推奨タスクプレイブック参照が、実在する task-playbooks を指している。
- 不要な循環参照や重複参照がない。

7. 旧パス参照が残っていないか
- .multi-agent/skills の参照が残っていない。

8. ドキュメント同期は取れているか
- README、architecture、install、運用ガイドの説明が実体と一致している。

9. テスト更新は必要十分か
- 構造変更に応じて verify-install と e2e-init の期待値を更新している。
- 変更に必要なテスト実行結果を記録している。

10. リスクとロールバック方針は明確か
- 破壊的変更の場合、影響範囲と戻し方を PR 説明に記載している。

## 推奨エビデンス

- 旧パス残存確認の検索結果
- verify-install 実行結果
- e2e-init 実行結果
- 主要ドキュメント差分

## 判定テンプレート

- 判定: approve / request changes / hold
- 理由: 1-3 行
- 未充足項目: 項番列挙
- 次アクション: 修正担当と期限
