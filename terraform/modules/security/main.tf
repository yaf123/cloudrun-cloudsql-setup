# =============================================================================
# Cloud Armor セキュリティポリシー
# =============================================================================
resource "google_compute_security_policy" "web" {
  name = "${var.prefix}-armor-policy"

  # SQLインジェクション防御
  rule {
    action   = "deny(403)"
    priority = 1000

    match {
      expr {
        expression = "evaluatePreconfiguredExpr('sqli-v33-stable')"
      }
    }

    description = "SQLi defense"
  }

  # XSS防御
  rule {
    action   = "deny(403)"
    priority = 1001

    match {
      expr {
        expression = "evaluatePreconfiguredExpr('xss-v33-stable')"
      }
    }

    description = "XSS defense"
  }

  # レート制限
  rule {
    action   = "throttle"
    priority = 1002

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }

    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      rate_limit_threshold {
        count        = var.rate_limit_count
        interval_sec = var.rate_limit_interval
      }
    }

    description = "Rate limiting"
  }

  # デフォルト許可
  rule {
    action   = "allow"
    priority = 2147483647

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }

    description = "Default allow"
  }
}
