# Runtime Operations

`runtime-core` は次を含む。

- gate scripts
- monitor scripts
- worker scripts

初期 package は、導入後すぐに最小運用を開始できることを目標にする。  
状態管理は GitHub を正、runtime file を補助として扱う。

---

## リリース手順（パッケージ配布）

### 1. 事前確認

```bash
# 重要成果物チェック
bash scripts/check-critical-artifacts.sh --strict

# init CLI の最小E2E
bash packages/agent-swarm-framework/tests/e2e-init.sh
```

### 2. 配布アーカイブ作成

```bash
git archive --format=tar.gz -o agent-swarm-framework-<version>.tar.gz HEAD:packages/agent-swarm-framework
```

GitHub Release 運用は、現時点では本モノレポ内ではなく専用の ASF リリースリポジトリ側で行う。
`agent-swarm-framework-v<version>` タグを契機に、同等の検証とアーカイブ生成を実行する。

### 3. 配布時メタ情報

配布時は次を必ず添付する。

- 対象コミット SHA
- スキーマ version（`config.schema.json` の `version`）
- 互換性ルール（下記）
- 実行済み検証コマンド結果

タグ運用例:

```bash
VERSION="$(tr -d '[:space:]' < packages/agent-swarm-framework/VERSION)"
git tag "agent-swarm-framework-v${VERSION}"
git push origin "agent-swarm-framework-v${VERSION}"
```

---

## 更新運用（既存導入先への反映）

### 推奨フロー

1. 新規ブランチを作成
2. package ファイルを更新
3. `bash packages/agent-swarm-framework/tests/e2e-init.sh` を実行
4. PR を作成
5. レビュー通過後にマージ

### 更新時の注意

- `packages/agent-swarm-framework/config.schema.json` を正規スキーマとして扱う
- 破壊的変更は必ず `version` のメジャー更新を伴う

---

## Mesh Pull 最小仕様（Phase 1）

line worker は、キューが空のときに GitHub backlog (`label: line-task`) から候補を pull できる。

最小判定条件:
- `blocked` ラベルが付いていない
- `depends-on` または依存セクションで参照される issue がすべて `CLOSED`
- `priority` を優先（`P0 > P1 > P2 > P3 > その他`）
- 同優先度では issue 番号が小さいものを優先

競合回避（最小）:
- `orchestration/runtime/mesh-pull.lock` によるローカル排他
- issue コメント `mesh_claimed_by: line:<id>` を付与して重複 claim を防ぐ

---

## Dynamic Scaling と runner 容量

orchestrator worker は `runnable issue 数` を算出した後、`self-hosted` 容量上限で再キャップする。

容量ファイル（任意）:
- パス: `orchestration/runtime/self-hosted-capacity.json`
- フィールド: `available_runners` (number)

例:

```json
{
	"available_runners": 2
}
```

未指定時は `MAX_LINE_WORKERS` を上限として扱う。

---

## 互換性ルール

| 変更種別 | 例 | version ルール |
|---------|----|----------------|
| 互換あり追加 | 任意フィールド追加、非必須設定追加 | `1.x -> 1.y` |
| 条件変更 | enum 値追加、分岐条件拡張 | `1.x -> 1.y`（要注記） |
| 破壊的変更 | required 追加、既存 enum 値削除、既存キー削除 | `1.x -> 2.0` |

---

## トラブルシュート

| 症状 | 主な原因 | 対処 |
|------|----------|------|
| `--non-interactive` 実行時に失敗 | `--config` 未指定 | `--config <file>` を併用 |
| 2回目適用で上書きされる | `manifest` が target にない | `init.sh` 経由で適用し metadata を生成 |
| milestone/issue が作成されない | `--skip-github` 指定 or `gh` 未認証 | `gh auth status` を確認し再実行 |
| 重要ファイルが消える | untracked/stash の取り扱い漏れ | `check-critical-artifacts.sh --strict` を cleanup 前に実行 |

---

## 監査ログ指針

リリースごとに以下を記録する。

- version
- 配布アーカイブ名
- コミット SHA
- E2E テスト結果
- 既知の制約・次バージョン課題

---

## 外部委譲 I/O 契約

merge / review / dependency update の外部委譲契約は次を正とする。

- [EXTERNAL_DELEGATION_IO_CONTRACT.md](./EXTERNAL_DELEGATION_IO_CONTRACT.md)

この契約は、`command-dispatch` 入力、委譲実行結果、状態遷移（success / retryable_failure / terminal_failure）を含む。
