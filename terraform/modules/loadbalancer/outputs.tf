output "lb_ip_address" {
  description = "ロードバランサーの外部IPアドレス"
  value       = google_compute_global_address.lb_ip.address
}
