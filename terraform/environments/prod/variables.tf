variable "project_id" {
  description = "GCPプロジェクトID"
  type        = string
}

variable "project_name" {
  description = "プロジェクト名（リソース名のプレフィックス）"
  type        = string
  default     = "rubese"
}

variable "env" {
  description = "環境名"
  type        = string
  default     = "dev"
}

variable "region" {
  description = "リージョン"
  type        = string
  default     = "asia-northeast1"
}

# --- DB ---
variable "db_name" {
  description = "データベース名"
  type        = string
}

variable "db_user" {
  description = "データベースユーザー名"
  type        = string
}

variable "db_password" {
  description = "DBパスワード"
  type        = string
  sensitive   = true
}

variable "db_tier" {
  description = "Cloud SQLマシンタイプ"
  type        = string
  default     = "db-f1-micro"
}

variable "ha_enabled" {
  description = "Cloud SQL高可用性"
  type        = bool
  default     = false
}

# --- Cloud Run ---
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

variable "image_tag" {
  description = "Dockerイメージタグ"
  type        = string
  default     = "latest"
}

# --- LB / Security ---
variable "domain" {
  description = "SSL証明書用ドメイン（空ならHTTPのみ）"
  type        = string
  default     = ""
}

variable "rate_limit_count" {
  description = "レート制限: リクエスト数/分"
  type        = number
  default     = 100
}

# --- CI/CD ---
variable "github_owner" {
  description = "GitHubオーナー（空ならトリガー未作成）"
  type        = string
  default     = ""
}

variable "github_repo_name" {
  description = "GitHubリポジトリ名（空ならトリガー未作成）"
  type        = string
  default     = ""
}
