variable "name" {
  type        = string
  description = "Prefix, e.g. orderflow-prod-use1."
}
variable "environment" {
  type        = string
  description = "dev | staging | prod"
}
variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR; must not overlap between regions (peering/TGW)."
}
variable "kubernetes_version" {
  type        = string
  description = "EKS version."
  default     = "1.31"
}
variable "system_node_instance_types" {
  type        = list(string)
  description = "Instance types for the small managed node group running Karpenter and add-ons."
  default     = ["m7g.large"]
}
variable "admin_role_arns" {
  type        = list(string)
  description = "IAM roles granted cluster-admin through EKS access entries."
  default     = []
}
variable "tags" {
  type        = map(string)
  description = "Common tags."
  default     = {}
}
variable "azs" {
  type        = list(string)
  description = "Exactly three AZs, pinned explicitly (no silent expansion when AWS adds zones)."
}
