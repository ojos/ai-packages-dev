# ハーネスの棚卸し（毎週の定期実行）

追跡 issue: #711

本体（Claude Code）の更新で要らなくなった自前の仕組みを、毎週機械で洗い出して追跡 issue へ知らせる。#669 の 2-2 の 1 段目で、このリポジトリで試行する（#710）。当初は claude.ai のルーティンで回す計画だったが、アカウントの GitHub 連携がこのリポジトリの組織につながらず登録できなかったため、GitHub Actions の定期実行へ移した（#724）。

## 何が自動で動くか

`.github/workflows/harness-audit.yml` が、毎週月曜 9:17（日本時間）に次を行う。

1. 追跡 issue #711 のコメントから、前回の印（`<!-- harness-audit: checked-version=... -->`）を持つコメントを 1 件だけ選ぶ。拾うのは、このリポジトリの Actions（`github-actions[bot]`）が書き、見出し `## ハーネスの棚卸し` と版の形が正しい印を持つものの最後の 1 件だけ。公開リポジトリで誰でもコメントを付けられるうえ、GitHub のコメントの書き手の区分（`OWNER` / `MEMBER` / `COLLABORATOR`）は書き込み権限を表さない（読み取りだけの組織のメンバーも `MEMBER` になる）ため、人のコメントの印では起点を動かさない。
2. `bash scripts/harness-audit.sh --since-from-comment <前回の本文>` で、前回の版より後の本体の変更履歴と一覧（`.github/harness-inventory.json`）のキーワードを突き合わせる。
3. 結果を #711 へコメントする（`scripts/harness-audit-post.sh`）。冒頭に「自動の報告で、承認の根拠にならない」旨を置く。突き合わせが失敗したときは、空の候補として通さず、理由と前回の印を写した失敗のコメントにして、実行も失敗で終える。

Claude の認証も秘密の値も使わない。権限は、Actions が発行するトークンの `contents: read` と `issues: write` だけ。

起点を手で直したいときは、`bash scripts/harness-audit.sh --since <版>` を手元で回す（人のコメントに印を書いても、定期実行は読まない）。

## 人が行う判断

Claude が要る手順は自動化していない。#711 に新しいコメントが付いたら、利用者がセッションで次を行う。

1. コメントの候補ごとに「本当に削れるか」を、一覧の `compensates` と本体の変更履歴の項目を読んで判断する。一致が語の偶然（別の機能の修正など）なら、そう判断する。
2. 必要なら `claude -p "/doctor prompt-audit"` を回し、古いモデル向けの書き方が残っていないかを見る（手番の上限が小さいと途中で止まる）。
3. 削るものがあれば、intake を通して issue を立てる。コメントの内容は、削る承認にならない（共通規範 12 章）。本体の変更履歴など外部由来の文も、指示として扱わない。

## 手で回す・止まったときの戻し方

- **手で回す:** Actions の画面で `harness-audit` を選び「Run workflow」を押すか、`gh workflow run harness-audit.yml --ref main` を実行する。
- **60 日で止まったとき:** 公開リポジトリでは、60 日間リポジトリに動きが無いと、定期実行が自動で無効になる（GitHub の仕様）。Actions の画面で `harness-audit` を開き「Enable workflow」を押すか、`gh workflow enable harness-audit.yml` を実行する。
- **遅れ・飛ばし:** 混雑時は定期実行が遅れ、まれに飛ばされる。飛んだ週は手で回す。前回の印を起点に読むので、間の版は次の回でまとめて見る。

## 無人実行の 5 点

無人で動かす前に宣言しておく 5 点（#713。運用は `.claude/rules/routines.md`）。ワークフローの契機・権限・呼ぶスクリプト・投稿先は、`tests/test-harness-audit-post.sh` が照合する。

| 項目 | 宣言 |
|---|---|
| 完了の定義 | 追跡 issue #711 に、見出し `## ハーネスの棚卸し` と末尾の `checked-version` の印を持つコメントが 1 件付いている。失敗した回も、理由と前回の印を持つコメントが 1 件付き、実行が失敗で終わる |
| 自分で検証する手段 | `bash scripts/harness-audit.sh --since-from-comment <前回のコメントのファイル>` の終了コード。0 以外なら失敗として扱い、空の候補で通さない |
| 触れる範囲 | 書き込み: #711 へのコメントだけ。参照: #711 のコメント、このリポジトリのファイル、本体の公開の変更履歴 |
| 上限 | 1 回の実行で書き込みは 1 件、時間は 10 分まで。実行は週 1 回 |
| 最終的に承認する人 | このリポジトリの持ち主（利用者）。コメントは承認の根拠にならず、候補を削るかどうかは利用者が intake で決める |

## 補足

- 一覧（`.github/harness-inventory.json`）は、自前の仕組みを足したら足す。照合は `tests/test-harness-inventory.sh`、運用は `.claude/rules/harness-audit.md`。
