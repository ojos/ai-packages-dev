# infra/github — 公開リポジトリの宣言

`ojos` の公開リポジトリ（配布先）の存在と設定を、Terraform で宣言的に管理します（#487）。共通規範「外部サービスの状態管理」（`.ai-playbook/shared-ai-rules.md` 4 章）のこのリポジトリでの具体化で、方針は `.github/project-ai-rules.md`「外部サービスの状態管理」にあります。

| 項目 | 内容 |
|---|---|
| 管理する対象 | `repositories.tf` の `local.repositories` に並べたリポジトリ |
| 状態ファイル | HCP Terraform（組織 `OJOS` / ワークスペース `github-ai-packages-dev`。Execution Mode は Local） |
| 実行する場所 | GitHub Actions（`.github/workflows/terraform.yml`）。PR で plan、`main` へのマージで apply |
| 資格情報 | Actions の secret の `TF_GITHUB_PAT`（GitHub）と `TF_API_TOKEN`（HCP Terraform） |

## 手元でできること

手元では、整形と構文の検査だけを行います。apply に要る PAT は Actions の secret にだけ置くため、手元からは apply できません（そう作っています）。

```bash
terraform -chdir=infra/github fmt -check -recursive
terraform -chdir=infra/github init -backend=false
terraform -chdir=infra/github validate
```

## リポジトリを足す

`local.repositories` に 1 行足して PR を作ります。PR の plan に、そのリポジトリの作成と、セキュリティの設定（Dependabot alerts / security updates / 非公開の脆弱性の報告）の有効化が出ます。

既にあるリポジトリを取り込むときは `imported = true` にします。`import` ブロックが管理下へ取り込み、plan には取り込みと設定の差分だけが出ます。

## 消さない

リポジトリには `prevent_destroy` と `archive_on_destroy` を付けています。`local.repositories` から行を消すと、plan が誤りとして止まります。管理から外すだけなら、`removed` ブロックで状態から外してください（リポジトリは GitHub に残ります）。

## 非公開の脆弱性の報告

GitHub provider が扱えないため、`terraform_data` から `gh api` の `PUT` で有効にします。実行されるのはリポジトリを作ったときと、その資源を初めて作ったときだけです。GitHub の画面などで無効にされても plan には差分が出ないので、照合は `scripts/check-repo-security.sh` で行います。
