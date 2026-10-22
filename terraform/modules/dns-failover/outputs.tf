output "primary_health_check_id" {
  value       = aws_route53_health_check.primary.id
  description = "Health check id."
}
