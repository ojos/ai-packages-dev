# DCB Rust 言語対応 仕様・作業計画

devcontainer-bootstrap（DCB）の `--languages` に `rust` を追加するための仕様と作業計画。

- 起案日: 2026-07-17
- 状態: **判断ポイント確定・実装未着手**
- 対象パッケージ: `packages/devcontainer-bootstrap`
- 種別: 計画（実装完了後は記録として `docs/records/` へ移動、または内容を issue クローズコメントへ集約のうえ archive 化）

> この文書は仕様の正本。作業進捗の正本は GitHub issue / PR とする（プロジェクト規約「作業状況の記録先」）。

## 1. 背景・目的

DCB は現在 `node` / `go` / `python` / `php` の 4 言語ランタイムを devcontainer feature 経由で選択導入できる。ここに `rust` を第 5 の選択肢として追加し、既存言語と同等の生成・検査・ドキュメント体験（パリティ）を提供する。

## 2. スコープ

### 2.1 In（対象）

- `--languages` の受理値に `rust` を追加（他言語と任意に組み合わせ可能）。
- 3 モード（minimal / standard / full）すべてで rust feature を配線。
- 選択時に `.gitignore` の github/gitignore `Rust` テンプレートを取り込む。
- `doctor.sh` と生成物 `post-rebuild-check.sh` で rust ランタイムの有無を検査。
- DCB README とヘルプ・エラーメッセージへ `rust` を反映。
- rust パリティを検証するテストを追加。

### 2.2 Out（対象外）

- rust 固有のプロジェクト雛形（`Cargo.toml` 等）の生成。DCB は環境の配線のみを担い、アプリ雛形は生成しない（既存言語と同じ方針）。
- 特定 rust ツールチェーン版・コンポーネント（clippy/rustfmt 等）の細粒度指定オプション。まず feature 既定で導入し、要望が出た時点で拡張する。
- ai-playbook（規範）側の変更。言語追加は DCB の配布機構内で完結する。

## 2.3 決定事項（レビューで確定）

| # | 論点 | 決定 |
|---|---|---|
| 1 | rust の検査コマンド（§4.1） | `cargo` を採用（言語名→コマンド名マッピングを導入） |
| 2 | 条件検査行の実装（§4.2） | php 専用プレースホルダを撤去し**汎用化**（配列駆動） |
| 3 | VS Code 拡張（§4.3） | **全言語**に language server 拡張を条件付き配線 |
| 4 | php/node の拡張（§4.3） | サードパーティ拡張は配線しない（node=JS/TS 組み込み、php=有料ティア回避で組み込みのみ） |

## 3. 現状の言語対応メカニズム（要約）

言語追加が触れる箇所は次のとおり（`bootstrap.sh`）。

| 箇所 | 役割 |
|---|---|
| 入力検証 `case "$lang" in node\|go\|python\|php)` | 受理値の allowlist とエラーメッセージ |
| devcontainer.json テンプレート（3 モード） | `"__IF_RUNTIME_<LANG>__": "ghcr.io/devcontainers/features/<lang>:1"` 行 |
| `render_content` の `for lang in node go python php` | 選択言語は feature 行へ展開、非選択は行削除 |
| `build_default_gitignore_targets` | 選択言語に対応する github/gitignore テンプレート名を追加 |
| `post-rebuild-check.sh` の `__IF_RUNTIME_PHP_CHECK__` | 条件付きで検査行を挿入する仕組み（現状 php のみ個別対応） |
| `doctor.sh` `check_runtime_languages` の `for lang in node go python php` | features から言語を検出し `command -v <lang>` で存在確認 |

## 4. Rust 固有の設計論点と決定

### 4.1 【最重要】言語名 ≠ ランタイムコマンド名

既存 4 言語はいずれも **feature キー名＝実行コマンド名**（`node`→`node`、`go`→`go`、`python`→`python`、`php`→`php`）で、`doctor.sh` と `post-rebuild-check.sh` はこの一致に依存して `command -v "$lang"` で存在確認している。

rust はこの前提が崩れる:

- devcontainer feature キー: `ghcr.io/devcontainers/features/rust:1`
- 実際に導入されるコマンド: `rustc` / `cargo` / `rustup` / `rustfmt` / `clippy`（`rust` という実行ファイルは無い）

