output "bucket_name" {
  description = "作成されたGCSバケット名"
  value       = google_storage_bucket.tfstate.name
}

output "bucket_url" {
  description = "GCSバケットURL"
  value       = google_storage_bucket.tfstate.url
}
