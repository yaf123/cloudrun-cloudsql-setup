variable "project_id" {
  description = "GCPプロジェクトID"
  type        = string
}

variable "region" {
  description = "GCSバケットのリージョン"
  type        = string
  default     = "asia-northeast1"
}

variable "bucket_name" {
  description = "tfstate保存用GCSバケット名（グローバルで一意）"
  type        = string
}
