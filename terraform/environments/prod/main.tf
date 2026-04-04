terraform {
  required_version = ">= 1.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.8"
    }
  }

  # GCSバックエンド（bootstrap 実行後に有効化）
  # backend "gcs" {
  #   bucket = "myapp-terraform-state"
  #   prefix = "cloudrun/prod"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# =============================================================================
# API有効化
# =============================================================================
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
    "secretmanager.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudbuild.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# =============================================================================
# モジュール呼び出し
# =============================================================================

module "network" {
  source = "../../modules/network"

  prefix = local.prefix
  region = var.region

  depends_on = [google_project_service.apis]
}

module "database" {
  source = "../../modules/database"

  prefix                 = local.prefix
  region                 = var.region
  vpc_id                 = module.network.vpc_id
  private_vpc_connection = module.network.private_vpc_connection
  db_name                = var.db_name
  db_user                = var.db_user
  db_password            = var.db_password
  db_tier                = var.db_tier
  ha_enabled             = var.ha_enabled
  deletion_protection    = false
}

module "security" {
  source = "../../modules/security"

  prefix           = local.prefix
  rate_limit_count = var.rate_limit_count

  depends_on = [google_project_service.apis]
}

module "registry" {
  source = "../../modules/registry"

  prefix = local.prefix
  region = var.region

  depends_on = [google_project_service.apis]
}

module "application" {
  source = "../../modules/application"

  prefix        = local.prefix
  project_id    = var.project_id
  region        = var.region
  vpc_id        = module.network.vpc_id
  subnet_id     = module.network.subnet_id
  repo          = module.registry.repository_id
  image_tag     = var.image_tag
  min_instances = var.min_instances
  max_instances = var.max_instances
  env           = var.env
  db_private_ip = module.database.private_ip
  db_name       = var.db_name
  db_user       = var.db_user
  db_secret_id  = module.database.secret_id

  depends_on = [google_project_service.apis]
}

module "loadbalancer" {
  source = "../../modules/loadbalancer"

  prefix                 = local.prefix
  region                 = var.region
  cloud_run_service_name = module.application.service_name
  security_policy_id     = module.security.policy_id
  domain                 = var.domain
}

module "cicd" {
  source = "../../modules/cicd"

  prefix           = local.prefix
  project_id       = var.project_id
  project_name     = var.project_name
  region           = var.region
  env              = var.env
  github_owner     = var.github_owner
  github_repo_name = var.github_repo_name

  depends_on = [google_project_service.apis]
}

# =============================================================================
# ローカル変数
# =============================================================================
locals {
  prefix = "${var.project_name}-${var.env}"
}
