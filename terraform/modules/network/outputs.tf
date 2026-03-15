output "vpc_id" {
  description = "VPCのID"
  value       = google_compute_network.vpc.id
}

output "vpc_name" {
  description = "VPCの名前"
  value       = google_compute_network.vpc.name
}

output "subnet_id" {
  description = "サブネットのID"
  value       = google_compute_subnetwork.subnet.id
}

output "private_vpc_connection" {
  description = "Private Services Access接続（Cloud SQL依存用）"
  value       = google_service_networking_connection.private_vpc_connection
}
