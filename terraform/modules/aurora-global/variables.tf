variable "name" {
  type        = string
  description = "Global cluster identifier prefix."
}

variable "engine_version" {
  type        = string
  description = "Aurora PostgreSQL version."
  default     = "16.4"
}

variable "instance_class" {
  type        = string
  description = "Instance class for writer/readers."
  default     = "db.r7g.large"
}

variable "primary" {
  type = object({
    subnet_group = string
    vpc_id       = string
    client_cidrs = list(string)
  })
  description = "Primary region networking."
}

variable "secondary" {
  type = object({
    subnet_group = string
    vpc_id       = string
    client_cidrs = list(string)
  })
  description = "Secondary region networking."
}

variable "tags" {
  type        = map(string)
  description = "Tags."
  default     = {}
}
