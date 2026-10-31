---
paths:
  - "infra/**"
  - "scripts/release-packages.sh"
  - "scripts/check-repo-security.sh"
  - ".github/workflows/release.yml"
  - ".github/workflows/terraform.yml"
  - "docs/release/**"
  - "SECURITY.md"
---

地図（`.github/project-ai-rules.md`）の「外部サービスの状態管理」の詳細です。リリースをローカルで実行しないことは地図が常時持ちます。

## 外部サービスの状態管理

共通規範「外部サービスの状態管理」を、このリポジトリで具体化します。

- 対象の外部状態: 公開リポジトリ（`ojos/devcontainer-bootstrap` / `ojos/ai-playbook` / `ojos/devcontainer-host`。存在と設定は `infra/github/` の Terraform、中身の反映は `scripts/release-packages.sh`）、GitHub Release、タグ
- 宣言・適用の手段: `scripts/release-packages.sh`。ソースの反映・タグ付け・Release 作成を冪等に行い、公開済みバージョンの再公開を preflight で拒否します（不変性）
- **実行場所は GitHub Actions（`.github/workflows/release.yml` の `workflow_dispatch`）です。ローカルからのリリース実行は行いません。** 実行環境を一本化し、手元の環境差に起因する失敗経路を残さないためです。手順は `docs/release/RELEASE_EXECUTION_RUNBOOK.md`
- この禁止は文書ではなく機構で担保します。`scripts/release-packages.sh` は `GITHUB_ACTIONS` を見て、Actions 外での `--execute` を preflight より前に拒否します。副作用を持たない dry-run と `--audit` はローカルでも実行できます
- 手動 `gh` / `git push` は状態確認・調査に留めます。リリースの恒久的操作はスクリプトを通します
- やむを得ず手動で公開状態を変えた場合は、スクリプト側の前提（README の固定バージョン等）へ後追いで反映します
- **公開リポジトリそのもの（存在と設定）は Terraform で宣言します（`infra/github/`。#487）。** 上のリリースのスクリプトが扱うのは公開物の中身（ソース・タグ・Release）で、リポジトリを作る・設定を変えることはしません。この 2 つの関心を分けます
  - 対象: 配布先の公開リポジトリ（`infra/github/repositories.tf` の一覧）。このモノレポ自身と、配布物以外の `ojos/*` は対象外です
  - 状態ファイルは HCP Terraform（組織 `OJOS` / ワークスペース `github-ai-packages-dev`）に置きます。Execution Mode は Local で、HCP は置き場所としてだけ使います
  - **実行場所は GitHub Actions（`.github/workflows/terraform.yml`）です。** PR で plan を出して PR へコメントし、`main` へのマージで apply します。fmt / validate は資格情報が要らないので `ci.yml` の `terraform` ジョブ（`scripts/acceptance.sh` がミラー）で回します
  - **apply を `main` の Actions からだけにすることは、資格情報の置き場所で担保します。** 書き込みの fine-grained PAT（`TF_GITHUB_PAT`）は、配備先を `main` に絞った Environment `terraform-apply` の secret にだけ置き、`.env` にもリポジトリの secret にも置きません。terraform のコマンドは手元からも打てるのでスクリプトで拒否しても迂回でき、PR のワークフローは PR のブランチで書き換えられるので、ワークフローの記述でも担保できないためです。PR の plan には、読み取りの PAT（`TF_GITHUB_PAT_READ`）を使います。一覧と設定の手順は `infra/github/README.md`「資格情報」
  - **公開リポジトリを消す plan は apply しません。** リポジトリに `prevent_destroy` と `archive_on_destroy` を付け、`terraform.yml` も plan の中にリポジトリの削除・作り直しがあれば apply の前に落とします（`scripts/terraform-refuse-destroy.sh`）。PAT の Administration: write は削除もできる権限だからです
  - リリースの GitHub App を新しいリポジトリへ install することは、手作業のまま残します（個人のアカウントでは PAT で扱えない見込みのため。#487 の scope.out）

### 脆弱性の報告と通知

公開リポジトリなので、脆弱性を見つけた人が非公開で知らせる窓口と、依存の脆弱性の通知を有効にしておきます（#394）。報告の宛先としての説明は、リポジトリ直下の `SECURITY.md` が持ちます。

- 対象の設定は 3 つです: Private vulnerability reporting（非公開の報告窓口）、Dependabot alerts、Dependabot security updates
- **配布先の公開リポジトリでは、この 3 つを Terraform で有効にします（`infra/github/security.tf`）。** Dependabot の 2 つは provider の資源で宣言します。Private vulnerability reporting は provider が扱えないため、`terraform_data` から `gh api` の `PUT` を打ちます。こちらは実行がリポジトリを作ったときに限られ、外で無効にされても plan に差分が出ません
- **このモノレポ自身は Terraform の対象外なので、手で有効にします**（下のコマンド）。リリースのスクリプトの関心（公開物の反映）とは別で、一度有効にすれば変える理由が無いためです
- どちらの場合も、`scripts/check-repo-security.sh` で照合します（引数で `owner/repo` を渡せます）。`SECURITY.md` が案内する窓口が閉じたまま、案内だけが残る状態を塞ぐためです
- 有効にするにも照合するにも、リポジトリの管理者権限のトークンが要ります（fine-grained PAT なら Administration。読むだけなら read、有効にするなら write）。`.env` の `GH_TOKEN` に権限が無いときは、`env -u GH_TOKEN` で `gh auth login` 済みの資格情報を使います
- 照合は CI のゲートに入れません。CI の `GITHUB_TOKEN` では Dependabot の 2 つを読めないためです。設定を変えたときと、リリースの前に持ち主が回します
- Dependabot の version updates（`.github/dependabot.yml`）は入れていません。security updates は脆弱性があるときだけ PR を出します

```bash
# 有効にする（どれも冪等）
gh api -X PUT repos/ojos/ai-packages-dev/private-vulnerability-reporting
gh api -X PUT repos/ojos/ai-packages-dev/vulnerability-alerts
gh api -X PUT repos/ojos/ai-packages-dev/automated-security-fixes   # alerts が有効でないと失敗する

# 照合する（0 = 3 つとも有効 / 1 = 無効がある / 2 = 読めない＝前提の不成立）
bash scripts/check-repo-security.sh
bash scripts/check-repo-security.sh ojos/devcontainer-bootstrap   # 配布先も同じく照合できる
```

