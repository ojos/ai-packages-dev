# リリースプロセス レビュー

リリース作成部分の構造的な問題を整理した記録です。

- 起案日: 2026-07-15
- 状態: **進行中**。二重所有の解消のみ実施。根本は未決

## 要約

リリース作成に**所有者が 2 つ**あり、レースの結果として**公開物の整合性が実際に壊れている**。
表面的には「ツールの重複」だが、その下に「公開リポジトリとは何か」という未定義の問いがある。

## 発見: 整合性の破壊（実測）

`ojos/devcontainer-bootstrap` v0.2.1 で検証チェーンが切れている。

| 項目 | 値 |
|---|---|
| `RELEASE-MANIFEST.json` が記録した `SHA256SUMS` のハッシュ | `1ee89327...` |
| 実際に公開されている `SHA256SUMS` のハッシュ | `4edbea2b...` |

マニフェストは**存在しない `SHA256SUMS` を指している**。
加えて `PACKAGE_ARCHIVE.tar.gz` は公開中の `SHA256SUMS` に含まれず、配布アーカイブが検証対象から外れている。

`audit_release_assets` はこの状態で **pass する**。資産の**存在**しか見ておらず、整合性を検証しないため。

## 原因: 所有者が 2 つ

| 所有者 | 起動 | 生成する SHA256SUMS |
|---|---|---|
| `scripts/release-packages.sh`（モノレポ・ローカル実行） | 手動 | `find . -type f` = 全 5 ファイル |
| `.github/workflows/release.yml`（公開リポジトリ・CI） | タグ push で自動 | `bootstrap.sh` + `doctor.sh` |

`release-packages.sh` がタグを push すると `release.yml` が発火し、同じリリースを作って資産を上書きする。
実測では `release.yml` が勝っており、タイトルも `v0.2.1` ではなく `devcontainer-bootstrap v0.2.1` になっている。

## 本質: 「リリースとは何か」の理論が 2 つある

機械的な競合ではなく、**両立しない設計思想**の衝突。

| | `release.yml` | `release-packages.sh` |
|---|---|---|
| リリースとは | ユーザーが curl する 2 ファイル | パッケージのアーカイブとマニフェスト |
| README の手順との整合 | **一致する** | **壊す**（後述） |
| 消費者 | 実在 | **不在** |

`PACKAGE_ARCHIVE.tar.gz` と `RELEASE-MANIFEST.json` を消費する documented なフローは存在しない。

## 消費モデル（設計の起点）

| パッケージ | 実体 | リリースの本体 |
|---|---|---|
| DCB | curl して実行する単一スクリプト | **リリース資産**が load-bearing |
| dotfiles | 文書のみ。ランタイムなし | **git タグ**が本体。資産は不要 |

- DCB の README は `curl bootstrap.sh` + `curl SHA256SUMS` + `sha256sum -c` を指示する。
- dotfiles の README は submodule / subtree / 手動同期でタグ + SHA を固定すると定める。資産をダウンロードしない。
- DCB の `--dotfiles-from` が使うのは git 自動生成の `archive/refs/tags/vX.tar.gz` であり、リリース資産ではない。

**dotfiles の 3 資産は誰も消費していない。**

## 検証済みの事実: documented な手順は両方の理論で壊れていた

当初「レースが偶然ユーザーを救っていた」と考えたが、**実測の結果これは誤りだった**。
公開中の v0.2.1 に対して README の手順を厳密に再現すると、**現状でも失敗する**。

```
bash256sum -c SHA256SUMS
  bootstrap.sh: OK
  sha256sum: doctor.sh: No such file or directory
  doctor.sh: FAILED open or read
→ exit=1
```

- `release-packages.sh` の版: 全 5 ファイルを列挙 → 4 件 FAILED
- `release.yml` の版（実際に公開されている）: `bootstrap.sh` + `doctor.sh` → 1 件 FAILED

レースが勝敗を分けたのは**失敗の度合いだけ**で、どちらも壊れていた。
README が `bootstrap.sh` と `SHA256SUMS` しか取得させないのに、どちらの SHA256SUMS も
それ以上のファイルを列挙していたため。

**検証ファイルは「検証する人が手元に持っているもの」を列挙しなければ意味がない。**
この不一致は誰も検証していなかったため、公開後も気づかれなかった。

## 問題の構造

3 層になっており、上が下を制約する。

```
C. 公開リポジトリとは何か（成果物置き場か、開発リポジトリか）  ← 未決
   └─ B. どのツールがリリースを所有するか                      ← 整合性破壊の原因はここだけ
        └─ A. どこで実行するか（ローカル / CI）                ← 急がない
```

