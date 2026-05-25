# Role Contract / Task Skill Guidelines

この文書は、ASF におけるロール契約とタスクスキルの作成規範を定義する。

## 1. 用語定義

- Role Contract: ロールが「いつ何を判断するか」を定義する契約。
- Task Skill: タスクを「どう実行するか」を定義する再利用手順。

## 2. 配置規則

- Role Contract は `.multi-agent/role-contracts/` に配置する。
- Task Skill は `.multi-agent/task-skills/` に配置する。
- この区分を混在させない。

## 3. Role Contract 必須項目

- 目的
- 入力
- 出力
- 禁止事項
- エスカレーション条件
- 完了定義

## 4. Task Skill 必須項目

- 目的
- 入力
- 手順
- 出力
- 注意事項

## 5. 記述規則

- 判定基準は曖昧語を避け、検証可能な記述にする。
- 推測で補完せず、不足情報は明示して問い合わせる。
- 破壊的操作は事前条件と停止条件を併記する。

## 6. 参照規則

- Role Contract は必要な Task Skill を `推奨タスクスキル` として参照する。
- Task Skill はロール固有判断を持たず、実行手順に集中する。

## 7. 非目標

- Task Skill にロール権限境界を定義しない。
- Role Contract に詳細な逐次実装手順を埋め込まない。