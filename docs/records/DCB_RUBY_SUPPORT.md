# DCB Ruby 言語対応 仕様・作業計画

devcontainer-bootstrap（DCB）の `--languages` に `ruby` を追加するための仕様と作業計画。

- 起案日: 2026-07-30
- 状態: **実装完了（devcontainer-bootstrap v0.8.0 で出荷予定）**
- 対象パッケージ: `packages/devcontainer-bootstrap`
- 種別: 記録（起案と実装を同一 PR で行ったため、当初から `docs/records/` へ置く）

> この文書は実装時点の仕様の記録であり、現行仕様の正本ではない。現行仕様の正本は `packages/devcontainer-bootstrap/README.md` と実装（`bootstrap.sh` / `doctor.sh`）とする。

## 実装完了の証跡

| 項目 | 内容 |
|---|---|
| issue | #206 |
| 実装箇所 | `bootstrap.sh`: usage（`--languages` の CSV 列挙）／受理値 allowlist と未対応時のエラーメッセージ／`__IF_RUNTIME_RUBY__` feature プレースホルダ／feature 配線ループの言語列挙／`Ruby` gitignore 暗黙ターゲット／`acceptance_check_cmd`（`bundle exec rake`）／`acceptance_manifest_cond`（`[[ -f Gemfile ]]`）／`acceptance_manifest_name`（`Gemfile`）／`acceptance_tool_cmd`（`bundle`）／`acceptance_install_hint`／`language_extension`（`Shopify.ruby-lsp`）。`doctor.sh`: `check_runtime_languages` の言語列挙 |
| 回帰テスト | `packages/devcontainer-bootstrap/tests/test-ruby-support.sh`（24 ケース） |
| 一覧照合の追加 | `tests/test-readme-flags.sh` に対応言語の**両方向**集合照合を追加（実装の受理集合 ⇔ README「言語サポート」節）。個別言語の取りこぼし検査は書いた言語しか守れないため |
| 未実装の残件 | **なし**。§6 の受け入れ条件は全項目が実装・テストで満たされている |

## 1. 背景・目的

DCB は現在 `node` / `go` / `python` / `php` / `rust` の 5 言語ランタイムを devcontainer feature 経由で選択導入できる。ここに `ruby` を第 6 の選択肢として追加し、既存言語と同等の生成・検査・診断・ドキュメント体験（パリティ）を提供する。

前例は [DCB_RUST_SUPPORT](DCB_RUST_SUPPORT.md)（rust を第 5 の選択肢として追加、v0.3.0 で出荷）。本作業はこれと同型である。

## 2. スコープ

### 2.1 In（対象）

- `--languages` の受理値に `ruby` を追加（他言語と任意に組み合わせ可能）。
- `ghcr.io/devcontainers/features/ruby:1` を feature として配線。
- 選択時に `.gitignore` の github/gitignore `Ruby` テンプレートを取り込む。
- `doctor.sh` と生成物 `post-rebuild-check.sh` で ruby ランタイムの有無を検査。
- 生成物 `acceptance.sh` に ruby の受け入れ検証行を配線。
- 選択時に VS Code language server 拡張 `Shopify.ruby-lsp` を条件配線。
- DCB README とヘルプ・エラーメッセージへ `ruby` を反映。
- ruby パリティを検証するテストを追加。
- `.ai-playbook/README.md` の言語列挙へ `ruby` を追加（事実の列挙が陳腐化するため）。

### 2.2 Out（対象外）

- ruby 固有のプロジェクト雛形（`Gemfile` / `Rakefile` / `*.gemspec`）の生成。DCB は環境の配線のみを担い、アプリ雛形は生成しない（既存言語と同じ方針）。
- rbenv / rvm / asdf 等のバージョン管理ツールの配線。devcontainer feature に委ねる。
- 特定 ruby 版の細粒度指定オプション。まず feature 既定で導入し、要望が出た時点で拡張する。
- ai-playbook パッケージのリリース。同パッケージ側は文書追随のみで規範の変更はない。
- 既存 5 言語の挙動変更。

## 3. 決定事項

| # | 論点 | 決定 | 理由 |
|---|---|---|---|
| 1 | acceptance の代表コマンド | `bundle exec rake` | ruby はテストフレームワークが Minitest / RSpec に分かれ、単一の慣習的コマンドが無い。`npm test` / `composer test` と同じ「プロジェクトの設定に委譲」型にして、どちらの流儀でも動く形にする。`bundle exec rspec` や `bundle exec rake test` を選ぶと、他方のプロジェクトで必ず失敗する |
| 2 | manifest 判定 | `[[ -f Gemfile ]]` | ルート直下マニフェストの実在確認という既存方針に合わせる。`*.gemspec` は gem 開発時のみ存在し、かつ `Gemfile` が併存するのが通例なので単独条件にしない |
| 3 | ツール可用性判定 | `bundle` | 実行するコマンドが `bundle exec ...` であるため、`ruby` の有無ではなく `bundle` の有無を見る。`composer test` に対し `composer` を見る php と同型 |
| 4 | ランタイム検査コマンド | `ruby`（写像なし） | feature 名（`ruby`）と実行ファイル名（`ruby`）が一致するため、rust で必要だった `rust`→`cargo` の写像分岐を追加しない。分岐を増やさないほうが `runtime_check_cmd` の意図（例外だけを書く）が保たれる |
| 5 | language server 拡張 | `Shopify.ruby-lsp` | 事実上の標準で、php のように有料ティアを持たない。`rebornix.ruby` は非推奨のため採らない |
| 6 | gitignore ターゲット | `Ruby` | github/gitignore に実在する。`--languages` は小文字・`--gitignore-targets` は大文字始まりという既存の表記差をそのまま踏襲 |
| 7 | 言語列挙の並び | 既存 5 言語の後ろへ追加 | 既存の順序を保ち、差分を追加のみに留める |