**決定**: 言語名→検査コマンド名の対応表を導入し、既定は言語名と同一、rust のみ `cargo` にマッピングする。

- 検査コマンドに `cargo` を採用する理由: feature が必ず同梱し、開発フローの中心（ビルド・テスト・依存管理）を担う代表コマンドであるため。`rustc` 単体より rust プロジェクト運用の準備完了を表す指標として妥当。
- 実装は bash 3.2 互換のため連想配列を使わず `case` で分岐する:

  ```bash
  runtime_check_cmd() {
    case "$1" in
      rust) printf 'cargo' ;;
      *)    printf '%s' "$1" ;;
    esac
  }
  ```

### 4.2 条件付き検査行の一般化

現状 `post-rebuild-check.sh` は php 専用に `__IF_RUNTIME_PHP_CHECK__` プレースホルダを持つ。rust も同種の条件付き検査行が必要。

**決定（レビューで確定）**: php 専用プレースホルダを**汎用化**する。言語ごとの条件検査行を、選択言語に応じて配列駆動で挿入/削除する機構へリファクタし、php も rust もその機構に載せる。今回の差分は増えるが、以後の言語追加時に検査行のためのコード変更が不要になる。

- 検査対象コマンドは §4.1 の `runtime_check_cmd`（rust→cargo、他は言語名）に一元化する。
- 各言語の検査行は「その言語が選択されているときのみ」`post-rebuild-check.sh` に現れる。既存の php 個別プレースホルダ（`__IF_RUNTIME_PHP_CHECK__`）はこの汎用機構へ置き換えて撤去する。
- bash 3.2 互換（連想配列不使用）を維持する。

### 4.3 VS Code 拡張（language server）の配線

現行テンプレートは go / python / php / rust に**言語固有の VS Code 拡張を追加していない**（追加しているのは copilot・containers・aws・terraform・gcloud などのインフラ系のみ）。

**決定（レビューで確定）**: 非対称を避けるため、**全言語**に対して language server 拡張を「選択言語に応じて条件付きで」配線する。ただし言語ごとに事情が異なる:

| 言語 | 配線する拡張 | 備考 |
|---|---|---|
| rust | `rust-lang.rust-analyzer` | 事実上の標準 |
| go | `golang.go` | 公式 |
| python | `ms-python.python` | 公式 |
| node | （なし） | JS/TS は VS Code 組み込みで language server 拡張は不要 |
| php | （サードパーティなし） | 組み込みの基本支援のみに留める。Intelephense（`bmewburn.vscode-intelephense-client`）は有料ティアがあるため既定配線しない |

- 実装は features の `__IF_RUNTIME_<LANG>__` と同様に、`customizations.vscode.extensions` へ条件付きエントリを置き、選択時のみ残す機構とする（node/php は配線対象の拡張を持たない）。
- インフラ系拡張（copilot 等）は従来どおりモード別に固定配置し、この条件付き機構とは分離する。

### 4.4 gitignore テンプレート

github/gitignore に `Rust.gitignore` が存在する。**決定**: `has_language "rust"` のとき既定ターゲットへ `Rust` を追加する（他言語と同一機構）。

### 4.5 モード別の扱い

rust feature と language server 拡張は 3 モード共通で配線する（他言語と同じ。モードは主に付随ツール群の差であり、言語ランタイム・言語拡張はモード非依存で選べる）。`on-attach.sh` の任意情報表示（full の `for cmd in ...` 等）に cargo を含めるかは任意（体験向上のみ、パリティ必須ではない）。

## 5. 詳細仕様（変更点一覧）

