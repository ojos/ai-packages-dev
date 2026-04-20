# Slack Intake Adapter（Dedicated-First, Shared-Compatible）

## 日本語概要
この文書は、ASF への Slack intake 統合に向けた phase-1 のアダプター契約と運用モデルを定義します。

## 目的
- dedicated workspace を主運用モデルとする。
- shared private-channel モードにも互換対応する。
- 既存 ASF intake フローへ正規化ペイロードを出力する。

## 入力契約（Slack -> Adapter）
- event_id
- team_id
- channel_id
- user_id
- text
- ts

## 出力契約（Adapter -> ASF）
- channel_type: slack
- source.workspace_mode: dedicated | shared
- source.channel_id
- source.user_id
- intake.raw_text
- intake.command_text
- safety.auth_validated: true | false

## Safety ルール
- ポリシーで未許可の channel/user は拒否する。
- runner unavailable 時は deferred/queued の明示結果を返す。
- コアワークフローはチャネル非依存を維持する。

## ロールアウト備考
- Phase-1 は契約定義と運用ガードレールを対象とする。
- 実行時実装フックは後続ステップで追加可能。
