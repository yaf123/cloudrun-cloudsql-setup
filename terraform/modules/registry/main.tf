# =============================================================================
# Artifact Registry（Docker イメージ管理）
# =============================================================================
resource "google_artifact_registry_repository" "docker" {
  location      = var.region
  repository_id = "${var.prefix}-docker"
  format        = "DOCKER"
  description   = "Docker images for ${var.prefix}"
}
