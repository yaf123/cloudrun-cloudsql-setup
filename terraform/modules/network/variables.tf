variable "prefix" {
  description = "リソース名のプレフィックス"
  type        = string
}

variable "region" {
  description = "リージョン"
  type        = string
}

variable "subnet_cidr" {
  description = "サブネットのCIDR"
  type        = string
  default     = "10.0.0.0/24"
}

variable "private_services_cidr" {
  description = "Private Services Access用のCIDR（先頭アドレス）"
  type        = string
  default     = "10.1.0.0"
}

variable "flow_log_sampling" {
  description = "フローログのサンプリング率（0.0〜1.0）"
  type        = number
  default     = 0.5
}
