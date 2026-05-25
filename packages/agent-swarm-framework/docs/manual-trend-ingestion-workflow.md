# Manual Trend Ingestion Workflow

この文書は、開発モノリポ上で外部トレンドを手動取り込みし、ASF 標準へ反映するための実行手順を定義する。

## 目的

- 外部トレンドを安全に取り込み、ASF の標準運用へ反映する。
- 取り込み判断と検証結果を追跡可能な形で残す。

## スコープ

- 配布元 ASF パッケージへの取り込み。
- 利用プロジェクト個別の最適化は対象外。

## 前提条件

- 作業開始時に `git status` がクリーンである。
- 取り込み候補の出典 URL と要約を準備している。
- 検証に必要なコマンドが利用可能である。

## 実行手順

1. Intake 定義を作成する。

`goal`, `scope.in`, `scope.out`, `acceptance`, `priority` を定義する。

2. Gate の dry-run で入力整合を確認する。

```bash
bash scripts/gate/conversation-entry.sh \
  --input-text "<取り込み要件>" \
  --intent-type "implement" \
  --channel-type "vscode_chat" \
  --dry-run true
```

3. 取り込み候補を分類する。

- role-contracts へ反映する変更か。
- task-playbooks へ反映する変更か。
- 既存ルールと衝突する変更か。

4. 変更を実装する。

- `packages/agent-swarm-framework/agent-definitions/files/.multi-agent/role-contracts/`
- `packages/agent-swarm-framework/agent-definitions/files/.multi-agent/task-playbooks/`

5. 関連ドキュメントを同期する。

- `packages/agent-swarm-framework/README.md`
- `packages/agent-swarm-framework/docs/architecture.md`
- `packages/agent-swarm-framework/docs/install.md`

6. 構文とテストを実行する。

```bash
bash -n packages/agent-swarm-framework/install.sh
bash -n packages/agent-swarm-framework/tests/verify-install.sh
bash -n packages/agent-swarm-framework/tests/e2e-init.sh
bash packages/agent-swarm-framework/tests/e2e-init.sh
bash packages/agent-swarm-framework/tests/run-shell-tests.sh
```

7. 採用可否を判定する。

- `adopt`: 標準採用
- `hold`: 保留
- `reject`: 不採用

8. 判定記録を残してコミットする。

コミット本文に最低限次を残す。

- 出典
- 取り込み理由
- 影響範囲
- 検証結果
- ロールバック条件

判定記録の保存先:

- `packages/agent-swarm-framework/docs/trend-ingestion-records/`

## 判定記録テンプレート

```markdown
Decision: adopt|hold|reject
Source: <url>
Summary: <1-3 lines>
Impact: <files / roles>
Validation: <commands and result>
Risk: <known risk>
Rollback: <how to revert>
```

## 完了条件

- 変更理由と判定が記録されている。
- 検証コマンドがすべて成功している。
- リリースリポジトリへ引き渡せる差分要約が作成されている。