| # | ファイル | 変更内容 |
|---|---|---|
| 1 | `bootstrap.sh` 入力検証 | allowlist を `node\|go\|python\|php\|rust)` に拡張。未対応エラー文の supported 一覧へ `rust` を追記 |
| 2 | `bootstrap.sh` usage | `--languages <csv>` の説明を `node,go,python,php,rust` に更新 |
| 3 | `bootstrap.sh` devcontainer.json ×3 | 各テンプレートの features に `"__IF_RUNTIME_RUST__": "ghcr.io/devcontainers/features/rust:1"` を追加 |
| 4 | `bootstrap.sh` `render_content` | 置換ループを `for lang in node go python php rust` に拡張 |
| 5 | `bootstrap.sh` `build_default_gitignore_targets` | `has_language "rust"` で `Rust` を追加 |
| 6 | `bootstrap.sh` `post-rebuild-check.sh`（minimal/standard/full） | php 専用 `__IF_RUNTIME_PHP_CHECK__` を**汎用化**（§4.2）。選択言語ごとに検査行を配列駆動で挿入/削除し、検査コマンドは `runtime_check_cmd`（rust→cargo）に一元化。既存 php プレースホルダは撤去 |
| 7 | `doctor.sh` `check_runtime_languages` | 検出ループへ `rust` を追加し、`runtime_check_cmd` 経由で `command -v cargo` を確認（言語名→コマンド名マッピング導入） |
| 8 | `bootstrap.sh` devcontainer.json ×3（拡張） | `customizations.vscode.extensions` に条件付き language server 拡張を配線（§4.3: rust→`rust-lang.rust-analyzer` / go→`golang.go` / python→`ms-python.python`。node/php は配線なし）。`render_content` に拡張用の条件挿入/削除を追加 |
| 9 | `packages/devcontainer-bootstrap/README.md` | 「言語サポート」に `rust`（Rust）を追記。前提説明・使用例・`--languages` 仕様へ反映。あわせて language server 拡張の条件配線を明記 |
| 10 | `tests/` | rust パリティ + 拡張条件配線の検証を追加（§7） |

### 5.1 使用例（追加後の想定）

```bash
# 単一言語
./bootstrap.sh --project-name myapp --languages rust --mode minimal

# 複数言語
./bootstrap.sh --project-name myapp --languages node,rust --mode standard
```

## 6. 受け入れ条件（Acceptance）

- [ ] `--languages rust` および `--languages node,rust` 等の組み合わせが検証を通過する。
- [ ] 生成された `.devcontainer/devcontainer.json` に `"ghcr.io/devcontainers/features/rust:1": {}` が含まれ、非選択時には含まれない。
- [ ] rust 選択時、`.gitignore` の管理セクションに `Rust` テンプレート由来の内容が入る。
- [ ] 生成 `post-rebuild-check.sh` が rust 選択時のみ `cargo` を検査し、非選択時は該当行を持たない。汎用化後も php 選択時は `php` 検査行が従来どおり出る（回帰なし）。
- [ ] `doctor.sh` が rust feature 配線を検出し、`cargo` の有無で OK/warn を出す（`command -v rust` の誤検査をしない）。
- [ ] `customizations.vscode.extensions` に、選択言語に応じた language server 拡張が入る（rust→rust-analyzer / go→golang.go / python→ms-python.python）。非選択言語の拡張と残留プレースホルダは含まれない。node/php 選択時にサードパーティ language server 拡張が追加されない。
- [ ] 生成された devcontainer.json は妥当な JSON（`jq` が解釈でき、条件配線の有無で末尾カンマ等の壊れが出ない）。
- [ ] `docker compose config` が rust を含む 3 モード生成物でエラーなし。
- [ ] `tests/run-tests.sh` が全 green（新規 rust・拡張配線アサーション含む）。
- [ ] DCB README の言語サポートに rust が記載され、language server 拡張の条件配線も明記。既存記述と日本語で一貫。
- [ ] `bootstrap.sh` は `bash -n` 構文チェックを通過し、bash 3.2 互換を維持（連想配列不使用）。

## 7. テスト計画

`tests/` に rust パリティ検証を追加する（既存 `test-templates.sh` 拡張、または新規 `test-rust-support.sh`）。最低限:

