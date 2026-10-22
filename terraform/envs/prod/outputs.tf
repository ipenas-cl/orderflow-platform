output "aurora_writer" {
  value       = module.aurora.primary_endpoint
  description = "Writer endpoint."
}
output "clusters" {
  value       = [module.primary.cluster_name, module.secondary.cluster_name]
  description = "EKS clusters (Argo CD registers both)."
}
