# Route 53 active/passive failover: the primary ALB is served while its health
# check (HTTPS /readyz through the ALB) passes; otherwise traffic shifts to the
# secondary region. TTL 30 s bounds client-side failover time.
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

resource "aws_route53_health_check" "primary" {
  fqdn              = var.primary.alb_dns
  port              = 443
  type              = "HTTPS"
  resource_path     = var.health_path
  request_interval  = 10
  failure_threshold = 3
  measure_latency   = true
  regions           = ["us-east-1", "us-west-2", "eu-west-1"]
  tags              = { Name = "${var.record_name}-primary" }
}

resource "aws_route53_health_check" "secondary" {
  fqdn              = var.secondary.alb_dns
  port              = 443
  type              = "HTTPS"
  resource_path     = var.health_path
  request_interval  = 30
  failure_threshold = 3
  regions           = ["us-east-1", "us-west-2", "eu-west-1"]
  tags              = { Name = "${var.record_name}-secondary" }
}

resource "aws_route53_record" "primary" {
  #checkov:skip=CKV2_AWS_23:Alias targets ALBs created by the AWS Load Balancer Controller (outside this state)
  zone_id         = var.zone_id
  name            = var.record_name
  type            = "A"
  set_identifier  = "primary-${var.primary.region}"
  health_check_id = aws_route53_health_check.primary.id
  failover_routing_policy {
    type = "PRIMARY"
  }
  alias {
    name                   = var.primary.alb_dns
    zone_id                = var.primary.alb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "secondary" {
  #checkov:skip=CKV2_AWS_23:Alias targets ALBs created by the AWS Load Balancer Controller (outside this state)
  zone_id         = var.zone_id
  name            = var.record_name
  type            = "A"
  set_identifier  = "secondary-${var.secondary.region}"
  health_check_id = aws_route53_health_check.secondary.id
  failover_routing_policy {
    type = "SECONDARY"
  }
  alias {
    name                   = var.secondary.alb_dns
    zone_id                = var.secondary.alb_zone_id
    evaluate_target_health = true
  }
}

# Health-check metrics live in us-east-1.
resource "aws_cloudwatch_metric_alarm" "primary_unhealthy" {
  alarm_name          = "${var.record_name}-primary-unhealthy"
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.primary.id }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  alarm_description   = "Primary region failing health checks: DNS failover in progress (docs/runbooks.md#regional-failover)"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}
