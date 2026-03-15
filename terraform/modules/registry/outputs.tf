output "repository_id" {
  description = "Artifact Registryリポジトリ名"
  value       = google_artifact_registry_repository.docker.repository_id
}

output "repository_url" {
  description = "Dockerイメージのベース URL"
  value       = "${var.region}-docker.pkg.dev/${google_artifact_registry_repository.docker.project}/${google_artifact_registry_repository.docker.repository_id}"
}
