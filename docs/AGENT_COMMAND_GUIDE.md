# Agent Command Guide / エージェント指示ガイド

このガイドは、Copilot agent（このエージェント）への指示内容を明確にするためのものです。

This guide clarifies how to instruct the Copilot agent (this agent) to perform specific tasks in the ASF workflow context.

## クイックリファレンス / Quick Reference

### 実装フェーズの進め方

| あなたの指示 | エージェントの解釈 | 結果 |
|------------|------------------|------|
| "進めて下さい" | ASF workflow に沿って次フェーズへ進行 | Issue 作成 → line worker に委譲 OR 自分で実装（小規模の場合） |
| "やってしまえ" | 直接コード実装する（委譲なし） | すぐに実装コード作成 → commit → push |
| "確認して" | 分析・検証のみ（実装なし） | 調査結果をレポート、コード変更なし |
| "#N 実装して" | Issue #N を実装する | Issue scope 確認 → 委譲判定 → 実装 |
| "レビューして" | Code review を実施 | PR/commit を確認、approve/suggest |

### Issue 言語ルール（標準）

- `implementation:` / `feature:` issue は日英併記を必須とする
- 冒頭に `English Summary` を置く
- 規範・受け入れ条件は英語で記述し、日本語は同義補足として併記する

### 実装委譲の標準実行ルール

- issue 作成やコメント追加だけでは line worker は動かない
- 実行可能な委譲には `scripts/worker/delegate-issue-implementation.sh` を使う
- line worker が処理するのは `line:<id>` scope の `/implement` であり、実行には `task-command` が必要

### Issue クローズの標準実行ルール

- クローズ前に必ず理由コメントを残す（completed/superseded/duplicate/invalid/deferred）
- `superseded` / `duplicate` は置換先 issue を明記する
- 実装 issue は検証結果（例: `PASS=24`、`no-op completed`）をコメントに含める
- 標準クローズは次のスクリプトを使う

```bash
bash scripts/worker/close-issue-with-policy.sh \
   --issue-number <N> \
   --reason <completed|superseded|duplicate|invalid|deferred> \
   --summary-en "<English summary>" \
   --summary-ja "<日本語要約>" \
   --related "#12,#13"
```

---

## 詳細な指示パターン / Detailed Instruction Patterns

### Pattern 1: 設計完了後、実装へ進む

**状況**: 設計決定が完了し、実装に進みたい

**指示**:
```
進めて下さい
```

**エージェント動作**:
1. 設計内容を確認
2. GitHub issue を作成（実装スコープ明記）
3. Issue を consult log に記録
4. **委譲判定を実施**:
   - 複雑な実装 → line worker に委譲（issue 作成で終了）
   - 小規模実装 → 自分で実装可（ドキュメント修正など）
5. 判定結果をユーザーに報告

**結果**:
- Line worker 委譲の場合: PR が戻ってくるのを待つ指示
- 自実装の場合: コード変更を実施

---

### Pattern 2: 直接実装を指示

**状況**: 小規模な修正や明確な実装タスクを直接やってほしい

**指示**:
```
/issue #15 のエラーハンドリング追加、やってしまえ
```

**エージェント動作**:
1. Issue #15 の内容を読む
2. Consult log に「self-implement」決定を記録
3. 実装コードを直接作成 → commit → push

**結果**: 直接コード変更が reflected される

---

### Pattern 3: 分析・設計のみ

**状況**: 実装ではなく、調査・分析・設計をしてほしい

**指示**:
```
conversation-entry.sh のエラーハンドリング戦略を分析して
```

**エージェント動作**:
1. コードを調査
2. エラーケースを分類
3. 対策案を提案
4. **コード変更なし**

**結果**: 分析レポートのみ、実装には進まない

---

### Pattern 4: 複数タスクの優先順位指定

**状況**: 複数の実装タスクがあり、優先順位を指定したい

**指示**:
```
#7 の拡張機能追加（高優先）を委譲してから、#8 の test 作成（低優先）をお願いします
```

**エージェント動作**:
1. #7 issue 確認 → 委譲判定 → line worker へ委譲
2. Consult log に優先度を記録
3. #8 issue 確認 → 判定 → 実装 OR 委譲
4. 順序を consult log に記録

**結果**: 複数 issue が priority 順に workflow に載る

---

## 委譲 vs 自実装の判定基準 / Delegation Decision Criteria

### 委譲する（line worker に任せる）

以下のいずれかに該当する場合：

1. **複雑な実装**
   - 新規ファイル作成（100行以上）
   - 複数ファイル修正を伴う
   - 既存ロジックの大幅変更

