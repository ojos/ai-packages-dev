# DCB `--mode` 廃止・`--with-*` 装備フラグ化 仕様・作業計画

devcontainer-bootstrap（DCB）の `--mode <minimal|standard|full>` を廃止し、mode が束ねていた直交した装備を「常時標準化」と「`--with-*` フラグ」に分解するための仕様と作業計画。

- 起案日: 2026-07-21
- 状態: **仕様確定・実装未着手**
- 対象パッケージ: `packages/devcontainer-bootstrap`
- 種別: 計画（実装完了後は記録として `docs/records/` へ移動、または issue クローズコメントへ集約のうえ archive 化）
- 破壊的変更: **あり**（`--mode` 削除）。後方互換は取らず版を上げる（案B）。

> この文書は仕様の正本。作業進捗の正本は GitHub issue / PR とする（プロジェクト規約「作業状況の記録先」）。

## 1. 背景・目的

現状 `--mode` は「手書きの 3 テンプレート一式（minimal/standard/full）」を切り替えるだけのスイッチだが、実体としては互いに**直交した 4 つの ON/OFF** を階段状に束ねているに過ぎない。

| mode が束ねる軸 | minimal | standard | full |
|---|---|---|---|
| docker のリッチさ（buildx / compose-switch） | 最小 | あり | あり |
| cloud（AWS/Terraform / GCP） | なし | AWS+TF | AWS+TF+GCP |
| Copilot 等 AI ツール拡張 | なし | copilot | copilot |
| AI 認証の永続化 + 診断の postCreate 配線 | なし | なし | あり |

この束ね方には次の問題がある。

- **実在する組み合わせが表現できない**: 「GCP だけ欲しい」「docker はリッチだが Copilot は不要」など。GCP を使うには full を選ぶしかない。
- **重複保守コスト**: `install-ai-tools.sh` は 3 mode で完全に同一、`on-attach.sh` / `post-rebuild-check.sh` は検査するコマンド名の一覧が違うだけ。同じ内容が 3 か所にコピーされている。
- **暗黙の自動挙動**: AI CLI（claude/gemini）は mode ではなく「環境変数トークンの有無」で自動インストールされ、利用者が明示制御できない。
- **根拠なき full 限定**: AI 認証の永続化（named volume）は full だけに付くが、これは compose 移行前の full テンプレ `mounts` を惰性で引き継いだもので、設計上の根拠は記録にない（しかも旧 `/home/node` 指定で永続化が効いていなかった経緯がある）。

**目的**: これら 4 軸を分解し、`--mode` を廃止して、装備を「常時標準（docker / AI 永続化）」と「明示 `--with-*` フラグ（cloud / AI ツール）」で選べるようにする。あわせて 3 テンプレートを 1 つのパラメータ化テンプレートへ集約し、重複保守を解消する。

## 2. スコープ

### 2.1 In（対象）

- `--mode` オプションの**削除**（受理・検証・分岐の撤去）。
- docker のリッチさ（`installDockerBuildx` / `installDockerComposeSwitch` / `dockerDashComposeVersion`）を**全生成物の標準**にする。
- cloud 装備を `--with-aws` / `--with-gcp` フラグへ切り出す（feature 行 + VSCode 拡張行の条件配線）。Terraform はいずれかの cloud フラグ指定時に暗黙同梱。
- AI ツール装備を `--with-claude` / `--with-gemini` / `--with-copilot` フラグへ切り出す（CLI インストール + VSCode 拡張 + 認証の永続化）。**トークン有無による自動インストールを廃止し、明示 opt-in のみ**にする。
- AI 認証の永続化（compose named volume）を **mode 非依存**にし、選択した AI ツールの設定ディレクトリを全生成物で永続化する。
- 3 mode 別テンプレートを 1 つのパラメータ化テンプレートへ集約（devcontainer.json / compose.yaml / on-attach.sh / post-rebuild-check.sh / install-ai-tools.sh）。
- 将来の `--with-*` 追加を差分 1 本で載せられる**拡張点**として実装（§5.6）。
- DCB README・usage・エラーメッセージの更新。
- 上記の検証テストの追加・改修。

### 2.2 Out（対象外）

