variable "zone_id" {
  type        = string
  description = "Hosted zone id."
}

variable "record_name" {
  type        = string
  description = "e.g. api.orderflow.example.com"
}

variable "primary" {
  type        = object({ alb_dns = string, alb_zone_id = string, region = string })
  description = "Primary region ALB."
}

variable "secondary" {
  type        = object({ alb_dns = string, alb_zone_id = string, region = string })
  description = "Secondary region ALB."
}

variable "health_path" {
  type        = string
  description = "Path checked by Route 53."
  default     = "/readyz"
}

variable "alarm_topic_arn" {
  type        = string
  description = "SNS topic for failover alarms."
}
