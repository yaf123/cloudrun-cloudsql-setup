output "policy_id" {
  description = "Cloud ArmorポリシーのID"
  value       = google_compute_security_policy.web.id
}
