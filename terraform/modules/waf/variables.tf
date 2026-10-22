variable "name" {
  type        = string
  description = "Web ACL name."
}

variable "rate_limit_per_5m" {
  type        = number
  description = "Requests per 5 minutes per IP before blocking."
  default     = 2000
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key for the log group."
}
