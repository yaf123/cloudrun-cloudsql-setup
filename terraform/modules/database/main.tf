# =============================================================================
# Cloud SQL インスタンス
# =============================================================================
resource "google_sql_database_instance" "main" {
  name             = "${var.prefix}-db"
  database_version = var.db_version
  region           = var.region

  depends_on = [var.private_vpc_connection]

  settings {
    tier              = var.db_tier
    availability_type = var.ha_enabled ? "REGIONAL" : "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = var.disk_size
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled                                  = false
      private_network                               = var.vpc_id
      enable_private_path_for_google_cloud_services = true
    }

    backup_configuration {
      enabled                        = true
      start_time                     = var.backup_start_time
      binary_log_enabled             = true
      transaction_log_retention_days = var.backup_retention_days
      backup_retention_settings {
        retained_backups = var.backup_retention_days
      }
    }

    maintenance_window {
      day          = 7
      hour         = 20
      update_track = "stable"
    }
  }

  deletion_protection = var.deletion_protection
}

# =============================================================================
# データベース
# =============================================================================
resource "google_sql_database" "default" {
  name     = var.db_name
  instance = google_sql_database_instance.main.name
}

# =============================================================================
# データベースユーザー
# =============================================================================
resource "google_sql_user" "default" {
  name     = var.db_user
  instance = google_sql_database_instance.main.name
  password = var.db_password
}

# =============================================================================
# Secret Manager（DBパスワード）
# =============================================================================
resource "google_secret_manager_secret" "db_password" {
  secret_id = "${var.prefix}-db-password"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = var.db_password
}
