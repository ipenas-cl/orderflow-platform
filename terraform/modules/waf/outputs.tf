output "web_acl_arn" {
  value       = aws_wafv2_web_acl.this.arn
  description = "Attach to the ALB via the ingress annotation alb.ingress.kubernetes.io/wafv2-acl-arn."
}
