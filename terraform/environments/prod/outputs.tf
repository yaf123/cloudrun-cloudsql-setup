output "lb_ip_address" {
  description = "ロードバランサーの外部IPアドレス"
  value       = module.loadbalancer.lb_ip_address
}

output "cloud_run_uri" {
  description = "Cloud RunサービスURI"
  value       = module.application.service_uri
}

output "cloudsql_private_ip" {
  description = "Cloud SQLのPrivate IPアドレス"
  value       = module.database.private_ip
}

output "artifact_registry_url" {
  description = "Artifact RegistryのURL"
  value       = module.registry.repository_url
}

output "docker_push_commands" {
  description = "Dockerイメージのpushコマンド"
  value       = <<-EOT
    docker tag nginx ${module.registry.repository_url}/nginx:latest
    docker tag php-fpm ${module.registry.repository_url}/php-fpm:latest
    docker push ${module.registry.repository_url}/nginx:latest
    docker push ${module.registry.repository_url}/php-fpm:latest
  EOT
}
