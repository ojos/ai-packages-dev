---
paths:
  - "scripts/setup-git-identity.sh"
  - "scripts/verify-commit-identity*.sh"
  - ".github/workflows/identity-guard.yml"
  - "scripts/on-attach.sh"
  - ".env.example"
---

地図（`.github/project-ai-rules.md`）の「Git identity と GitHub 認証」の詳細です。global の identity に依存しないこと、人の名義で commit することは地図が常時持ちます。

- git identity の値（`GIT_IDENTITY_NAME` / `GIT_IDENTITY_EMAIL`）: 人の操作は `.env`、release workflow は Actions のリポジトリ変数 `RELEASE_BOT_NAME` / `RELEASE_BOT_EMAIL`。値の一覧と設定先は `docs/release/RELEASE_EXECUTION_RUNBOOK.md`「前提条件（リポジトリ設定）」。

## Git identity（コミット作者情報）

`ojos/*` リポジトリへの git 操作の名義は、**操作の主体**で分けます。例外を積み上げるより、主体で分けるほうが機構が増えても破綻しないためです。

| 主体 | 名義 | 適用範囲 |
|---|---|---|
| 人の操作 | `user.name` = `.env` の `GIT_IDENTITY_NAME`（= `Ido`） / `user.email` = `.env` の `GIT_IDENTITY_EMAIL`（= `ido@ojos.jp`） | commit / tag / push のすべて（既定） |
| 機構の操作 | GitHub App の bot（`ojos-release-bot[bot]`） | **公開リポジトリへの release snapshot コミットのみ** |

機構の名義を分けるのは、実行主体とコミット名義を一致させるためです。人の名義を機械が打つと、履歴が実態と乖離します。
bot の適用範囲は上表のとおりで、本モノレポへは bot がコミットしません（リリース後の `README.md` 更新も人が行います。`docs/release/RELEASE_EXECUTION_RUNBOOK.md`「事後確認」）。

順守事項:

- global の identity には依存しません。`scripts/setup-git-identity.sh` が global の `user.name` / `user.email` を削除し、`user.useConfigOnly=true` を立てます。Dev Container はホストの `~/.gitconfig`（別アカウントの identity の場合がある）をコピーするため、そこへ落ちる経路を残しません。
- コンテナ接続時に `scripts/on-attach.sh` が `setup-git-identity.sh` を再適用します（リビルドのたびに ~/.gitconfig が再生成されるため）。`bash scripts/setup-git-identity.sh --check` で状態を検証できます。
- local 設定を持たないリポジトリでは `git commit` が exit 128 で止まります。これは設計どおりです。黙って別名義のコミットが通るより、止まって気づくほうを選びます。
- リポジトリ外の一時クローンでコミットするスクリプトは、`git -c user.name=... -c user.email=...` で identity を明示します（`scripts/release-packages.sh`）。CI の `Self devcontainer credential isolation` ジョブが明示を検査します。値の供給元は主体で変わります（release workflow は bot の値を渡し、それ以外は `.env` が供給元です）。
- push / リリース実行の前に `bash scripts/verify-commit-identity.sh` で作者情報を検証します。別 identity を検出した場合は中断し、`bash scripts/setup-git-identity.sh` を適用したうえで該当コミットを `git rebase` で author ごと作り直します。単発の目視確認には `git log -1 --format='%an <%ae>'` を使います。

### commit identity の検証層

判定ロジックは `scripts/verify-commit-identity.sh` に置き、CI と手元で同じコードを走らせます。手元で先に落とせるようにするためです。

```bash
bash scripts/verify-commit-identity.sh              # 既定: origin/main..HEAD（取得できなければ HEAD の全履歴）
bash scripts/verify-commit-identity.sh <range>      # 任意の範囲
bash scripts/verify-commit-identity.sh --full       # HEAD の全履歴
```

