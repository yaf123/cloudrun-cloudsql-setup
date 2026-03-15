output "trigger_id" {
  description = "Cloud BuildトリガーID"
  value       = var.github_repo_name != "" ? google_cloudbuild_trigger.deploy[0].id : null
}