- `--with-codex`（OpenAI Codex）/ `--with-sakura`（さくらのクラウド）/ `--with-cloudflare`（Cloudflare）の**実装**。フラグ表面と条件配線の拡張点だけ用意し、値の追加は将来行う（§5.6）。
- `--languages`（言語ランタイム選択）の仕様変更。既存機構は据え置き。
- ai-playbook（規範）側の変更。本件は DCB の配布機構内で完結する。
- `--with-playbook` / `--github-profiles` / gitignore 系など、mode と無関係な既存フラグの挙動変更。
- AI ツールの認証情報そのものの管理方法（トークンは従来どおり `remoteEnv` 経由で受け渡す）。

## 3. 決定事項（確定）

| # | 論点 | 決定 |
|---|---|---|
| 1 | `--mode` の後方互換 | **案B**: 受理せず即削除する破壊的変更。版を上げる（§8-10） |
| 2 | docker のリッチさ | 全生成物で standard/full 相当（buildx + compose-switch）を**標準化**。フラグ化しない |
| 3 | cloud の指定 | `--with-aws` / `--with-gcp` の**明示フラグ**。mode から切り離す |
| 4 | Terraform | 独立フラグにせず、`--with-aws` または `--with-gcp` の**いずれか指定時に暗黙同梱**（両指定でも 1 回、cloud 無指定なら無し） |
| 5 | AI ツールの指定 | `--with-claude` / `--with-gemini` / `--with-copilot` の**明示フラグ**。`--with-codex` は予定のみ |
| 6 | AI ツールの自動インストール | **廃止**。トークン有無に関わらず、フラグ指定時のみ導入（明示 opt-in） |
| 7 | AI ツールの挙動統一 | 各 `--with-<ai>` は「CLI インストール + 対応 VSCode 拡張 + 設定ディレクトリの永続化」を**同型**で行う |
| 8 | AI 認証の永続化 | mode 非依存。選択した AI ツールごとに永続 volume を全生成物で配置（full 限定を撤廃） |
| 9 | テンプレート構成 | 3 mode 別テンプレを 1 つのパラメータ化テンプレへ集約し重複を解消 |
| 10 | 拡張性 | cloud/AI とも「フラグ 1 本 + 条件配線エントリ」で将来値を追加できる汎用機構にする |

## 4. 現状メカニズム（要約）

`bootstrap.sh` の関係箇所。

| 箇所 | 役割 |
|---|---|
| 入力検証 `case "$MODE" in minimal\|standard\|full)` | mode の allowlist |
| `get_template_content` の `case "$mode:$rel" in ...` | ファイル×mode ごとに `cat <<'TMPL'` で本文を返す（3 mode 分のヒアドキュメント） |
| devcontainer.json テンプレ ×3 | features（docker/cloud/言語/AI 拡張）と `customizations.vscode.extensions` を mode 別にベタ書き |
| compose.yaml テンプレ（minimal/standard 共通・full 別） | full のみ `claude-storage`/`gemini-storage` の named volume を定義 |
| `install-ai-tools.sh` テンプレ ×3 | **3 mode 完全同一**。`CLAUDE_CODE_OAUTH_TOKEN`/`GEMINI_API_KEY` があれば claude/gemini を npm global 導入 |
| `on-attach.sh` / `post-rebuild-check.sh` テンプレ ×3 | 表示・検査する command 名の一覧が mode で異なるだけ |
| `render_content` の言語ループ（`for lang in node go python php rust`） | 選択言語の feature 行を有効化、非選択は sed で行削除（`has_language`→sed 機構、[bootstrap.sh:1102-1110]） |
| `postCreateCommand` | full のみ `&& bash scripts/post-rebuild-check.sh` を追加 |

**再利用する中核機構**: `has_language`→sed による「選択されたものだけ feature 行/拡張行を残し、非選択は削除する」条件配線（言語で実績あり）。これを cloud/AI ツールへ転用する。

## 5. 新設計

### 5.1 `--mode` の廃止

- usage・入力検証・`get_template_content` の `mode:` 次元をすべて撤去する。
- `--mode` が渡された場合は**未知オプションとしてエラー**にする（黙って無視しない。案B）。
- 生成物名の `(minimal)`/`(standard)`/`(full)` サフィックスは撤去、または固定名（例: プロジェクト名のみ）にする。