- 終了コード 0 = `IDENTITY_PASS` / 1 = `IDENTITY_FAIL`（許可外の identity を検出、または範囲・許可 email を解決できない）。
- 判定は名前ではなく **email** で行います（GitHub の Contributors は既定ブランチのコミット author の email で集計されるため）。対象は author / committer / `Co-Authored-By` の 3 つです。
- committer には `noreply@github.com` を、`Co-Authored-By` にはさらに `noreply@anthropic.com` を追加で許可します（squash merge / web UI コミット、および AI コーディング規約の trailer に対応）。
- 許可 author email の解決順は、`ALLOWED_AUTHOR_EMAILS`（カンマまたは空白区切り）→ `.env` の `GIT_IDENTITY_EMAIL`。どちらでも解決できない場合は「検査対象が無いので通過」にせず、fail-closed で落とします。
- 許可エントリは既定で完全一致です。加えて `@example.com` / `*@example.com` の **2 形だけ**をドメイン一括指定として解釈します。任意の glob を許さないのは、設定ミスの `*` 1 文字で全 email が通り、検知層が黙って無効化されるためです（`*` 単体は何も許可しません）。ローカル部は 1 文字以上を要求し、`@` を含む形（`attacker@untrusted.com@example.com`）は通しません。
- committer が `noreply@github.com` のコミットに限り、author が `<login>@users.noreply.github.com` の形であれば許可します。GitHub 側でメール非公開を有効にした利用者の PR マージ・web UI 編集がこの形になるためです。許可を committer に縛るのは、適用漏れが通る範囲を狭めるためです。committer / author の email はローカルで自由に設定できるため、**この許可は偽装を防ぎません**（ローカルで作ったコミットでも、この 2 つを GitHub の形に設定すれば通ります）。この検査の目的は identity の適用漏れ（別アカウントの email の混入）の検出で、意図的な偽装への対策は、書き込み権限の管理と、必要なら署名の検証（GitHub の verified な web-flow の署名）が担います。署名の検証を入れると、手元で数 ms で落とすという性質を失うため、判定は変えません。書き込み権限を持つアカウントが Contributors に現れることは許容し、誰に権限を与えるかはリポジトリ側の責務として切り分けます（偽装を防がないことも、同じ側の判断です）。
- 同じ条件（`is_github_authored`）を `Co-Authored-By` にも適用します。マージした人と PR の作者が違う squash merge では、GitHub がマージの瞬間に作者を `Co-authored-by` として足すためです（PR の検査では見えず、`push(main)` の全履歴検査で初めて現れます）。この許可も committer を縛るだけで、偽装は防ぎません（上の項目と同じです）。
- `scripts/verify-commit-identity-selftest.sh` が判定ロジックの自己試験です。1 コミットだけの仕込みのリポジトリで、通すべき形と落とすべき形の両方を確かめます。本物の履歴だけでは落ちるべき形がほとんど現れないため、`identity-guard.yml` は `verify-commit-identity.sh` の検証より前にこれを呼びます。
- CI の検知層は `.github/workflows/identity-guard.yml` です。`pull_request`（`opened` / `synchronize` / `reopened`）では PR に含まれる全コミットを、`push`（`main`）では main の全履歴を検査します。PR を経由しない直接 push こそが混入の原因なので、後者を省略しません。
- 許可 email は生成物へ焼き込まず、**リポジトリ変数** `ALLOWED_AUTHOR_EMAILS`（Settings > Secrets and variables > Actions > Variables）で渡します。CI には `.env` が無いため、これを設定しないと identity-guard は fail-closed で必ず失敗します。
- **release workflow の bot は許可 email に加えません。** bot が名義を持つのは公開リポジトリへの release snapshot だけで、本モノレポへはコミットしないためです（identity-guard の検査対象は本モノレポのみ）。今は使わない許可を先回りして広げると、その分だけ fail-closed の検知力が落ちます。必要になった時点で加えます。

