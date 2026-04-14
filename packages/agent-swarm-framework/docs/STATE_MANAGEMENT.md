# ステート管理の全体像とProject連携

## 1. 基本方針
- **GitHubを正の状態面**とし、issue/PR/Projectで全体進捗・担当・依存を一元管理
- **runtimeファイルは補助的な一時状態**として扱い、不整合時はGitHub側を優先

## 2. Project連携によるリアルタイム可視化
- Projectボードで全issue/PR/ワーカー/ラインの進捗・担当・優先度を可視化
- カスタムフィールドで「ラインID」「エージェント名」「優先度」等を追跡
- カンバン/テーブル/タイムライン等のビューで多角的に状況把握
- 担当・進捗・優先度の変更はProject/issue/PR間で双方向同期

## 3. 自動化・運用例
- PRマージやラベル付与で自動カラム移動（組み込み自動化/Actions/gh project）
- ワーカー/エージェントごとの負荷・滞留・依存関係もProject上で即時把握
- テンプレート化で複数プロジェクト・ライン横断の運用標準化

## 4. ベストプラクティス
- Projectボードを「全体」「ライン別」「担当別」など複数用意し、状況に応じて切替
- カスタムフィールド設計は現場運用に合わせて柔軟に拡張
- ステート不整合時は必ずGitHub側を正とし、runtime側を再生成

---

## 参考: Projectテンプレート・自動化スクリプト
- template-project/github/project-board.json
- template-project/github/create-project-board.sh
