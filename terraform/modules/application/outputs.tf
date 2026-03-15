output "service_name" {
  description = "Cloud Runサービス名"
  value       = google_cloud_run_v2_service.app.name
}

output "service_uri" {
  description = "Cloud RunサービスURI"
  value       = google_cloud_run_v2_service.app.uri
}
