variable "zone_id" {
  type        = string
  description = "Route 53 hosted zone id."
  default     = "Z0000000EXAMPLE"
}
variable "domain" {
  type        = string
  description = "Base domain."
  default     = "orderflow.example.com"
}
# ALBs are created by the AWS Load Balancer Controller from the Ingress; their
# DNS names are fed back here (or looked up with data "aws_lb" by tag).
variable "primary_alb_dns" {
  type        = string
  description = "Primary ALB DNS name."
  default     = "primary-alb.us-east-1.elb.amazonaws.com"
}
variable "primary_alb_zone_id" {
  type        = string
  description = "Primary ALB hosted zone id."
  default     = "Z35SXDOTRQ7X7K"
}
variable "secondary_alb_dns" {
  type        = string
  description = "Secondary ALB DNS name."
  default     = "secondary-alb.us-west-2.elb.amazonaws.com"
}
variable "secondary_alb_zone_id" {
  type        = string
  description = "Secondary ALB hosted zone id."
  default     = "Z1H1FL5HABSF5"
}
