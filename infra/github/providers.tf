# 資格情報はコードに書かず、環境変数 GITHUB_TOKEN から provider が読む。
# 値は Actions の secret（TF_GITHUB_PAT）で、terraform.yml がジョブの中でだけ渡す。
# 手元のシェルに GITHUB_TOKEN を恒久的に置かない（.github/project-ai-rules.md「GitHub 認証」）。
provider "github" {
  owner = var.owner
}
