# =============================================================================
# Cloud Build サービスアカウント権限
# デフォルトの Cloud Build SA に必要な権限を付与
# =============================================================================

data "google_project" "current" {}

locals {
  cloud_build_sa = "serviceAccount:${data.google_project.current.number}@cloudbuild.gserviceaccount.com"
}

resource "google_project_iam_member" "cloudbuild_roles" {
  for_each = toset([
    "roles/run.admin",
    "roles/artifactregistry.writer",
    "roles/iam.serviceAccountUser",
  ])

  project = var.project_id
  role    = each.value
  member  = local.cloud_build_sa
}

# =============================================================================
# Cloud Build トリガー（GitHub リポジトリ接続後に有効化）
#
# GitHub との接続は GCP コンソールで手動設定が必要:
#   Cloud Build → トリガー → リポジトリを接続
#   接続後に github_repo_name を設定して count = 1 にする
# =============================================================================
resource "google_cloudbuild_trigger" "deploy" {
  count    = var.github_repo_name != "" ? 1 : 0
  name     = "${var.prefix}-deploy"
  location = var.region

  github {
    owner = var.github_owner
    name  = var.github_repo_name

    push {
      branch = var.trigger_branch
    }
  }

  filename = "cloudbuild.yaml"

  substitutions = {
    _ENV          = var.env
    _REGION       = var.region
    _PROJECT_NAME = var.project_name
  }
}
