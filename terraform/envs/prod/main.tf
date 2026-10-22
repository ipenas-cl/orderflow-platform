# Production: active/passive across us-east-1 (primary) and us-west-2 (DR).
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
  backend "s3" {
    bucket         = "orderflow-tfstate-example"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "orderflow-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  alias  = "primary"
  region = "us-east-1"
  default_tags {
    tags = local.tags
  }
}

provider "aws" {
  alias  = "secondary"
  region = "us-west-2"
  default_tags {
    tags = local.tags
  }
}

locals {
  tags = { Project = "orderflow", Environment = "prod", Owner = "platform", CostCenter = "commerce" }
}

module "primary" {
  source      = "../../modules/region"
  providers   = { aws = aws.primary }
  name        = "orderflow-prod-use1"
  azs         = ["us-east-1a", "us-east-1b", "us-east-1c"]
  environment = "prod"
  vpc_cidr    = "10.10.0.0/16"
  tags        = local.tags
}

module "secondary" {
  source      = "../../modules/region"
  providers   = { aws = aws.secondary }
  name        = "orderflow-prod-usw2"
  azs         = ["us-west-2a", "us-west-2b", "us-west-2c"]
  environment = "prod"
  vpc_cidr    = "10.20.0.0/16"
  tags        = local.tags
}

module "aurora" {
  source    = "../../modules/aurora-global"
  providers = { aws.primary = aws.primary, aws.secondary = aws.secondary }
  name      = "orderflow-prod"
  primary = {
    subnet_group = module.primary.database_subnet_group
    vpc_id       = module.primary.vpc_id
    client_cidrs = module.primary.private_subnets_cidr
  }
  secondary = {
    subnet_group = module.secondary.database_subnet_group
    vpc_id       = module.secondary.vpc_id
    client_cidrs = module.secondary.private_subnets_cidr
  }
  tags = local.tags
}

resource "aws_kms_key" "logs" {
  provider                = aws.primary
  description             = "orderflow prod log encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.logs_kms.json
}

data "aws_caller_identity" "me" {
  provider = aws.primary
}

data "aws_iam_policy_document" "logs_kms" {
  #checkov:skip=CKV_AWS_109:Key policy grants the account root and CloudWatch Logs; "*" means this key
  #checkov:skip=CKV_AWS_111:Key policy grants the account root and CloudWatch Logs; "*" means this key
  #checkov:skip=CKV_AWS_356:Key policies use "*" to mean "this key"
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.me.account_id}:root"]
    }
  }
  statement {
    sid       = "CloudWatchLogs"
    actions   = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.us-east-1.amazonaws.com"]
    }
  }
}

module "waf" {
  source      = "../../modules/waf"
  providers   = { aws = aws.primary }
  name        = "orderflow-prod-use1"
  kms_key_arn = aws_kms_key.logs.arn
}

resource "aws_sns_topic" "alerts" {
  provider          = aws.primary
  name              = "orderflow-prod-alerts"
  kms_master_key_id = aws_kms_key.logs.arn
}

# Application secrets live in Secrets Manager (replicated to the DR region)
# and are synced into Kubernetes by External Secrets via IRSA.
resource "aws_secretsmanager_secret" "payments_stripe" {
  #checkov:skip=CKV2_AWS_57:Stripe keys are rotated in the Stripe dashboard (runbook), not by Lambda
  provider    = aws.primary
  name        = "orderflow/prod/payments-stripe"
  description = "STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET"
  kms_key_id  = aws_kms_key.logs.arn
  replica {
    region = "us-west-2"
  }
}

module "dns" {
  source          = "../../modules/dns-failover"
  providers       = { aws = aws.primary }
  zone_id         = var.zone_id
  record_name     = "api.${var.domain}"
  primary         = { alb_dns = var.primary_alb_dns, alb_zone_id = var.primary_alb_zone_id, region = "us-east-1" }
  secondary       = { alb_dns = var.secondary_alb_dns, alb_zone_id = var.secondary_alb_zone_id, region = "us-west-2" }
  alarm_topic_arn = aws_sns_topic.alerts.arn
}
