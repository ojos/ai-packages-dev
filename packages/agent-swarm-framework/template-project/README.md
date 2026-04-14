# template-project

導入先プロジェクトごとの差し替え対象を保持するカテゴリです。

## 含まれるもの
- project overrides example
- labels definition
- bootstrap milestone / issue definitions

---

## カスタマイズ例
- `project-overrides.example.json` をコピーし、リポジトリ名・ライン構成・運用モード等を現場要件に合わせて編集
- 例: `lineIds` を3ラインや動的割当型に変更、`mergePolicy` を `conditional` に変更 など

## 運用ガイド
- `labels.json` は現場のワークフローや通知運用に合わせて追加・色分け
- `milestones.json` でマイルストーン粒度・進行順序を明確化
- `issues/bootstrap/` 配下のテンプレートは初期セットアップや自動起票に活用

## 推奨パターン
- ラベル名・マイルストーン名は短く一貫性を持たせる
- project-overridesは「displayName/projectSlug/lineIds/mergePolicy」等を必ず明記
- 導入先の運用ルール・承認フローもoverridesやissueテンプレートに反映
