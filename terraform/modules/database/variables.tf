variable "prefix" {
  description = "リソース名のプレフィックス"
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

variable "private_vpc_connection" {
  description = "Private Services Access接続（依存関係用）"
  type        = any
}

variable "db_version" {
  description = "データベースバージョン"
  type        = string
  default     = "MYSQL_8_0"
}

variable "db_tier" {
  description = "マシンタイプ"
  type        = string
  default     = "db-f1-micro"
}

variable "db_name" {
  description = "データベース名"
  type        = string
}

variable "db_user" {
  description = "データベースユーザー名"
  type        = string
}

variable "db_password" {
  description = "データベースパスワード"
  type        = string
  sensitive   = true
}

variable "disk_size" {
  description = "ディスクサイズ(GB)"
  type        = number
  default     = 10
}

variable "ha_enabled" {
  description = "高可用性を有効にするか"
  type        = bool
  default     = true
}

variable "backup_start_time" {
  description = "バックアップ開始時刻（UTC）"
  type        = string
  default     = "18:00"
}

variable "backup_retention_days" {
  description = "バックアップ保持日数"
  type        = number
  default     = 7
}

variable "deletion_protection" {
  description = "削除保護"
  type        = bool
  default     = true
}
