# External Delegation I/O Contract

この文書は、`merge` / `review` / `dependency update` を将来外部委譲するための最小I/O契約を定義する。

対象スコープ:
- `scripts/command-dispatch.sh` の入力契約
- worker / closer / external executor の責務境界
- 成功・再試行可能失敗・終端失敗の状態遷移
- GitHub 状態面（Issue / PR / Project）に反映する最小項目

---

## 1. 共通入力契約

`command-dispatch` へ投入する最小ペイロード:

```json
{
  "issuer": "orchestrator|closer|implementer|intake-manager|human",
  "command": "/review|/merge|/apply",
  "scope": "pr:#123|issue:#456|consult",
  "options": {
    "execute": true,
    "priority": "high|medium|low",
    "comment": "free text"
  }
}
```

バリデーションの原則:
- `issuer` と `command` の許可組み合わせは `command-validate.sh` を正とする。
- `scope` の形式（`pr:#N`, `issue:#N`, `consult`）は fail-fast で検証する。
- `options` は JSON として妥当であること。

---

## 2. 責務境界

### Closer
- `/review` と `/close pr` の実行主体。
- PR 状態判定（open/draft/approved/changes_requested/merged/closed）の一次判断を担う。
- 重大指摘時は merge へ進めず、修正ループへ戻す。

### Orchestrator
- `/merge` の実行要求を受けるが、検証結果が不十分な場合は拒否または保留へ分岐する。
- `/apply` `/defer` `/backlog` を用いて後続アクションをキュー化する。

### External Executor（将来）
- 委譲対象コマンドの実処理のみ担当（例: 自動マージ、依存更新PR作成）。
- 判定ロジックは保持せず、入力契約に従った実行結果を返す。

---

## 3. 委譲領域ごとの契約

### 3.1 Review Delegation

入力:

```json
{
  "command": "/review",
  "scope": "pr:#123",
  "options": {
    "checklist": ["tests", "security", "regression"],
    "blockingThreshold": "high"
  }
}
```

出力:

```json
{
  "result": "success|retryable_failure|terminal_failure",
  "review": {
    "high": 0,
    "medium": 1,
    "low": 2,
    "summary": "..."
  },
  "artifacts": {
    "reportPath": "orchestration/logs/<id>-review.md"
  }
}
```

### 3.2 Merge Delegation

入力:

```json
{
  "command": "/merge",
  "scope": "pr:#123",
  "options": {
    "policy": "manual|conditional|auto",
    "requireApprovedReview": true,
    "requireGreenChecks": true
  }
}
```

出力:

```json
{
  "result": "success|retryable_failure|terminal_failure",
  "merge": {
    "merged": true,
    "sha": "<commit-sha>"
  }
}
```

### 3.3 Dependency Update Delegation

入力:

```json
{
  "command": "/apply",
  "scope": "issue:#456",
  "options": {
    "kind": "dependency-update",
    "strategy": "patch-only|minor|all",
    "allowlist": ["npm", "go"]
  }
}
```

出力:

```json
{
  "result": "success|retryable_failure|terminal_failure",
  "update": {
    "branch": "deps/update-20260410",
    "pr": 789
  }
}
```

---

## 4. 状態遷移契約

共通結果:
- `success`: 後続フェーズへ進める。
- `retryable_failure`: 指数バックオフ付きで再試行キューへ戻す。
- `terminal_failure`: dead-letter へ移送し、人間または orchestrator の再計画を要求する。

最小遷移:

1. `queued`
2. `executing`
3. `success` or `retryable_failure` or `terminal_failure`

`retryable_failure` 時:
- `attempts += 1`
- `attempts > max_retries` で `terminal_failure` に昇格

---

## 5. GitHub 反映最小項目

Issue/PR コメントに残す最小キー:
- `command`
- `scope`
- `result`
- `next_action`
- `artifact`（あれば）

Project 反映最小項目:
- `Status`
- `Priority`
- `Next Action`
- `Owner Role`
- `Due Date`

---

## 6. 互換性ポリシー

- キー追加は後方互換とする（既存キーは削除しない）。
- 列挙値の削除・意味変更は breaking change とし、設定 version のメジャー更新を伴う。
- 外部委譲を有効化していない環境では、既存 worker 処理へフォールバックする。
