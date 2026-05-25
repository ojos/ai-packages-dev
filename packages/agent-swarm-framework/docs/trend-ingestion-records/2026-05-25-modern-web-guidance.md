# Trend Ingestion Record: Modern Web Guidance (2026-05-25)

Decision: adopt
Source: https://developer.chrome.com/docs/modern-web-guidance?hl=ja
Summary: Modern Web Guidance は継続更新される Web 実装ガイダンスであり、UI/性能/セキュリティ領域の実践知として取り込み価値がある。
Impact: task-playbooks に `web-modernization-modern-web-guidance.md` を追加。
Validation: `bash packages/agent-swarm-framework/tests/e2e-init.sh` PASS。
Risk: 無条件適用すると既存仕様との衝突や過剰最適化が発生し得る。
Rollback: 追加 playbook を削除し、参照リンクを除去する。

## Notes

- 本取り込みは「外部推奨を内部標準へ正規化する」実行例として採用。
- 適用は段階導入（candidate -> canary -> full）を前提とする。
