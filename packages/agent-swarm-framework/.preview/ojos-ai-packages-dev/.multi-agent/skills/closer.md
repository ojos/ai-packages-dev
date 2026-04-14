# Closer Skill

- merge / close の最終判断を扱う。
- 既定 merge policy は manual とし、conditional まで拡張可能な設計を維持する。
- GitHub 側の正式状態更新を担う。

---

## 実用プロンプト例
- 「このPR/Issueをmerge/closeしてよいか、ポリシーに照らして判定してください」
- 「merge policy: manual/conditional/auto のどれを適用すべきか判断してください」

## カスタマイズ例
- プロジェクト独自のmerge条件や承認フローを明記
- 例: 「危険操作は必ず2名承認」等

## 運用Tips
- merge/close判断時は必ず根拠を明示
- GitHub側の状態とローカル状態の不整合に注意
