# GitHub Actions Setup

初期 package が正式サポートする remote executor は `github-actions` のみ。

## 実行前提（2026-04-10 確定）

- remote 実行は `self-hosted` runner を正とする。
- AI 実行インターフェースは CLI 呼び出しを正とする（`claude` / `gemini` / `codex` など）。
- GitHub-hosted runner は検証対象外とし、必要な場合は別設計として扱う。

## スコープ

現在の実装スコープ:
- issue event を起点にした planner / dispatcher ワークフロー雛形
- implementer による PR 作成フローの土台

未実装または段階対応:
- reviewer / merge の remote 自動化
- mesh 型（各ライン自律 pull）への全面移行

## self-hosted 運用メモ

- runner は外向き通信で GitHub からジョブを取得する。
- 実行環境の依存コマンドと認証状態は self-hosted 側で管理する。
- ローカル検証で使用する runner と本番 runner は分離する。

## 参考

- 設計全体: `docs/architecture.md`
- 完了条件: `docs/VISION_AUTONOMOUS_ORCHESTRATION.md`
