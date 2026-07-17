# 規範パッケージの改名計画（dotfiles → ai-playbook）

> **アーカイブ（2026-07-17）**: 改名は実施済みです（DCB 旧 v0.3.0 で追随、配布リポジトリ
> `ojos/ai-playbook` 稼働中）。本書は計画時の記録として保存します。
> 現行の正本は [RELEASE_HISTORY](../RELEASE_HISTORY.md) を参照。

- 起案日: 2026-07-15
- 状態: **実施済み・アーカイブ**
- 背景: [RELEASE_PROCESS_RECORD](RELEASE_PROCESS_RECORD.md)、および「dotfiles」という名前が実態（共有規範パッケージ）と食い違う問題

## goal

規範パッケージを、実態に合った名前・構造・配布方式へ移す。

- 名前: `dotfiles` → `ai-playbook`（配布リポジトリ `ojos/ai-playbook`）
- 取り込み先ディレクトリ: `.ai-playbook/`（ドット始まり。上流管理・利用者は触らない裏方であることを構造で示す）
- 内部構造: `ai/common/` を除去しフラット化（`REL_ROOT = .ai-playbook`）
- 配布: GitHub Release + 3 資産を廃止し、**git タグのみ**で配布

## 決定の根拠（確定済み）

| 決定 | 根拠 |
|---|---|
| ドット始まり | 共通ルールは上流管理で利用者が触らない。`.github/` `.devcontainer/` と同系列。触る `.github/project-ai-rules.md` との対比を構造で表現 |
| フラット化 | `ai/common` の `common` の隣には何もなかった。`.ai-playbook` 自体が「全体共通」を意味するので `ai/common` は冗長 |
| Release 廃止 | dotfiles の 3 資産は DL=0。DCB が使うのは git タグ由来の `archive/refs/tags/` tarball で Release とは独立（実測確認済み） |
| 新リポジトリ | 既存 `ojos/ai-dotfiles` は release ミラーとして履歴が汚れており、Release 資産も残る。クリーンな配布専用リポジトリを新設 |

## scope

### in

- モノレポ内 `dotfiles/` の改名とフラット化
- DCB のコード・テンプレート・README・テスト
- 全ドキュメントの参照更新（CLAUDE.md / `.github/*` / docs）
- `release-packages.sh` の dotfiles 部分（Release 廃止・タグのみ）
- 対外操作: `ojos/ai-playbook` 新設・公開、`ojos/ai-dotfiles` 廃止

### out

- DCB 自体の名前（`devcontainer-bootstrap` のまま）
- モノレポの private/public（変えない）
- audit の検証内容（別論点、RELEASE_PROCESS_RECORD）

## acceptance

| # | 条件 | 検証方法 |
|---|---|---|
| A1 | モノレポに `dotfiles` / `ai/common` の参照が残らない（意図的な履歴記述を除く） | grep で残存ゼロ |
| A2 | このモノレポ自身の AI ルール配線（CLAUDE.md 等）が `.ai-playbook` を正しく指す | 参照先の実在を確認 |
| A3 | DCB が `.ai-playbook/` へ規範を配置し、入口ファイルの参照先が実在する | 実行して確認 |
| A4 | DCB がドット始まりディレクトリを URL/ローカル/隣接の 3 経路で扱える | テストで確認 |
| A5 | `release-packages.sh` が dotfiles を Release なし・タグのみで公開する | dry-run で確認 |
| A6 | 全テストが通り、CI 相当（構文・リンク・中立性・CATALOG）も通る | 実行して確認 |
| A7 | 公開 `ojos/ai-playbook` から取得して DCB が動く | 公開後に end-to-end で確認 |

## タスクと依存順

```
T1（正本の改名・フラット化）
 ├─> T2（DCB コード・テンプレート・テスト）
 ├─> T3（モノレポ自身の配線と全ドキュメント）
 └─> T4（release-packages.sh の dotfiles 部分）
        すべて完了後 ─> T5（検証・コミット）─> T6（対外操作：新設・公開・旧廃止）
```

