variable "prefix" {
  description = "リソース名のプレフィックス"
  type        = string
}

variable "project_id" {
  description = "GCPプロジェクトID"
  type        = string
}

variable "region" {
  description = "リージョン"
  type        = string
}

variable "vpc_id" {
  description = "VPCのID"
  type        = string
}

variable "subnet_id" {
  description = "サブネットのID"
  type        = string
}

variable "repo" {
  description = "Artifact Registryリポジトリ名"
  type        = string
}

variable "image_tag" {
  description = "Dockerイメージタグ"
  type        = string
  default     = "latest"
}

variable "min_instances" {
  description = "Cloud Run 最小インスタンス数"
  type        = number
  default     = 0
}

variable "max_instances" {
  description = "Cloud Run 最大インスタンス数"
  type        = number
  default     = 5
}

variable "nginx_cpu" {
  description = "Nginx CPU"
  type        = string
  default     = "0.5"
}

variable "nginx_memory" {
  description = "Nginx メモリ"
  type        = string
  default     = "256Mi"
}

variable "php_cpu" {
  description = "PHP-FPM CPU"
  type        = string
  default     = "0.5"
}

variable "php_memory" {
  description = "PHP-FPM メモリ"
  type        = string
  default     = "256Mi"
}

variable "env" {
  description = "環境名 (dev/prod)"
  type        = string
}

variable "db_private_ip" {
  description = "Cloud SQL Private IP"
  type        = string
}

variable "db_name" {
  description = "データベース名"
  type        = string
}

variable "db_user" {
  description = "データベースユーザー名"
  type        = string
}

variable "db_secret_id" {
  description = "Secret ManagerのシークレットID（DBパスワード）"
  type        = string
}
