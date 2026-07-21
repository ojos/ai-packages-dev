# @intake 自動提案・ループ入口ゲート 記録

`@intake` を明示起動のみから自動提案経路へ拡張し、intake をループコーディングの入口フェーズとして機械判定ゲートで接地しました。

本文書は意思決定と実施を記録として完結させたものです。

- 起案日: 2026-07-21
- 完了日: 2026-07-21
- 状態: **完了**
- 証跡コミット: `636db75`（ブランチ `feat/intake-auto-suggest-loop`）

## 背景

`@intake`（[.github/project-ai-rules.md](../../.github/project-ai-rules.md) の @intake コマンド節）は、メッセージ先頭に `@intake` を付けた場合のみ Intake Manager フローを起動する明示起動のみだった。「セッション内容から自動で intake を起動できないか」という要望を起点に、自動化の可否と、intake がループコーディング（[.ai-playbook/loop-workflow.md](../../.ai-playbook/loop-workflow.md)）の入口として十分かを検討した。

## 決定事項

| # | 論点 | 決定 | 根拠 |
|---|---|---|---|
| A | intake の自動起動方式 | **提案型（検出→確認）**。要件らしい発話を検出したら AI が intake 化を提案し、ユーザー承認後にフロー開始 | 完全自動は雑談・調査質問を 9 ステップのゲートに巻き込む誤検出リスクが高く、「探索的会話を妨げない」現行設計と衝突する。提案止まりなら Step 7 承認ゲートより手前で止まり両立する |
| B | 誤検出の抑制 | **非トリガー条件と過剰提案の抑制を明文化**。質問・調査・レビュー・雑談・発散段階では提案しない。一度見送られた要件は明確な再要求まで再提案しない | 自動検出は確定的パーサでなく AI 判断に依存するため、保護条件を規約側に固定する |
| C | intake とループの接続強度 | **intake = ループの入口フェーズと明文化**し、Step 6 で機械判定できる acceptance を確定してから委譲する | 従来は intake-template 経由の間接参照のみで、acceptance の機械判定が「可能な限り」の努力目標に留まり、ループを閉じられない acceptance が入口を素通りし得た |
| D | 機械判定できない作業の扱い | **「ループコーディング非対象」を intake 票に明記して通過可**。完了は人が確定し自律反復ループには載せない | 純粋な設計相談・ドキュメント合意など本質的に機械判定を持てない作業を無理に機械判定へ矯正しないための逃げ道 |

## 実施結果

| 対象 | 変更 |
|---|---|
| [.github/project-ai-rules.md](../../.github/project-ai-rules.md) @intake 節 | 起動経路を「明示起動」「自動提案」の 2 経路へ整理。自動提案のトリガー条件・非トリガー条件（探索的会話の保護）・過剰提案の抑制を追加 |
| 同 Step 1 | 自動提案から承認された場合、承認根拠となった直近発話を要件テキストに使用する旨を追記 |
| 同 Step 6（計画整合性レビュー） | 審査項目に「acceptance が非対話で実行でき終了コードで合否判定できる形か」を追加。満たせない場合の差し戻し／ループ非対象明記の扱いを規定 |
| 同 制約 | intake がループコーディングの入口フェーズを担うことと、対象／非対象の分岐を明文化 |
| [.ai-playbook/intake/intake-template.md](../../.ai-playbook/intake/intake-template.md) | acceptance 要件を「可能な限り機械判定」から「ループ対象は機械判定検証を最低 1 つ含める」へ強度統一。満たせない場合は Step 6 で非対象明記 |

## 設計上の性質（残す判断根拠）

- `@intake` はハーネスがパースする本物のコマンドではなく、AI が Markdown を読んで解釈する規約である。したがって「自動起動」もハーネス機能ではなく規約文書の記述で実現し、検出は確定的でなく AI 判断に依存する。この非決定性を前提に、誤検出しても提案止まりとなる提案型を選んだ。
- 硬直（全作業を機械判定へ矯正）と穴（緩くて素通り）の両方を避けるため、機械判定を原則必須にしつつ「ループ非対象」の明示的な逃げ道を用意した。

## 関連

- 正本: [.github/project-ai-rules.md](../../.github/project-ai-rules.md)（@intake コマンド節）
- ループ規範: [.ai-playbook/loop-workflow.md](../../.ai-playbook/loop-workflow.md) / 解説: [.ai-playbook/loop-coding-guide.md](../../.ai-playbook/loop-coding-guide.md)
- ロール契約: [intake-manager](../../.ai-playbook/role-contracts/intake-manager.md) / [implementer](../../.ai-playbook/role-contracts/implementer.md)
