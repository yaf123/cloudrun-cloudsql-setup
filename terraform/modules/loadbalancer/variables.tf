variable "prefix" {
  description = "リソース名のプレフィックス"
  type        = string
}

variable "region" {
  description = "リージョン"
  type        = string
}

variable "cloud_run_service_name" {
  description = "Cloud Runサービス名"
  type        = string
}

variable "security_policy_id" {
  description = "Cloud ArmorポリシーのID"
  type        = string
  default     = null
}

variable "domain" {
  description = "SSL証明書用ドメイン（空ならHTTPのみ）"
  type        = string
  default     = ""
}
