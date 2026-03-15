variable "prefix" {
  description = "リソース名のプレフィックス"
  type        = string
}

variable "rate_limit_count" {
  description = "レート制限: リクエスト数"
  type        = number
  default     = 100
}

variable "rate_limit_interval" {
  description = "レート制限: 間隔(秒)"
  type        = number
  default     = 60
}