### 5.2 docker のリッチさを標準化

- 全生成 devcontainer.json の `docker-outside-of-docker` を standard/full 相当（`moby:false` + `dockerDashComposeVersion:latest` + `installDockerComposeSwitch:true` + `installDockerBuildx:true`）で固定する。
- minimal 相当の最小オプションは廃止。

### 5.3 cloud フラグ（`--with-aws` / `--with-gcp` + Terraform 同梱）

- `--with-aws`: `ghcr.io/devcontainers/features/aws-cli:1` + 拡張 `amazonwebservices.aws-toolkit-vscode`。
- `--with-gcp`: `ghcr.io/dhoeric/features/google-cloud-cli:1` + 拡張 `GoogleCloudTools.cloudcode`。（GCP は公式 feature が無く外部 dhoeric に依存＝現状踏襲）
- Terraform: `--with-aws` **または** `--with-gcp` のいずれかが指定されたとき、`ghcr.io/devcontainers/features/terraform:1` + 拡張 `hashicorp.terraform` を**1 回だけ**同梱。両方指定でも重複させない。cloud 無指定なら入れない。
- 実装は devcontainer.json テンプレに条件プレースホルダ（例 `__IF_WITH_AWS__` / `__IF_WITH_GCP__` / `__IF_WITH_TERRAFORM__`）を置き、選択に応じて有効化/削除（§5.7）。Terraform のプレースホルダは「aws OR gcp」で有効化する。

### 5.4 AI ツールフラグ（`--with-claude` / `--with-gemini` / `--with-copilot`）

各フラグ指定時、次の 3 点を**同型**で行う。

| フラグ | CLI（install-ai-tools.sh で導入） | VSCode 拡張 | 永続化する設定ディレクトリ |
|---|---|---|---|
| `--with-claude` | `@anthropic-ai/claude-code`（`claude`） | Claude 公式拡張 ※ID は実装時確定 | `~/.claude` |
| `--with-gemini` | `@google/gemini-cli`（`gemini`） | Gemini 拡張 ※ID は実装時確定 | `~/.gemini` |
| `--with-copilot` | GitHub Copilot CLI ※パッケージ名は実装時確定 | `github.copilot`, `github.copilot-chat` | Copilot 設定ディレクトリ ※実装時確定 |

- **自動インストール廃止**: 生成される `install-ai-tools.sh` は「選択された AI ツールのみ」を無条件に導入する。トークン有無（`CLAUDE_CODE_OAUTH_TOKEN` 等）での分岐は行わない。トークンは従来どおり `remoteEnv` で渡し、認証はランタイムで行う。
- 何も `--with-<ai>` を指定しなければ、`install-ai-tools.sh` は AI ツールを一切導入しない（no-op として生成、または `postCreateCommand` から外す）。
- ※印の識別子（Claude/Gemini の拡張 ID、Copilot CLI のパッケージ名と設定ディレクトリ）は、パッケージ中立・恒久提供を確認のうえ**実装時に確定**する。

### 5.5 AI 認証の永続化を全生成物へ

- compose.yaml を 1 本化し、**選択した AI ツールごとに** named volume を条件付きで定義・マウントする（`--with-claude`→`claude-storage:~/.claude`、等）。
- mode ではなく AI ツールフラグで決まるため、どの環境でもリビルドを跨いで認証・履歴が保持される。full 限定を撤廃。
- AI ツール未選択時は AI 用 volume を定義しない（docker socket 等の既存マウントは維持）。

### 5.6 拡張点（予定フラグの枠）

将来 `--with-*` を追加する際に、フラグ 1 本 + 条件配線エントリだけで載るようにする。今回は**実装しないが設計で想定**する。

| 予定フラグ | 種別 | 想定配線 |
|---|---|---|
| `--with-codex` | AI ツール | CLI + 拡張 + 永続化（§5.4 と同型） |
| `--with-sakura` | cloud（さくらのクラウド） | CLI（`sacloud`/`usacloud` 等）+ 拡張（あれば）。§5.3 と同型 |
| `--with-cloudflare` | cloud（Cloudflare） | CLI（`wrangler` 等）+ 拡張（あれば）。§5.3 と同型 |

