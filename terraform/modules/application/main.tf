# =============================================================================
# サービスアカウント
# =============================================================================
resource "google_service_account" "run_sa" {
  account_id   = "${var.prefix}-run-sa"
  display_name = "${var.prefix} Cloud Run Service Account"
}

resource "google_project_iam_member" "roles" {
  for_each = toset([
    "roles/cloudsql.client",
    "roles/secretmanager.secretAccessor",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/artifactregistry.reader",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.run_sa.email}"
}

# =============================================================================
# Cloud Run サービス（マルチコンテナ: Nginx + PHP-FPM）
# =============================================================================
resource "google_cloud_run_v2_service" "app" {
  name                 = "${var.prefix}-app"
  location             = var.region
  ingress              = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  invoker_iam_disabled = true  # 公開アクセスを許可（認証チェック無効化）

  template {
    service_account = google_service_account.run_sa.email

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    # Direct VPC Egress（Cloud SQL Private IP接続用）
    vpc_access {
      network_interfaces {
        network    = var.vpc_id
        subnetwork = var.subnet_id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    # 共有ボリューム（Nginx ↔ PHP-FPM 間の静的ファイル共有）
    volumes {
      name = "static-files"
    }

    # -----------------------------------------------------------------
    # Ingress コンテナ: Nginx
    # -----------------------------------------------------------------
    containers {
      name  = "nginx"
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repo}/nginx:${var.image_tag}"

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = var.nginx_cpu
          memory = var.nginx_memory
        }
      }

      env {
        name  = "PHP_FPM_HOST"
        value = "127.0.0.1"
      }

      volume_mounts {
        name       = "static-files"
        mount_path = "/var/www/html/public"
      }

      startup_probe {
        http_get {
          path = "/health"
          port = 8080
        }
        initial_delay_seconds = 3
        period_seconds        = 5
        failure_threshold     = 5
      }

      depends_on = ["php-fpm"]
    }

    # -----------------------------------------------------------------
    # Sidecar コンテナ: PHP-FPM
    # -----------------------------------------------------------------
    containers {
      name  = "php-fpm"
      image = "${var.region}-docker.pkg.dev/${var.project_id}/${var.repo}/php-fpm:${var.image_tag}"

      resources {
        limits = {
          cpu    = var.php_cpu
          memory = var.php_memory
        }
      }

      env {
        name  = "APP_ENV"
        value = var.env
      }

      env {
        name  = "DB_HOST"
        value = var.db_private_ip
      }

      env {
        name  = "DB_PORT"
        value = "3306"
      }

      env {
        name  = "DB_NAME"
        value = var.db_name
      }

      env {
        name  = "DB_USER"
        value = var.db_user
      }

      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = var.db_secret_id
            version = "latest"
          }
        }
      }

      volume_mounts {
        name       = "static-files"
        mount_path = "/var/www/html/public"
      }

      startup_probe {
        tcp_socket {
          port = 9000
        }
        initial_delay_seconds = 2
        period_seconds        = 5
        failure_threshold     = 5
      }
    }
  }

  depends_on = [google_project_iam_member.roles]
}

# 公開アクセスは google_cloud_run_v2_service の invoker_iam_disabled = true で設定済み
# アクセス制御は Cloud Armor（WAF + レート制限）が担当
