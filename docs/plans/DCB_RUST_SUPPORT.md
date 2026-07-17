# DCB Rust 言語対応 仕様・作業計画

devcontainer-bootstrap（DCB）の `--languages` に `rust` を追加するための仕様と作業計画。

- 起案日: 2026-07-17
- 状態: **仕様レビュー中（未着手）**
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

**決定（推奨）**: 最小差分を優先し、php と同じ方式で `__IF_RUNTIME_RUST_CHECK__`（挿入コマンドは `command -v cargo ...`）を追加する。将来 3 言語目の個別検査が出た時点で汎用プレースホルダ機構へリファクタする（今回は範囲外）。

> 代替案: 今回いっしょに汎用化（言語ごとの条件検査行を配列駆動生成）。差分は増えるが以後の言語追加が軽くなる。**未決**として本レビューで選択可能とする。既定は最小差分（php 方式踏襲）。

### 4.3 VS Code 拡張（rust-analyzer）の要否

現行テンプレートは go / python / php に**言語固有の VS Code 拡張を追加していない**（追加しているのは copilot・containers・aws・terraform・gcloud などのインフラ系のみ）。

**決定**: 既存言語とのパリティと中立性を優先し、`rust-analyzer` 拡張は**追加しない**。導入したい利用者は生成後に各自の `.devcontainer` で拡張を足せる。

> 代替案: standard / full に `rust-lang.rust-analyzer` を追加。開発体験は上がるが、他言語に language server 拡張を入れていない現方針と非対称になる。**未決**。既定は追加しない。

### 4.4 gitignore テンプレート

github/gitignore に `Rust.gitignore` が存在する。**決定**: `has_language "rust"` のとき既定ターゲットへ `Rust` を追加する（他言語と同一機構）。

### 4.5 モード別の扱い

rust feature は 3 モード共通で配線する（他言語と同じ。モードは主に付随ツール群の差であり、言語ランタイムはモード非依存で選べる）。`on-attach.sh` の任意情報表示（full の `for cmd in ...` 等）に cargo を含めるかは任意（体験向上のみ、パリティ必須ではない）。

## 5. 詳細仕様（変更点一覧）

| # | ファイル | 変更内容 |
|---|---|---|
| 1 | `bootstrap.sh` 入力検証 | allowlist を `node\|go\|python\|php\|rust)` に拡張。未対応エラー文の supported 一覧へ `rust` を追記 |
| 2 | `bootstrap.sh` usage | `--languages <csv>` の説明を `node,go,python,php,rust` に更新 |
| 3 | `bootstrap.sh` devcontainer.json ×3 | 各テンプレートの features に `"__IF_RUNTIME_RUST__": "ghcr.io/devcontainers/features/rust:1"` を追加 |
| 4 | `bootstrap.sh` `render_content` | 置換ループを `for lang in node go python php rust` に拡張 |
| 5 | `bootstrap.sh` `build_default_gitignore_targets` | `has_language "rust"` で `Rust` を追加 |
| 6 | `bootstrap.sh` `post-rebuild-check.sh`（minimal/standard/full） | `__IF_RUNTIME_RUST_CHECK__` を追加し、選択時に `command -v cargo ...` を挿入。`render_content` に php と同様の条件挿入/削除ロジックを追加 |
| 7 | `doctor.sh` `check_runtime_languages` | 検出ループへ `rust` を追加し、`runtime_check_cmd` 経由で `command -v cargo` を確認（言語名→コマンド名マッピング導入） |
| 8 | `packages/devcontainer-bootstrap/README.md` | 「言語サポート」に `rust`（Rust）を追記。前提説明・使用例・`--languages` 仕様へ反映 |
| 9 | `tests/` | rust パリティ検証を追加（§7） |

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
- [ ] 生成 `post-rebuild-check.sh` が rust 選択時のみ `cargo` を検査し、非選択時は該当行を持たない。
- [ ] `doctor.sh` が rust feature 配線を検出し、`cargo` の有無で OK/warn を出す（`command -v rust` の誤検査をしない）。
- [ ] `docker compose config` が rust を含む 3 モード生成物でエラーなし。
- [ ] `tests/run-tests.sh` が全 green（新規 rust アサーション含む）。
- [ ] DCB README の言語サポートに rust が記載され、既存記述と日本語で一貫。
- [ ] `bootstrap.sh` は `bash -n` 構文チェックを通過し、bash 3.2 互換を維持（連想配列不使用）。

## 7. テスト計画

`tests/` に rust パリティ検証を追加する（既存 `test-templates.sh` 拡張、または新規 `test-rust-support.sh`）。最低限:

1. `--languages rust` 生成物の devcontainer.json に rust feature が **ある**。
2. `--languages node`（rust 非選択）生成物に rust feature が **ない**（残留プレースホルダ `__IF_RUNTIME_RUST__` も無い）。
3. rust 選択時の `post-rebuild-check.sh` に `cargo` 検査行が **ある**、非選択時は **ない**。
4. rust 選択時の `.gitignore` 管理セクションに Rust テンプレート内容が入る。
5. `doctor.sh` が rust 配線済み devcontainer.json を [OK]/[WARN] 判定し、`command -v rust` の誤検査をしない。
6. `docker compose config` が rust を含む生成物で成功。

## 8. 作業計画（フェーズ）

進捗の正本は issue / PR。以下は分解の目安。

1. **仕様確定**: 本書のレビュー・§4 の未決（4.2 汎用化、4.3 拡張）を決定 → 実装 issue 化。
2. **実装（bootstrap.sh）**: 検証・usage・テンプレ ×3・render・gitignore・条件検査行。
3. **実装（doctor.sh）**: 言語名→コマンド名マッピング導入と rust 追加。
4. **README 更新**: 言語サポート・使用例・仕様。
5. **テスト追加**: §7 のアサーション。
6. **検証**: `tests/run-tests.sh` / `docker compose config`（3 モード）/ `doctor.sh`。
7. **レビューゲート**: `/code-review` → `scripts/gemini-review.sh`（クロスモデル二段）。
8. **PR 作成・マージ**。
9. **リリース（別作業）**: テンプレートの機能追加のため **minor bump**（現行 `v0.2.0` → `v0.3.0`）。`scripts/release-packages.sh` を唯一の経路とし、事前に DCB README のピン留め版を更新（preflight `validate_dcb_docs` 要件）。リリースは本計画の完了後に別途判断。

## 9. リスク・留意点

- **言語名≠コマンド名の波及**: §4.1 のマッピングを doctor と check の両方へ一貫適用しないと、片方だけ `command -v rust` が残り常に warn になる。テスト 5 で担保する。
- **feature の初回ビルド時間**: rust feature は toolchain 取得でビルドが長くなり得る。生成物の挙動には影響せず、利用者環境の初回 rebuild 時間の話に留まる（ドキュメントで軽く触れる程度）。
- **bash 3.2 互換**: マッピングに連想配列を使わない（`case` 分岐）。macOS 標準 bash を壊さない。
- **パッケージ中立性**: 追加値は汎用の `rust`・公式 feature・github/gitignore の `Rust` のみ。固有名詞は持ち込まない。

## 10. 関連

- 実装対象: [packages/devcontainer-bootstrap/bootstrap.sh](../../packages/devcontainer-bootstrap/bootstrap.sh) / [doctor.sh](../../packages/devcontainer-bootstrap/doctor.sh)
- リリース手順: [RELEASE_EXECUTION_RUNBOOK](../release/RELEASE_EXECUTION_RUNBOOK.md)
- 直近の言語追加の先行例: php 対応（`__IF_RUNTIME_PHP_CHECK__` 方式）
