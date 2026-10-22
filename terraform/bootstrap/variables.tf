variable "region" {
  type        = string
  description = "Region for the state bucket."
  default     = "us-east-1"
}

variable "state_bucket" {
  type        = string
  description = "Globally unique state bucket name."
  default     = "orderflow-tfstate-example"
}
