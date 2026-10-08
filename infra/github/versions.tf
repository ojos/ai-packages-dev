# ojos の公開リポジトリ（配布先）を宣言的に管理する Terraform の設定（#487）。
#
# 状態ファイルは HCP Terraform（組織 OJOS / ワークスペース github-ai-packages-dev）に置く。
# ワークスペースの Execution Mode は Local で、HCP は状態の置き場所としてだけ使う。
# plan / apply は GitHub Actions（.github/workflows/terraform.yml）で実行する。
# 手元から apply しない。apply に要る PAT は Actions の secret にだけ置き、.env には置かない。
terraform {
  required_version = "~> 1.16"

  cloud {
    organization = "OJOS"

    workspaces {
      name = "github-ai-packages-dev"
    }
  }

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }
}
