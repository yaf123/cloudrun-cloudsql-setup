output "instance_name" {
  description = "Cloud SQLインスタンス名"
  value       = google_sql_database_instance.main.name
}

output "connection_name" {
  description = "Cloud SQL接続名（Auth Proxy用）"
  value       = google_sql_database_instance.main.connection_name
}

output "private_ip" {
  description = "Cloud SQLのPrivate IP"
  value       = google_sql_database_instance.main.private_ip_address
}

output "secret_id" {
  description = "Secret ManagerのシークレットID"
  value       = google_secret_manager_secret.db_password.secret_id
}
