---
name: 実装タスク
about: ASF ワークフロー内で委譲レビューを伴う実装作業
labels: implementation,asf-workflow
---

## 要約（必須）

<!-- 2〜6行で簡潔に記載。目的、スコープ、期待結果を含めること。 -->

## 詳細

<!-- 背景や補足説明を記載する。要約との矛盾がないこと。 -->

## 実行ディスパッチ注意

<!-- Issue を作成しただけでは line 実行は開始されない。スコープ確定後に scripts/worker/delegate-issue-implementation.sh で実行可能タスクを投入する。 -->

## 📋 実装スコープ

<!-- スコープを明確にすると委譲判断が容易になる -->

### 作成/更新対象ファイル
- [ ] 対象ファイルまたはワイルドカードを記載（例: `scripts/gate/**.sh`, `packages/agent-swarm-framework/...`）

### 受け入れ条件
- [ ] （条件を記載）
- [ ] テストがすべて成功する
- [ ] root/runtime-core の整合性を維持する（該当時）
- [ ] マージ前にコードレビューを完了する

### 必要なテスト範囲
- [ ] Unit tests: 実施 / 非実施
- [ ] Integration tests: 実施 / 非実施
- [ ] E2E tests: 実施 / 非実施

### 破壊的変更
- [ ] なし
- [ ] 軽微（後方互換あり）
- [ ] 重大（後方互換なし）

---

## 🤝 委譲メタデータ

### エージェント協調向け

**委譲ステータス**:
- [ ] 実装前に code review が必要（**line worker へ委譲**）
- [ ] エージェントの自実装で対応可能（小規模/ドキュメント）
- [ ] line worker 割り当て待ち

**想定工数**:
- [ ] small (< 1 hour)
- [ ] medium (1-4 hours)
- [ ] large (> 4 hours)

**他作業のブロッキング有無**
- [ ] NO（並行実行可）
- [ ] YES（blocking: [issue番号を列挙]）

---

## 📝 実装メモ

<!-- 任意: 実装担当向けの補足情報を記載 -->

---

## Runtime 委譲（Auto-Enqueue 任意有効）

安全条件を満たす場合のみ auto-enqueue を有効化する。

- [ ] Add labels: `line-task` and `auto-enqueue`
- [ ] Dependencies are closed
- [ ] 要約が記載されている
- [ ] 受け入れ条件が充足している

auto-enqueue 必須項目:

task_command: <single-line shell command>
line: auto-001

例:

task_command: bash packages/agent-swarm-framework/tests/conversation-entry.sh >/dev/null
line: auto-001

