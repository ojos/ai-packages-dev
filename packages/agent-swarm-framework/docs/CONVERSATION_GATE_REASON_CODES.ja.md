# Conversation Gate Reason Codes（日本語）

この文書は、ASF の会話ゲートで使用する `reason_code` の正規一覧を定義する。
これらのコードはコア判定エンジンが出力し、入口連携（IDE/チャットアダプター）が参照する。

## 対象範囲

- 会話ゲート出力契約に適用する:
  - `intake_required`
  - `reason_code`
  - `reason_message`
  - `missing_fields[]`
- 新規 intake 経路と既存 issue 流用経路の両方に適用する。

## 命名規則

- `SCREAMING_SNAKE_CASE` を使用する。
- 1コード1意味を維持する。
- 既存コードは原則維持し、挙動変更は実装で吸収する。

## 出力契約（参照）

```json
{
  "intake_required": true,
  "reason_code": "IMPLEMENTATION_MISSING_ACCEPTANCE",
  "reason_message": "Implementation request requires acceptance criteria.",
  "missing_fields": [
    {
      "field": "acceptance",
      "reason": "missing",
      "prompt_hint": "List concrete completion criteria."
    }
  ]
}
```

## コード分類

### 1) Intake 必須: Implementation 経路

| reason_code | intake_required | 説明 |
|---|---:|---|
| IMPLEMENTATION_MISSING_GOAL | true | 実装依頼に対して `goal` が不足している。 |
| IMPLEMENTATION_MISSING_ACCEPTANCE | true | 実装依頼に対して `acceptance` が不足している。 |
| IMPLEMENTATION_MISSING_SCOPE_IN | true | 実装依頼に対して `scope.in` が不足している。 |
| IMPLEMENTATION_MISSING_SCOPE_OUT | true | 文脈上必要な `scope.out` が不足している。 |
| IMPLEMENTATION_MISSING_CONSTRAINTS | true | 安全実行に必要な制約情報が不足している。 |
| IMPLEMENTATION_MISSING_GOAL_ACCEPTANCE | true | `goal` と `acceptance` が同時に不足している。 |
| IMPLEMENTATION_MISSING_MULTIPLE | true | 必須項目が3つ以上不足している。 |
| IMPLEMENTATION_EXISTING_ISSUE_UNCLEAR | true | 既存 issue を参照しているが intake 流用可否を判定できない。 |
| IMPLEMENTATION_NEEDS_INTAKE_CONFIRMATION | true | 下書きはあるが正式 intake 確認が未完了。 |

### 2) Intake 不要: Exempt 経路

| reason_code | intake_required | 説明 |
|---|---:|---|
| QUESTION_EXEMPT | false | 質問のみで実装依頼ではない。 |
| EXPLAIN_EXEMPT | false | 説明要求のみで実装依頼ではない。 |
| INVESTIGATE_EXEMPT | false | 調査要求のみで実装依頼ではない。 |
| SMALL_FIX_EXEMPT_MEETS_CRITERIA | false | 軽微修正候補が除外条件を満たす。 |
| IMPLEMENTATION_EXISTING_ISSUE_REUSABLE | false | 既存 issue に必須 intake 項目が揃っており流用可能。 |

### 3) Exempt 不成立: Intake 必須へフォールバック

| reason_code | intake_required | 説明 |
|---|---:|---|
| SMALL_FIX_REQUIRES_INTAKE | true | 軽微修正候補だが除外条件を満たさない。 |
| EXEMPTION_UNCLEAR_FALLBACK_INTAKE | true | 除外判定が不明瞭なため intake 必須へフォールバック。 |

### 4) Bypass ポリシー

| reason_code | intake_required | 説明 |
|---|---:|---|
| BYPASS_APPROVED_EMERGENCY | false | 緊急障害対応として bypass を許可。 |
| BYPASS_APPROVED_EXTERNAL_FACTOR | false | 外部要因で intake 完了待ち不可のため bypass を許可。 |
| BYPASS_REJECTED_INVALID_REASON | true | bypass 理由が無効または未対応のため拒否。 |
| BYPASS_UNNECESSARY_INTAKE_COMPLETE | false | intake が既に充足しており bypass が不要。 |

## `missing_fields[].reason` 値

許容値:
- `missing`
- `insufficient_detail`
- `conflicting_with_existing_issue`
- `required_for_risk_control`

## `missing_fields[].field` 値（初期）

- `goal`
- `scope.in`
- `scope.out`
- `acceptance`
- `priority`
- `constraints`

## 互換性方針

- 追加（新コード/新項目）は後方互換とする。
- 既存コードの改名・削除は破壊的変更とし、バージョン管理対象とする。
- 入口アダプターは未知 `reason_code` を受けた場合、原則 intake 必須側へ安全フォールバックする。
