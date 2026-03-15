# =============================================================================
# 外部IP
# =============================================================================
resource "google_compute_global_address" "lb_ip" {
  name = "${var.prefix}-lb-ip"
}

# =============================================================================
# Serverless NEG（Cloud Run 用）
# =============================================================================
resource "google_compute_region_network_endpoint_group" "serverless_neg" {
  name                  = "${var.prefix}-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run {
    service = var.cloud_run_service_name
  }
}

# =============================================================================
# バックエンドサービス
# =============================================================================
resource "google_compute_backend_service" "web" {
  name                  = "${var.prefix}-backend"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  security_policy       = var.security_policy_id

  backend {
    group = google_compute_region_network_endpoint_group.serverless_neg.id
  }
}

# =============================================================================
# URLマップ
# =============================================================================
resource "google_compute_url_map" "web" {
  name            = "${var.prefix}-urlmap"
  default_service = google_compute_backend_service.web.id
}

# =============================================================================
# HTTP（常に有効）
# =============================================================================
resource "google_compute_target_http_proxy" "web" {
  name    = "${var.prefix}-http-proxy"
  url_map = google_compute_url_map.web.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.prefix}-http-fw-rule"
  target                = google_compute_target_http_proxy.web.id
  ip_address            = google_compute_global_address.lb_ip.id
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# =============================================================================
# HTTPS（ドメイン設定時のみ有効）
# =============================================================================
resource "google_compute_managed_ssl_certificate" "web" {
  count = var.domain != "" ? 1 : 0
  name  = "${var.prefix}-cert"

  managed {
    domains = [var.domain]
  }
}

resource "google_compute_target_https_proxy" "web" {
  count            = var.domain != "" ? 1 : 0
  name             = "${var.prefix}-https-proxy"
  url_map          = google_compute_url_map.web.id
  ssl_certificates = [google_compute_managed_ssl_certificate.web[0].id]
}

resource "google_compute_global_forwarding_rule" "https" {
  count                 = var.domain != "" ? 1 : 0
  name                  = "${var.prefix}-https-fw-rule"
  target                = google_compute_target_https_proxy.web[0].id
  ip_address            = google_compute_global_address.lb_ip.id
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
