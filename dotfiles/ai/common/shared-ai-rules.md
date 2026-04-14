# AI 共通開発ガイドライン (Shared Guidelines)

このファイルは、全プロジェクトで共通して適用される AI アシスタント向けのコーディングおよびコミット規約です。

## 1. コーディング規約 (Coding Guidelines)
- **命名規則**: ファイル、ディレクトリ、変数、関数、クラスなど、すべてにおいて「使用する言語の慣習（ベストプラクティス）」に完全に従うこと。
- **ドキュメント・コメント**: すべての関数・クラス・主要な処理に対して、仕様や役割を説明するドキュメントコメント（JSDocやDocStringなど）を必ず記述すること。
- **エラーハンドリングとロギング**: 外部API通信やファイル操作など失敗しうる処理には、必ず `try-catch` 等の適切なエラーハンドリングを実装し、エラー内容をログとして出力すること。
- **型定義の厳密化**: 型推論や静的型付け（TypeScript, Python等）を使用する場合、`any`等の曖昧な型は極力避け、可能な限り厳密に変数の型や関数のシグネチャ（引数・戻り値）を定義すること。
- **ファイル分割・モジュール化**:
  - 1ファイルにつき「1クラス」または「1つの主なコンポーネント」と定めること。
  - 再利用可能なロジックは積極的に別ファイル（`utils` ディレクトリなど）に切り出し、責務を分離すること。

## 2. テストの作成ルール (Testing Rules)
- 新しい関数、クラス、コンポーネントを作成または修正した場合は、必ず対応する単体テスト（ユニットテスト）ファイルも作成・更新すること。

## 3. コミットメッセージ規約 (Commit Message Rules)
- **プレフィックス**: Conventional Commits に従い、先頭に変更の種類を示すプレフィックス（`feat:`, `fix:`, `docs:`, `refactor:` 等）をつけること。
- **言語**: コミットメッセージはすべて「日本語」で記述すること。
- **詳細度**:
  - 1行目にタイトル（変更内容の要約）を書く。
  - 2行目は空行とする。
  - 3行目以降に「なぜその変更をしたのか（Why）」と「どうやって変更したか（How）」の詳細を記述すること。

---
※ これらのルールは全プロジェクトで共通です。パフォーマンスの最適化を優先するため言語やフレームワーク自体は限定しません。

---

## 4. ドキュメント言語方針 (Documentation Language Policy)

- **日英併記**: 主要ドキュメントは原則として日英併記を推奨する。
- **規範文は英語**: 実働上の規範文は英語で記述し、日本語は同義の補足として併記する。Keep normative statements in English for operational consistency, and add equivalent Japanese text for readability.
- **意味の一致**: 日英で意味をずらさない。更新時は両言語を同時に更新する。Keep Japanese and English semantically aligned, and update both together.

### ドキュメント形式の使い分け / Document Format Rules

**規範文書（指示・ポリシー層）:**
- 形式: 1ファイル内で日英併記
- 位置: `.github/` 配下
- 理由: AI解釈のズレを避けるため、同一コンテキストで両言語を保持

**利用ガイド（パッケージドキュメント層）:**
- 形式: 言語別に分離（英語正本 / 日本語翻訳）
- 正本: 英語（`README.md` / `*.md`）を正本として扱う
- 翻訳: 日本語は `README.ja.md` / `*.ja.md` として分離する
- 同期: 更新時は英語更新後に日本語を追随させる（同時更新必須）

## 5. ドキュメント命名規則 (Document Naming Convention)

Markdown ファイルの命名は、文書の役割に応じて以下の規則に従う。
Name Markdown files according to their role as follows.

| 役割 / Role | 命名形式 / Pattern | 例 / Example |
|---|---|---|
| ポリシー・仕様・契約文書 | `UPPER_SNAKE_CASE.md` | `STATE_MANAGEMENT.md` |
| ガイド・手順・説明文書 | `lower-kebab-case.md` | `install.md`, `runtime-operations.md` |
| パッケージ README と日本語訳 | `README.md` / `README.ja.md` | `README.md`, `README.ja.md` |
| スキル・テンプレート定義 | `lower-kebab-case.md` | `orchestrator.md`, `intake-template.md` |
| 連番 issue テンプレート | `NN-lower-kebab-case.md` | `01-project-config.md` |

**判断基準 / Decision criteria:**
- 他コンポーネントが参照する規範的定義・契約・方針 → `UPPER_SNAKE_CASE`
- 人間が読む手順書・解説・ガイド → `lower-kebab-case`
- 日本語翻訳は常に `.ja.md` サフィックスで分離する（例: `*.ja.md`）