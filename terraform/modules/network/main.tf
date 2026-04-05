# =============================================================================
# VPC
# =============================================================================
resource "google_compute_network" "vpc" {
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false
}

# =============================================================================
# サブネット
# =============================================================================
resource "google_compute_subnetwork" "subnet" {
  name                     = "${var.prefix}-subnet"
  region                   = var.region
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = var.flow_log_sampling
  }
}

# =============================================================================
# Private Services Access（Cloud SQL用）
# =============================================================================
resource "google_compute_global_address" "private_ip_range" {
  name          = "${var.prefix}-google-managed-services"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 24
  network       = google_compute_network.vpc.id
  address       = var.private_services_cidr
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_range.name]
  deletion_policy         = "ABANDON"  # destroy時のCloud SQL依存エラー回避（Provider既知Issue）
}

# =============================================================================
# GCE版からの削除:
#   - ファイアウォールルール (IAP SSH, LB→Web, deny-all) → Cloud Run は不要
#   - Cloud Router + Cloud NAT → Cloud Run は不要
# =============================================================================