1. `--languages rust` 生成物の devcontainer.json に rust feature が **ある**。
2. `--languages node`（rust 非選択）生成物に rust feature が **ない**（残留プレースホルダ `__IF_RUNTIME_RUST__` も無い）。
3. rust 選択時の `post-rebuild-check.sh` に `cargo` 検査行が **ある**、非選択時は **ない**。
4. **汎用化の回帰確認**: php 選択時に `php` 検査行が従来どおり出て、非選択時は出ない（php 個別プレースホルダ撤去後も挙動不変）。
5. rust 選択時の `.gitignore` 管理セクションに Rust テンプレート内容が入る。
6. `doctor.sh` が rust 配線済み devcontainer.json を [OK]/[WARN] 判定し、`command -v rust` の誤検査をしない。
7. **拡張の条件配線**: rust/go/python 選択時に対応拡張が `extensions` に **ある**、非選択時は **ない**。node/php 選択時にサードパーティ language server 拡張が入らない。
8. 条件配線の有無いずれでも devcontainer.json が妥当な JSON（`jq` 通過）。
9. `docker compose config` が rust を含む生成物で成功。

## 8. 作業計画（フェーズ）

進捗の正本は issue / PR。以下は分解の目安。

1. **仕様確定**: 本書のレビュー（§4 の判断ポイントは確定済み、下記「決定事項」参照）→ 実装 issue 化。
2. **実装（bootstrap.sh 検査系）**: 検証・usage・feature テンプレ ×3・render・gitignore、および `post-rebuild-check.sh` の検査行汎用化（php プレースホルダ撤去＋配列駆動）。
3. **実装（bootstrap.sh 拡張系）**: `customizations.vscode.extensions` の条件付き language server 拡張配線（rust/go/python）。
4. **実装（doctor.sh）**: 言語名→コマンド名マッピング（`runtime_check_cmd`）導入と rust 追加。
5. **README 更新**: 言語サポート・使用例・拡張の条件配線・仕様。
6. **テスト追加**: §7 のアサーション（rust パリティ・汎用化回帰・拡張条件配線）。
7. **検証**: `tests/run-tests.sh` / `docker compose config`（3 モード）/ `doctor.sh` / `jq` による JSON 妥当性。
8. **レビューゲート**: `/code-review` → `scripts/gemini-review.sh`（クロスモデル二段）。
9. **PR 作成・マージ**。
10. **リリース（別作業）**: テンプレートの機能追加のため **minor bump**（現行 `v0.2.0` → `v0.3.0`）。`scripts/release-packages.sh` を唯一の経路とし、事前に DCB README のピン留め版を更新（preflight `validate_dcb_docs` 要件）。リリースは本計画の完了後に別途判断。

## 9. リスク・留意点

- **言語名≠コマンド名の波及**: §4.1 のマッピングを doctor と check の両方へ一貫適用しないと、片方だけ `command -v rust` が残り常に warn になる。テスト 6 で担保する。
- **php プレースホルダ撤去の回帰**: §4.2 の汎用化で既存 `__IF_RUNTIME_PHP_CHECK__` を撤去するため、php 選択時の検査行が従来どおり出ることを回帰テスト（テスト 4）で担保する。
- **条件付き拡張配線の JSON 破損**: 非選択言語の拡張エントリ削除で末尾カンマ等が残ると devcontainer.json が壊れる。既存の `perl` による末尾カンマ除去＋`jq` 整形（`write_file`）を経由させ、テスト 8 で JSON 妥当性を担保する。
- **feature の初回ビルド時間**: rust feature は toolchain 取得でビルドが長くなり得る。生成物の挙動には影響せず、利用者環境の初回 rebuild 時間の話に留まる（ドキュメントで軽く触れる程度）。
- **bash 3.2 互換**: マッピング・条件配線に連想配列を使わない（`case` 分岐・逐次判定）。macOS 標準 bash を壊さない。
- **パッケージ中立性**: 追加値は汎用の `rust`・公式 feature・github/gitignore の `Rust`・公式/OSS の言語拡張（`rust-lang.rust-analyzer` / `golang.go` / `ms-python.python`）のみ。有料ティアのある拡張（Intelephense 等）や固有名詞は持ち込まない。

## 10. 関連

- 実装対象: [packages/devcontainer-bootstrap/bootstrap.sh](../../packages/devcontainer-bootstrap/bootstrap.sh) / [doctor.sh](../../packages/devcontainer-bootstrap/doctor.sh)
- リリース手順: [RELEASE_EXECUTION_RUNBOOK](../release/RELEASE_EXECUTION_RUNBOOK.md)
- 直近の言語追加の先行例: php 対応（`__IF_RUNTIME_PHP_CHECK__` 方式。本計画で汎用化し撤去）
