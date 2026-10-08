# 管理する公開リポジトリ。ここに 1 行足すと、そのリポジトリが作られ、同じ設定がそろう。
#
# 設定の値は、既存の 2 つ（devcontainer-bootstrap / ai-playbook）を import した直後に
# 差分が出ないよう、2026-10-08 時点の実際の値に合わせている。provider の既定値は
# GitHub の既定値と一致しないものがある（has_issues など）ため、すべて明示する。
locals {
  repositories = {
    "devcontainer-bootstrap" = { imported = true }
    "ai-playbook"            = { imported = true }
    "devcontainer-host"      = { imported = false }
  }
}

# 既存のリポジトリを管理下へ取り込む。新しく作るもの（imported = false）は含めない。
import {
  for_each = { for name, repo in local.repositories : name => repo if repo.imported }
  to       = github_repository.public[each.key]
  id       = each.key
}

resource "github_repository" "public" {
  for_each = local.repositories

  name       = each.key
  visibility = "public"

  has_issues      = true
  has_projects    = true
  has_wiki        = true
  has_discussions = false
  is_template     = false

  allow_merge_commit     = true
  allow_squash_merge     = true
  allow_rebase_merge     = true
  allow_auto_merge       = false
  allow_update_branch    = false
  delete_branch_on_merge = false

  merge_commit_title          = "MERGE_MESSAGE"
  merge_commit_message        = "PR_TITLE"
  squash_merge_commit_title   = "COMMIT_OR_PR_TITLE"
  squash_merge_commit_message = "COMMIT_MESSAGES"

  web_commit_signoff_required = false

  # 中身は release workflow（scripts/release-packages.sh）が push する。
  # Terraform は初期コミットを作らない。
  auto_init = false

  # 万一 destroy の plan が出ても、消さずにアーカイブに留める（二重の安全策の 1 枚目）。
  archive_on_destroy = true

  lifecycle {
    # 公開リポジトリを消す plan は、それ自体を誤りとして止める（2 枚目）。
    # PAT の Administration: write はリポジトリの削除もできるため。
    prevent_destroy = true
  }
}
