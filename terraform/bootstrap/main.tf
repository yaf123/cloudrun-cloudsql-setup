# =============================================================================
# Terraform State 用 GCS バケット（最初に1回だけ実行）
# =============================================================================
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.8"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_storage_bucket" "tfstate" {
  name     = var.bucket_name
  location = var.region
  project  = var.project_id

  # バージョニング（tfstate の履歴保持）
  versioning {
    enabled = true
  }

  # 均一バケットレベルアクセス（セキュリティ推奨）
  uniform_bucket_level_access = true

  # 古いバージョンの自動削除（コスト管理）
  lifecycle_rule {
    condition {
      num_newer_versions = 10
    }
    action {
      type = "Delete"
    }
  }

  # 誤削除防止
  force_destroy = false
}
