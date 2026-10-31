---
paths:
  - ".ai-playbook/intake/**"
  - ".ai-playbook/task-playbooks/plan-review.md"
  - ".github/ISSUE_TEMPLATE/implementation.md"
---

# intake の実行フローと制約

地図（`.github/project-ai-rules.md`）の「intake フロー」の続きです。起動条件（明示起動・自動提案・提案しない条件）は地図が持ち、起動後の Step 1〜9 と制約をここへ置きます。

## 実行フロー

```
Step 1: 要件テキストの確定
  - 起動要求に要件テキストが添えられている場合、そのテキストをそのまま使用する
  - 要件テキストが添えられていない場合、要件を対話で引き出す
  - 自動提案から承認された場合、承認の根拠となった直近のユーザー発話を要件テキストとして使用する

Step 2: 意図の解釈・確認（インプット確認）
  - 入力テキストの内容を解釈し、以下をユーザーに提示して確認する:
      - 解釈した目的（何を実現したいか）
      - 想定する変更の範囲・種別（新機能/修正/設計変更 等）
      - 不明点があれば質問する
  - ユーザーが「合っている」と確認するまで次へ進まない

Step 3: 設計妥当性の相談（条件付き）
  - 以下のいずれかに該当する場合のみ相談を起動する:
      - 設計方針に曖昧さ・矛盾がある
      - スコープ境界が不明確（何が in/out か判断できない）
      - 責務・型契約に影響する懸念がある
      - 優先順位の判断が難しい
  - 上記に該当しない場合はスキップしてよい
  - 相談の結論は goal / scope.in / acceptance に反映してから次へ進む
  - 進行と記録は consult-facilitator ロール契約に従う

Step 4: intake 票の下書き
  - .ai-playbook/intake/intake-template.md の必須構造を埋める
  - 必須: goal / scope.in / acceptance / priority
  - 任意: scope.out / constraints

Step 5: intake 確認ブロックをユーザーに提示・確認
  - goal / scope.in / scope.out / constraints / acceptance / priority をチャット上で表示
  - ユーザーが修正・承認するまで次へ進まない

Step 6: 計画整合性レビュー（必須）
  - 確認ブロックの内容を .ai-playbook/task-playbooks/plan-review.md の観点 A で審査する
    （観点の一覧と、指摘の出し方はそちらが正本。ここへ複製しない）
  - 矛盾・漏れを発見した場合は、同手順の出し方（問題と修正案の表、修正の差分）で提示し、
    Step 5 へ差し戻す（Step 5 の承認のやり直しが、同手順の「承認し直し」にあたる）
  - 機械で判定できない作業の扱いと、「レビュー通過」の明示も同手順に従う

Step 7: 最終意図確認（実行前ゲート）
  - issue 化の直前に、以下を要約してユーザーへ確認する:
      - 作成予定の issue タイトルと内容サマリー
      - 「この内容で進めてよいか？」を明示的に確認する
  - ユーザーが承認するまで issue を作成しない

Step 8: ユーザー承認後に issue 化

Step 9: 実装委譲へ移行
  - issue 作成完了後、「実装委譲パターン」へ引き継ぐ
```

## 制約

- Step 7（ユーザー承認）なしに issue を作成してはなりません。
- intake の要否判定と、その根拠の分類は `.ai-playbook/intake/REASON_CODES.md` に従います。
- intake-manager の権限境界（`.ai-playbook/role-contracts/intake-manager.md`）に従います。
- intake はループコーディングの入口フェーズを担います。ループ対象の作業は、Step 6 で機械判定できる acceptance を確定してから実装委譲へ移します（`.ai-playbook/loop-workflow.md`）。ループ非対象と判定した作業は、その旨を intake 票に明記します。
