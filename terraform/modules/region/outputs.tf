output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "VPC id."
}
output "database_subnet_group" {
  value       = module.vpc.database_subnet_group_name
  description = "DB subnet group for Aurora."
}
output "private_subnets_cidr" {
  value       = module.vpc.private_subnets_cidr_blocks
  description = "Private subnet CIDRs (allowed to reach Aurora)."
}
output "node_security_group_id" {
  value       = module.eks.node_security_group_id
  description = "EKS node SG."
}
output "cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name."
}
output "karpenter_queue" {
  value       = module.karpenter.queue_name
  description = "Interruption queue for Karpenter."
}
output "external_secrets_role_arn" {
  value       = module.external_secrets_irsa.iam_role_arn
  description = "IRSA role for External Secrets."
}
output "payments_role_arn" {
  value       = module.payments_irsa.iam_role_arn
  description = "IRSA role for payments."
}