- allowlist・条件プレースホルダ・（AI なら）install ブロックと volume を追加するだけで拡張できる構造にする。
- 予定フラグは usage / README に「未対応」として出さない（実装時に追記）。ただし内部の with-set 検証や配線機構は将来値を受け入れやすい形にしておく。

### 5.7 条件配線の実装方式

- 繰り返し可能な `--with-<name>` ブールフラグを受理し、内部で **with-set**（重複排除した選択集合）へ正規化する。allowlist は今回実装分（`aws` `gcp` `claude` `gemini` `copilot`）。
- `has_with <name>`（with-set に含まれるか）を述語として用意。既存 `has_language` と対になる。
- devcontainer.json / compose.yaml / install-ai-tools.sh に `__IF_WITH_<NAME>__` 系プレースホルダを置き、`render_content` を拡張して「選択時は有効行へ展開、非選択時は sed で行削除」する（言語機構と同一パターン）。Terraform は「aws OR gcp」の合成条件で処理。
- bash 3.2 互換のため連想配列は使わず、`case` 分岐と space 区切り文字列（`" aws gcp "` 形式の包含判定）で with-set を扱う。

## 6. 詳細仕様（変更点一覧）

| # | ファイル | 変更内容 |
|---|---|---|
| 1 | `bootstrap.sh` usage/引数解析 | `--mode` を削除。`--with-<name>`（繰り返し可）を追加し with-set へ正規化。allowlist 検証（`aws\|gcp\|claude\|gemini\|copilot`）と未知値エラー |
| 2 | `bootstrap.sh` 入力検証 | `case "$MODE" in ...` を撤去 |
| 3 | `bootstrap.sh` `get_template_content` | `case "$mode:$rel"` を `case "$rel"` へ。ファイルごとに単一テンプレートへ集約（devcontainer.json / compose.yaml / on-attach.sh / post-rebuild-check.sh / install-ai-tools.sh） |
| 4 | `bootstrap.sh` devcontainer.json テンプレ | docker を standard/full 相当で固定。cloud/AI 拡張・Terraform を `__IF_WITH_*__` 条件プレースホルダ化。features と `customizations.vscode.extensions` の両方に配線 |
| 5 | `bootstrap.sh` compose.yaml テンプレ | 単一化。AI ツールごとの named volume を `__IF_WITH_<AI>__` 条件で定義・マウント（full 限定を撤廃） |
| 6 | `bootstrap.sh` `install-ai-tools.sh` テンプレ | 単一化。トークン分岐を撤廃し、選択 AI ツールのみ無条件導入。未選択時は AI 導入なし |
| 7 | `bootstrap.sh` `on-attach.sh` / `post-rebuild-check.sh` テンプレ | 単一化。検査/表示コマンドは選択装備（言語 + with-set）に応じて条件配線（`runtime_check_cmd` 等の既存機構と整合） |
| 8 | `bootstrap.sh` `render_content` | `has_with` 述語と with 条件配線（`__IF_WITH_*__` の有効化/削除、Terraform の合成条件）を追加 |
| 9 | `bootstrap.sh` `postCreateCommand` | mode 分岐を撤去し全生成物で統一（診断 `post-rebuild-check.sh` を全生成物で配線するか要検討＝§9） |
| 10 | `doctor.sh` | mode 前提の検査を撤去。with-set 由来の feature/拡張/volume の整合検査へ更新 |
| 11 | `packages/devcontainer-bootstrap/README.md` | `--mode` の記述を全削除。`--with-*` の仕様・使用例・cloud/AI 装備表・永続化の説明を追加。**リリース版ピン留め節（`validate_dcb_docs` 対象）を新版へ更新** |
| 12 | `tests/` | mode 前提テストの撤去/改修。with-set 条件配線・Terraform 合成条件・AI 永続化・自動インストール廃止の検証を追加（§7） |

### 6.1 使用例（変更後の想定）