2. **テストが必須**
   - Unit test が必要
   - Integration test が必要
   - E2E test が必要

3. **Code review が必要**
   - パッケージ層への変更
   - Architecture に影響する変更
   - Security-related な変更

4. **複数エージェント間の調整が必要**
   - 別エージェントのコード利用
   - 外部 API との連携

### 自分で実装する（委譲しない）

以下のいずれかに該当する場合：

1. **ドキュメント作業**
   - README 作成・編集
   - ガイドドキュメント作成
   - コメント追加

2. **小規模実装**
   - 50行以下の新規ファイル
   - 簡単な bug fix（1-2行変更）
   - 設定ファイル変更

3. **既に検証済みの変更**
   - テスト済みのコード修正
   - 確定した小規模フィーチャー

4. **ユーザー明示指示**
   - "やってしまえ" と指示された
   - "直接実装" と明記された

---

## Consult Log への記録パターン / Consult Logging Patterns

### 委譲決定の記録

```bash
bash scripts/gate/command-dispatch.sh \
  --issuer conversation-gate-agent \
  --action /delegate \
  --scope "issue:#7" \
  --options '{
    "decision": "delegate_to_line_worker",
    "issue_title": "conversation-entry.sh エラーハンドリング強化",
    "scope_description": "error_json関数追加、6つのエラーケース処理",
    "estimated_effort": "medium",
    "blocking": false
  }'
```

### 自実装決定の記録

```bash
bash scripts/gate/command-dispatch.sh \
  --issuer conversation-gate-agent \
  --action /delegate \
  --scope "issue:#100" \
  --options '{
    "decision": "self_implement",
    "reason": "document_edit",
    "issue_title": "README.md 更新",
    "scope_description": "conversation-gate 使用例追加",
    "estimated_effort": "small"
  }'
```

---

## よくある質問 / FAQ

### Q: "進めて下さい" と言ったら何が起きるのか？

A: 
1. 現在のフェーズを確認
2. 次フェーズで必要な issue/task を作成
3. その issue が「委譲対象」か「自実装」か判定
4. 判定結果をユーザーに報告
5. 委譲の場合は line worker を待つ、自実装の場合は進行

### Q: 修正したいコードがあったら、何と言えばいい？

A: 以下のいずれか:
- 小規模修正 → "バグを直してしまえ"
- 大規模修正 → "issue #N を実装してもらう" (委譲される)
- わからない場合 → "進めて下さい" (エージェントが判定)

### Q: Consult log とは何か？

A: ASF workflow の意思決定ログ。以下が記録される:
- 誰が何を決めたか
- なぜそう決めたか
- 優先度、effort 推定
- Delegation vs self-implement の判定理由

エージェント間の透明性と監査に使用。

### Q: Line worker が不可用だったら？

A: 
- Consult log に「worker_unavailable」と記録
- ユーザーに通知
- 自動フォールバック（小規模タスク）OR manual intervention 待機

### Q: Code review を飛ばしたい場合は？

A: 推奨されません。以下のいずれかで対応:
- "やってしまえ"と指示（小規模のみ）
- 別途 reviewer を指定（"@reviewer_name に review してもらう"）
- デフォルト: code review gate は bypass しない（ASF policy）

---

## Workflow Coordination Checklist

各 issue 作成時、以下のチェックリストを念頭に置きます:

- [ ] Issue title に接頭辞がある？（"implementation:", "design:", etc.）
- [ ] Issue body に実装スコープが明記されている？
- [ ] Acceptance criteria が定義されている？
- [ ] テスト要件が記載されている？
- [ ] Delegation 判定に必要な情報は十分か？
- [ ] Consult log への記録タイミングは明確か？

### Auto-Enqueue 条件（`feature: 条件付きで issue から自動enqueue`）

以下を満たす issue のみ自動で line 実行キューに投入される:

- [ ] title が `implementation:` または `feature:` で開始
- [ ] labels に `line-task` と `auto-enqueue` が付与されている
- [ ] issue に `English Summary` と `Acceptance Criteria` がある
- [ ] 依存 issue がすべて CLOSED
- [ ] `task_command:` が本文に定義されている

この条件を満たさない issue は自動enqueueされず、手動委譲（`delegate-issue-implementation.sh`）を使用する。

これが整っていれば、ASF workflow がスムーズに流れます。

---

## Next Steps

- このガイドを `.github/` に置いて、新規エージェント onboarding 時に参照させる
- Delegation decision の自動化を検討（線引き基準を code に embed）
- Line worker availability check の実装化

