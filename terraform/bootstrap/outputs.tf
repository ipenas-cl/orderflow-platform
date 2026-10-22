output "state_bucket" {
  value       = aws_s3_bucket.state.id
  description = "Use in backend \"s3\" blocks."
}