```bash
# 素の環境（cloud も AI ツールも無し）
./bootstrap.sh --project-name myapp --languages node

# GCP だけ（Terraform 同梱）＋ Claude
./bootstrap.sh --project-name myapp --languages go --with-gcp --with-claude

# AWS + GCP（Terraform は 1 回）＋ Copilot
./bootstrap.sh --project-name myapp --languages node,go --with-aws --with-gcp --with-copilot
```

## 7. 受け入れ条件（Acceptance）

- [ ] `--mode` を渡すと未知オプションとしてエラー終了する（黙って無視しない）。
- [ ] `--mode` 無しで生成でき、docker feature は buildx + compose-switch を含む（全生成物で standard/full 相当）。
- [ ] `--with-aws` 指定時のみ aws-cli feature + aws-toolkit 拡張 + Terraform（feature/拡張）が入る。非指定時は入らない。
- [ ] `--with-gcp` 指定時のみ google-cloud-cli feature + cloudcode 拡張 + Terraform が入る。非指定時は入らない。
- [ ] `--with-aws --with-gcp` で Terraform feature/拡張が**1 回だけ**入る（重複しない）。cloud 無指定なら Terraform は入らない。
- [ ] `--with-claude`/`--with-gemini`/`--with-copilot` 指定時のみ、対応 CLI が `install-ai-tools.sh` に現れ、対応 VSCode 拡張が入り、対応する named volume が compose に定義・マウントされる。
- [ ] AI ツールの導入がトークン有無に依存しない（`install-ai-tools.sh` に `CLAUDE_CODE_OAUTH_TOKEN` 等での分岐が無い）。未選択の AI ツールは一切導入されない。
- [ ] AI 永続化が mode 非依存（選択すればどの生成物でも volume が付く）。
- [ ] 生成された devcontainer.json / compose.yaml が妥当（`jq` 解釈可、条件配線の有無で末尾カンマ等の破損が無い）。`docker compose config` がエラー無し。
- [ ] `doctor.sh` が新生成物を正しく判定し、mode 前提の誤検査をしない。
- [ ] DCB README に `--mode` の記述が残らず、`--with-*` の仕様・使用例が日本語で一貫。リリース版ピン留めが新版と一致（`validate_dcb_docs` 通過）。
- [ ] `bootstrap.sh` は `bash -n` 通過、bash 3.2 互換（連想配列不使用）。
- [ ] `tests/run-tests.sh` が全 green（新規アサーション含む）。

## 8. テスト計画

`tests/` を改修・追加する。最低限:

1. `--mode` を渡すとエラー（allowlist 撤去の回帰）。
2. 素の生成物に buildx/compose-switch が**ある**（docker 標準化）。
3. `--with-aws` あり/なしで aws feature・aws 拡張・Terraform の有無が切り替わる。
4. `--with-gcp` あり/なしで gcp feature・cloudcode 拡張・Terraform の有無が切り替わる。
5. `--with-aws --with-gcp` で Terraform が 1 回だけ（重複検出）。cloud 無指定で Terraform 無し。
6. 各 `--with-<ai>` で CLI 行・拡張・volume が三点セットで現れ、非選択では現れない。
7. `install-ai-tools.sh` にトークン分岐が無い（自動インストール廃止の回帰）。
8. AI 永続化が mode に依存しない（旧 full 相当以外でも volume が付く）。
9. 条件配線の全組み合わせ（cloud/AI の有無）で devcontainer.json / compose.yaml が妥当 JSON/YAML（`jq` / `docker compose config`）。
10. `doctor.sh` が新生成物で誤検査しない。
11. 既存 `--languages` 機構が回帰していない（言語 feature の有効化/削除、gitignore、検査行）。

## 9. 作業計画（フェーズ）

進捗の正本は issue / PR。以下は分解の目安。

