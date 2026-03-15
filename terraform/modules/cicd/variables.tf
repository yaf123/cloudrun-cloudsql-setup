variable "prefix" {
  description = "リソース名のプレフィックス"
  type        = string
}

variable "project_id" {
  description = "GCPプロジェクトID"
  type        = string
}

variable "project_name" {
  description = "プロジェクト名"
  type        = string
}

variable "region" {
  description = "リージョン"
  type        = string
}

variable "env" {
  description = "環境名 (dev/prod)"
  type        = string
}

variable "github_owner" {
  description = "GitHubオーナー（ユーザー名 or Organization名）"
  type        = string
  default     = ""
}

variable "github_repo_name" {
  description = "GitHubリポジトリ名（空ならトリガー未作成）"
  type        = string
  default     = ""
}

variable "trigger_branch" {
  description = "トリガー対象ブランチ"
  type        = string
  default     = "^main$"
}
