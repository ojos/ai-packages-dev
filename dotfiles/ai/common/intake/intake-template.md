# Intake Template

```yaml
goal:
scope.in:
scope.out:
constraints:
acceptance:
priority:
```

## メモ

- 必須項目: `goal`, `scope.in`, `acceptance`, `priority`
- 任意項目: `scope.out`, `constraints`
- 記述は具体的かつ検証可能に保つ。`acceptance` は `goal` を検証できる形にする
- 既定言語は日本語
- ユーザー承認を得るまで起票しない

## 関連

- ロール契約: [intake-manager](../role-contracts/intake-manager.md)
- 判定根拠の分類: [REASON_CODES](REASON_CODES.md)