1. **仕様確定**: 本書レビュー → 実装 issue 化。※印の識別子（Claude/Gemini 拡張 ID、Copilot CLI パッケージ名・設定ディレクトリ）を事前調査で確定。
2. **実装（引数・検証）**: `--mode` 撤去、`--with-<name>` 受理と with-set 正規化・allowlist 検証、`has_with` 述語。
3. **実装（テンプレ集約）**: `get_template_content` を単一テンプレート化（devcontainer.json / compose.yaml / install-ai-tools.sh / on-attach.sh / post-rebuild-check.sh）。docker 標準化を反映。
4. **実装（条件配線）**: `render_content` に `__IF_WITH_*__` の有効化/削除、Terraform 合成条件、AI の CLI/拡張/volume の三点配線を追加。
5. **実装（doctor.sh）**: mode 前提の検査を with-set ベースへ更新。
6. **README 更新**: `--mode` 記述削除、`--with-*` 仕様・使用例・装備表・永続化説明。リリース版ピン留めの更新は§10 のリリース時。
7. **テスト**: §8 のアサーション追加・既存 mode テストの改修/撤去。
8. **検証**: `tests/run-tests.sh` / `docker compose config`（複数の with 組み合わせ）/ `doctor.sh` / `jq`。
9. **レビューゲート**: `/code-review` → `scripts/gemini-review.sh`（クロスモデル二段）。
10. **PR 作成・マージ**。
11. **リリース（別作業）**: **破壊的変更**（`--mode` 削除）。案B により版を上げる。現行 `v0.3.1` からの推奨は `v0.4.0`（0.x では minor で破壊的変更を許容。最終番号はリリース時判断）。README 移行ノートに「`--mode` 廃止と `--with-*` への移行」を明記。`scripts/release-packages.sh` を唯一の経路とし、事前に DCB README のピン留め版を更新（preflight `validate_dcb_docs` 要件）。ai-playbook は本件で変更しないため同時リリース不要。

## 10. リスク・留意点

- **破壊的変更の周知**: `--mode` を使う既存利用者・ドキュメント・呼び出しスクリプトが壊れる。README にマイグレーション節（旧 `--mode standard` 相当＝`--with-aws`、旧 `full` 相当＝`--with-aws --with-gcp --with-claude --with-gemini` 等の対応表）を用意する。
- **条件配線の JSON/YAML 破損**: 非選択エントリ削除で末尾カンマや空 `volumes:` が残ると壊れる。既存の末尾カンマ除去 + `jq` 整形（`write_file`）を経由させ、テスト 9 で担保。空になり得る `features`/`extensions`/`volumes` ブロックの縮退を検証する。
- **Terraform の合成条件**: 「aws OR gcp」を 1 回だけ。両指定時の二重挿入・片方だけ指定時の欠落をテスト 5 で担保。
- **自動インストール廃止の影響**: 従来トークンだけで claude/gemini が入っていた利用者は、`--with-claude`/`--with-gemini` を明示しないと入らなくなる。README マイグレーションで明記。
- **識別子の恒久性・中立性**: Claude/Gemini 拡張 ID、Copilot CLI のパッケージ名は変動・非公式の可能性がある。パッケージ中立・恒久提供を確認して確定し、不確実なものは実装を保留（予定フラグ側へ回す）。
- **テンプレ集約の回帰**: 3→1 集約で既存生成物（特に standard 利用者）の出力が変わる。既存テストの期待値を新設計に合わせて更新しつつ、`--languages` など無関係機構の回帰が無いことをテスト 11 で担保。
- **bash 3.2 互換**: with-set は連想配列を使わず space 区切り文字列 + `case` で扱う。macOS 標準 bash を壊さない。
- **拡張点の空振り**: 予定フラグ（codex/sakura/cloudflare）は allowlist に含めない。将来追加時に「フラグ 1 本 + 配線エントリ」で済むことを、今回の機構設計で担保する（実装はしない）。

## 11. 関連

- 実装対象: [packages/devcontainer-bootstrap/bootstrap.sh](../../packages/devcontainer-bootstrap/bootstrap.sh) / [doctor.sh](../../packages/devcontainer-bootstrap/doctor.sh)
- 再利用する条件配線の先行例: `--languages`（`has_language`→sed 機構）。本計画の `has_with` はこれと対になる
- リリース手順: [RELEASE_EXECUTION_RUNBOOK](../release/RELEASE_EXECUTION_RUNBOOK.md) / [RELEASE_HISTORY](../release/RELEASE_HISTORY.md)
- 先行計画の体裁: [DCB_RUST_SUPPORT](DCB_RUST_SUPPORT.md)