## 4. 実装箇所

`bootstrap.sh`（12 箇所）:

1. usage の `--languages` 説明（CSV 列挙）
2. 受理値 allowlist の `case`
3. 未対応言語のエラーメッセージ（対応言語の列挙）
4. `devcontainer.json` テンプレートの `__IF_RUNTIME_RUBY__` プレースホルダ
5. feature 配線ループの言語列挙（`for lang in node go python php rust ruby`）
6. `build_default_gitignore_targets` の `Ruby`
7. `acceptance_check_cmd`
8. `acceptance_manifest_cond`
9. `acceptance_manifest_name`
10. `acceptance_tool_cmd`
11. `acceptance_install_hint`
12. `language_extension`

`runtime_check_cmd` は変更しない（既定の「言語名 = コマンド名」で正しく解決される）。

`doctor.sh`（1 箇所）: `check_runtime_languages` の言語列挙。

`README.md`（12 箇所）: 前提環境・`--languages` 説明・`acceptance.sh` 節・言語サポート一覧・feature 導入の説明・language server 拡張表・使用例・生成物一覧・入力規約・gitignore 暗黙ターゲット表・表記差の注意・doctor 節。

## 5. テスト

`tests/test-ruby-support.sh`（新規、24 ケース）を `test-rust-support.sh` と同型で追加する。ネットワークには出ない。

| 区分 | 検証内容 |
|---|---|
| feature 配線 | 選択時に feature が入る／非選択時に feature もプレースホルダも残らない／JSON 妥当性／options 無し（python の uv 同梱に巻き込まれない） |
| post-rebuild-check | 選択時に `ruby` 検査行が出る／非選択時に出ない／`cargo` のような写像を挟まない |
| acceptance | `bundle exec rake` が入る／フレームワークを決め打ちしない／`Gemfile` 実在確認がある／非選択時に入らない／`Gemfile` 不在で skip／`Gemfile` あり `bundle` 不在で導入手順付き非 0／各組み合わせで `bash -n` を通る |
| gitignore | 選択時に `Ruby` ターゲットが入る／非選択時に入らない |
| language server 拡張 | 選択時に `Shopify.ruby-lsp` が入る／非選択時に入らない／既存言語の拡張が回帰しない |
| doctor | ruby feature を検出して `ruby` で検査する／非選択時に報告しない |
| 入力検証 | `ruby` が受理される／未対応言語のエラーが `ruby` を列挙する／ヘルプが `ruby` を列挙する |

加えて `tests/test-readme-flags.sh` へ**対応言語の両方向集合照合**を追加する。個別言語の取りこぼし検査（rust 節・ruby 節）は書いた言語しか守れず、次の言語追加で検査ごと足し忘れると README の追随漏れが素通りする。実装の受理集合を `case` から生成し、README「言語サポート」節の箇条書きと差集合を両方向で見る（規範 `.ai-playbook/shared-ai-rules.md`「一覧の複製は機械照合で担保する」）。

## 6. 受け入れ条件

すべて非対話で実行でき、終了コードで合否が判定できる。

1. `bash packages/devcontainer-bootstrap/tests/run-tests.sh` が終了コード 0
2. `bash scripts/verify.sh` が終了コード 0（`VERIFY_PASS`）
3. `bash scripts/acceptance.sh` が終了コード 0（CATALOG 網羅・dangling 検査を含む）
4. `--languages ruby` の生成物 `devcontainer.json` に `ghcr.io/devcontainers/features/ruby:1` を含む
5. 同生成物 `acceptance.sh` が `bundle exec rake` と `Gemfile` 実在判定を含み、`Gemfile` 不在で skip、`Gemfile` あり `bundle` 不在で導入手順付き失敗
6. `--languages unsupported` がエラー終了し、対応言語の列挙に `ruby` を含む
7. `--languages ruby` 指定時のみ `Shopify.ruby-lsp` が配線される
8. `doctor.sh` が ruby を検出し `ruby command available` / `missing` を出力する
9. `--gitignore-targets` の暗黙ターゲット解決が `ruby` に対し `Ruby` を返す
10. リリース時に preflight `validate_dcb_docs` が v0.8.0 で通過する

## 7. リリース

- バージョン: v0.7.4 → **v0.8.0**（テンプレートの機能追加のため minor bump）
- 経路: `scripts/release-packages.sh` を唯一の経路とし、**実行場所は GitHub Actions**（`.github/workflows/release.yml` の `workflow_dispatch`）。ローカルからの `--execute` は機構が拒否する
- 事前条件: `packages/devcontainer-bootstrap/README.md` の固定バージョン 3 箇所（見出し `最新安定リリース:` / 固定行 `` - `v0.8.0` `` / 取得手順 `TAG=v0.8.0`）が v0.8.0 で揃っていること
- 事後: ルート `README.md` の RELEASE_STATUS ブロックを `bash scripts/update-release-status.sh --owner ojos --readme README.md` で更新し、人がコミットする（bot は本モノレポへコミットしない）

手順の正本は `docs/release/RELEASE_EXECUTION_RUNBOOK.md`。

## 関連

- 前例: [DCB_RUST_SUPPORT](DCB_RUST_SUPPORT.md)
- モード廃止と装備フラグ化: [DCB_MODE_REMOVAL_WITH_FLAGS](DCB_MODE_REMOVAL_WITH_FLAGS.md)