- **A だけ直しても解決しない。** `release.yml` はタグ push で発火するため、実行場所を変えても競合は残る。
- **B だけ直せば解決する。** ローカル実行のままでも整合性は回復する。
- **したがって A と B は別事象**であり、絡みは一方向（B が A を制約する）。

### C が未決であることの影響

現在の公開リポジトリは 7 ファイルで、位置づけが定まっていない。

- 配布物（`bootstrap.sh` / `SHA256SUMS` / `PACKAGE_ARCHIVE.tar.gz`）を持つ → **成果物置き場**として振る舞う
- `release.yml`（コードを検査してリリースを作る CI）も持つ → **開発リポジトリ**として振る舞う
- しかし `tests/` も規範ソースも持たない → **開発リポジトリとしては不完全**

重複はこの曖昧さの症状。どちらがビルドの持ち主か決まっていないため、両方が同じ仕事をしている。

### さらにその下

ミラーが存在する唯一の理由は、**モノレポが private で、配布先が public** であること。

```
private で開発 → public で配布 → ミラーが要る → 同期ツールが要る
  → ミラーにも CI を置いた → 二重所有 → 整合性破壊
```

`prepare_*_release_repo`、`init_and_push_release_repo`（clone → 全削除 → コピー → push）、
テンプレートとモノレポ実体の乖離は、すべてミラーの副産物。

## 儀式の問題

`RELEASE_ASSET_STANDARDIZATION_PROPOSAL`（削除済み）が、3 パッケージへ一律 3 資産を課した。
各パッケージが何を必要とするかを問わない均一化であり、結果として誰も消費しない資産が生まれた。

`audit_release_assets` はその存在を確認して緑を出すが、整合性は検証しない。
**実質を検査できず、儀式のみを検査している。** これは `shared-ai-rules.md` の「機構化の判断基準」が
禁じている形であり、ASF の git hook が儀式に退化したのと同じ病理。

なお本提案文書は「Phase 1〜3 実装済み」として削除したが、**実装されたことと正しいことを取り違えていた**。

## 実施内容（B のみ）

1. 公開側 `release.yml` を廃止し、所有者を `release-packages.sh` に一本化した。
   パッケージから削除したため、公開リポジトリへ二度と渡らない。
2. SHA256SUMS の対象を `SUMS_TARGETS` として呼び出し側で明示し、パッケージごとに宣言する形にした。
   DCB は `bootstrap.sh` と `doctor.sh`。消費モデルが異なるものに同じ形を課さない。
3. README の手順を SHA256SUMS の対象と一致させた（`doctor.sh` も取得する）。
4. この契約をテストで固定した（`tests/test-release-contract.sh`、7 件）。
   SHA256SUMS の対象と README の取得対象が食い違うと、実際に `sha256sum -c` を走らせて検出する。

結果: 整合性の破壊が止まり、マニフェストの検証チェーンも所有者が 1 つになったことで回復した。
documented な手順が初めて実際に通るようになった。

`release.yml` が担っていた機能の行き先:

| 機能 | 移動先 |
|---|---|
| `bash -n` / shellcheck | モノレポ CI（`.github/workflows/ci.yml`） |
| SHA256SUMS 生成 | `release-packages.sh` |
| リリース作成 | `release-packages.sh` |
| 機能テスト | **元から無かった**（これが v0.2.0 を通した）。現在は preflight が実施 |

## 今回実施しないこと（未決）

| 論点 | 内容 |
|---|---|
| **C: 公開リポジトリの位置づけ** | 成果物置き場と定義するか。定義すれば B の答えが導出される |
| **モノレポを public にするか** | ミラー機構ごと不要になる。private である理由が不明 |
| **dotfiles の資産の要否** | 誰も消費していない。タグのみで足りる可能性 |
| **均一化の撤回** | パッケージごとに消費モデルが異なるのに同じ形を課している |
| **audit の検証内容** | 存在確認から整合性検証へ |
| **A: 実行場所** | モノレポ CI へ移すか。クロスリポジトリ push 用の PAT が必要 |
| **リリース経路のテスト** | `release-packages.sh` 418 行にテストがない |

## 関連

- 退役の記録: [ASF_RETIREMENT_RECORD](ASF_RETIREMENT_RECORD.md)
- 実行手順: [RELEASE_EXECUTION_RUNBOOK](RELEASE_EXECUTION_RUNBOOK.md)