### T1: 正本の改名とフラット化

- **責務**: `dotfiles/ai/common/*` を `.ai-playbook/*` へ移し、`dotfiles/README.md` を `.ai-playbook/README.md` へ
- **前提**: なし（全参照の起点）
- **注意**: ドット始まりが `.gitignore` の既存パターンに誤マッチしないことを先に確認（実測済み: マッチなし）
- **検証**: A1 の一部（ディレクトリ移動の完了）
- **担当**: 自実装

### T2: DCB の対応

- **責務**: `DOTFILES_REL_ROOT`、フォールバック探索パス、`--dotfiles-from` の URL、テンプレート参照、テストを新構造へ
- **前提**: T1
- **内容**: `DOTFILES_REL_ROOT=.ai-playbook`、探索パスを `*/.ai-playbook` へ、入口テンプレートの参照を `.ai-playbook/` へ。ドット始まりの 3 経路テストを追加
- **検証**: A3 / A4
- **担当**: 自実装

### T3: モノレポの配線と全ドキュメント

- **責務**: CLAUDE.md / `.github/*` / docs の `dotfiles/ai/common` 参照を `.ai-playbook` へ。このリポジトリ自身の `dotfiles/` を `.ai-playbook/` にした結果、入口ファイルが指す先も張り替える
- **前提**: T1
- **注意**: **自己参照**。CLAUDE.md はこのモノレポの `dotfiles/` を参照しており、改名で配線が切れる。同時に直す
- **検証**: A2
- **担当**: 自実装

### T4: リリース方式の変更

- **責務**: `release-packages.sh` の dotfiles 部分を、Release 作成なし・タグ push のみへ。`SUMS_TARGETS` / `generate_standard_assets` / `tag_and_release` の dotfiles 経路を除去し、ソース push + タグのみに
- **前提**: T1（配布物の構造が変わるため）
- **内容**: `prepare_dotfiles_release_repo` は残す（配布リポジトリの中身更新）。Release と 3 資産の生成を削除。新リポジトリ名 `ai-playbook` へ向ける
- **検証**: A5
- **担当**: 自実装

### T5: 検証とコミット

- **責務**: A1〜A6 を実行で確認し、変異でテストの有効性も確認してコミット
- **前提**: T2・T3・T4
- **担当**: 自実装

### T6: 対外操作（承認必須）

- **責務**: `ojos/ai-playbook` を新設・公開、DCB/dotfiles をリリース、`ojos/ai-dotfiles` を廃止
- **前提**: T5
- **注意**: **取り消せない対外操作**。実行前に必ず承認を得る。新リポジトリ作成・旧リポジトリ削除・公開はそれぞれ確認ポイント
- **検証**: A7
- **担当**: ユーザー承認のもと実行

## 並列化の判断

T2・T3・T4 はいずれも T1 のみに依存し、互いに独立（触るファイルが異なる: DCB / ドキュメント / リリーススクリプト）。
論理的には並列実行可能。

ただし 3 つとも中規模で、`isolation: "worktree"` による並列委譲の分離コスト（worktree 生成・結果統合）が、逐次実行との差を上回らないと判断する。逐次で実施する。

T1 は全参照の起点であり、T5 は全完了後の検証。これらは直列。

## リスクと未決

| 項目 | 対応 |
|---|---|
| ドット始まりを AI エージェントが読めるか | パス指定で読めるはず。T2 で実測確認 |
| 既存 `ojos/ai-dotfiles` の 2 タグ（v0.2.1 / v0.3.0）の利用者 | stars/forks 0。実質このモノレポのみ。廃止時に最終確認 |
| DCB の README が指す dotfiles バージョン | 新リポジトリの初版タグに合わせる。T2 で更新 |
| 破壊的変更（submodule パスが変わる） | 外部利用者ゼロのため実害なし。記録には残す |
