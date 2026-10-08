# Dependabot alerts。SECURITY.md の窓口と対で有効にする（.github/project-ai-rules.md
# 「脆弱性の報告と通知」）。github_repository の vulnerability_alerts は非推奨のため、
# 専用の資源で持つ。
resource "github_repository_vulnerability_alerts" "public" {
  for_each = github_repository.public

  repository = each.value.name
  enabled    = true
}

# Dependabot security updates。alerts が有効でないと GitHub が受け付けないので、
# alerts の後に作る。
resource "github_repository_dependabot_security_updates" "public" {
  for_each = github_repository_vulnerability_alerts.public

  repository = each.value.repository
  enabled    = true
}

# 非公開の脆弱性の報告（private vulnerability reporting）。
#
# GitHub provider（v6.13）はこの設定を扱えないため、gh api の PUT で有効にする（#487）。
# PUT は冪等で、既に有効なら何も変わらない。
#
# **限界: 実行するのは、リポジトリが作られたとき（node_id が変わったとき）と、この資源を
# 初めて作ったときだけです。** GitHub 側で無効にされても plan には差分が出ません。
# 有効かどうかの照合は scripts/check-repo-security.sh が担います。
resource "terraform_data" "private_vulnerability_reporting" {
  for_each = github_repository.public

  triggers_replace = [each.value.node_id]

  provisioner "local-exec" {
    # GH_TOKEN は terraform.yml が渡す（GITHUB_TOKEN と同じ PAT）。
    command = "gh api -X PUT \"repos/${var.owner}/${each.value.name}/private-vulnerability-reporting\" --silent"
  }
}
