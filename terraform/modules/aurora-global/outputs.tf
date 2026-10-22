output "primary_endpoint" {
  value       = aws_rds_cluster.primary.endpoint
  description = "Writer endpoint (primary region)."
}

output "secondary_reader_endpoint" {
  value       = aws_rds_cluster.secondary.reader_endpoint
  description = "Reader endpoint (DR region)."
}

output "global_cluster_id" {
  value       = aws_rds_global_cluster.this.id
  description = "Used by the failover runbook."
}

output "master_secret_arn" {
  value       = aws_rds_cluster.primary.master_user_secret[0].secret_arn
  description = "Secrets Manager ARN of the master password (consumed by External Secrets)."
}
