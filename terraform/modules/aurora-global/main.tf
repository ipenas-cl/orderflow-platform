# Aurora PostgreSQL Global Database: a writer cluster in the primary region and
# a read-only secondary cluster in the DR region (storage-level replication,
# typical lag < 1 s). Failover = promote the secondary (managed switchover or
# detach-and-promote); see docs/dr-plan.md.
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.70"
      configuration_aliases = [aws.primary, aws.secondary]
    }
  }
}

resource "aws_kms_key" "primary" {
  provider                = aws.primary
  description             = "${var.name} aurora (primary)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = var.tags
}

resource "aws_kms_key" "secondary" {
  provider                = aws.secondary
  description             = "${var.name} aurora (secondary)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = var.tags
}

data "aws_caller_identity" "this" {
  provider = aws.primary
}

data "aws_iam_policy_document" "kms" {
  #checkov:skip=CKV_AWS_109:Key policy grants the account root; "*" means this key
  #checkov:skip=CKV_AWS_111:Key policy grants the account root; "*" means this key
  #checkov:skip=CKV_AWS_356:Key policies use "*" to mean "this key"
  statement {
    sid       = "AccountAdmin"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.this.account_id}:root"]
    }
  }
}

resource "aws_rds_global_cluster" "this" {
  provider                  = aws.primary
  global_cluster_identifier = var.name
  engine                    = "aurora-postgresql"
  engine_version            = var.engine_version
  database_name             = "orderflow"
  storage_encrypted         = true
  deletion_protection       = true
}

resource "aws_security_group" "primary" {
  provider    = aws.primary
  name        = "${var.name}-aurora"
  description = "Aurora access from EKS private subnets"
  vpc_id      = var.primary.vpc_id
  ingress {
    description = "Postgres from private subnets"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.primary.client_cidrs
  }
  tags = var.tags
}

resource "aws_security_group" "secondary" {
  provider    = aws.secondary
  name        = "${var.name}-aurora"
  description = "Aurora access from EKS private subnets"
  vpc_id      = var.secondary.vpc_id
  ingress {
    description = "Postgres from private subnets"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.secondary.client_cidrs
  }
  tags = var.tags
}

resource "aws_rds_cluster_parameter_group" "primary" {
  provider = aws.primary
  name     = "${var.name}-pg16"
  family   = "aurora-postgresql16"
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }
  parameter {
    name  = "log_statement"
    value = "ddl"
  }
  tags = var.tags
}

resource "aws_rds_cluster_parameter_group" "secondary" {
  provider = aws.secondary
  name     = "${var.name}-pg16"
  family   = "aurora-postgresql16"
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }
  parameter {
    name  = "log_statement"
    value = "ddl"
  }
  tags = var.tags
}

resource "aws_rds_cluster" "primary" {
  provider                            = aws.primary
  cluster_identifier                  = "${var.name}-primary"
  global_cluster_identifier           = aws_rds_global_cluster.this.id
  engine                              = aws_rds_global_cluster.this.engine
  engine_version                      = aws_rds_global_cluster.this.engine_version
  database_name                       = "orderflow"
  master_username                     = "orderflow_admin"
  manage_master_user_password         = true
  db_subnet_group_name                = var.primary.subnet_group
  vpc_security_group_ids              = [aws_security_group.primary.id]
  db_cluster_parameter_group_name     = aws_rds_cluster_parameter_group.primary.name
  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.primary.arn
  backup_retention_period             = 14
  preferred_backup_window             = "03:00-04:00"
  copy_tags_to_snapshot               = true
  deletion_protection                 = true
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]
  skip_final_snapshot                 = false
  final_snapshot_identifier           = "${var.name}-primary-final"
  tags                                = var.tags
}

resource "aws_rds_cluster_instance" "primary" {
  #checkov:skip=CKV_AWS_354:Performance Insights uses the default AWS-managed key; CMK optional
  count                                 = 2
  provider                              = aws.primary
  identifier                            = "${var.name}-primary-${count.index}"
  cluster_identifier                    = aws_rds_cluster.primary.id
  engine                                = aws_rds_cluster.primary.engine
  engine_version                        = aws_rds_cluster.primary.engine_version
  instance_class                        = var.instance_class
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 30
  monitoring_role_arn                   = aws_iam_role.monitoring_primary.arn
  auto_minor_version_upgrade            = true
  publicly_accessible                   = false
  tags                                  = var.tags
}

resource "aws_rds_cluster" "secondary" {
  provider                            = aws.secondary
  cluster_identifier                  = "${var.name}-secondary"
  global_cluster_identifier           = aws_rds_global_cluster.this.id
  engine                              = aws_rds_global_cluster.this.engine
  engine_version                      = aws_rds_global_cluster.this.engine_version
  db_subnet_group_name                = var.secondary.subnet_group
  vpc_security_group_ids              = [aws_security_group.secondary.id]
  db_cluster_parameter_group_name     = aws_rds_cluster_parameter_group.secondary.name
  storage_encrypted                   = true
  kms_key_id                          = aws_kms_key.secondary.arn
  backup_retention_period             = 14
  copy_tags_to_snapshot               = true
  deletion_protection                 = true
  iam_database_authentication_enabled = true
  enabled_cloudwatch_logs_exports     = ["postgresql"]
  skip_final_snapshot                 = false
  final_snapshot_identifier           = "${var.name}-secondary-final"
  tags                                = var.tags

  lifecycle {
    # Replication source is managed by the global cluster.
    ignore_changes = [replication_source_identifier, global_cluster_identifier]
  }
  depends_on = [aws_rds_cluster_instance.primary]
}

resource "aws_rds_cluster_instance" "secondary" {
  #checkov:skip=CKV_AWS_354:Performance Insights uses the default AWS-managed key; CMK optional
  count                                 = 1
  provider                              = aws.secondary
  identifier                            = "${var.name}-secondary-${count.index}"
  cluster_identifier                    = aws_rds_cluster.secondary.id
  engine                                = aws_rds_cluster.secondary.engine
  engine_version                        = aws_rds_cluster.secondary.engine_version
  instance_class                        = var.instance_class
  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 30
  monitoring_role_arn                   = aws_iam_role.monitoring_secondary.arn
  auto_minor_version_upgrade            = true
  publicly_accessible                   = false
  tags                                  = var.tags
}

data "aws_iam_policy_document" "monitoring_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "monitoring_primary" {
  provider           = aws.primary
  name               = "${var.name}-rds-monitoring-primary"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "monitoring_primary" {
  provider   = aws.primary
  role       = aws_iam_role.monitoring_primary.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "aws_iam_role" "monitoring_secondary" {
  provider           = aws.secondary
  name               = "${var.name}-rds-monitoring-secondary"
  assume_role_policy = data.aws_iam_policy_document.monitoring_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "monitoring_secondary" {
  provider   = aws.secondary
  role       = aws_iam_role.monitoring_secondary.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# AWS Backup on top of Aurora's continuous backups: daily snapshots kept 35
# days, copied to the DR region vault (protects against logical corruption,
# which the Global Database would replicate).
resource "aws_backup_vault" "primary" {
  provider    = aws.primary
  name        = "${var.name}-primary"
  kms_key_arn = aws_kms_key.primary.arn
  tags        = var.tags
}

resource "aws_backup_vault" "secondary" {
  provider    = aws.secondary
  name        = "${var.name}-dr"
  kms_key_arn = aws_kms_key.secondary.arn
  tags        = var.tags
}

resource "aws_backup_plan" "aurora" {
  provider = aws.primary
  name     = "${var.name}-aurora"
  rule {
    rule_name         = "daily"
    target_vault_name = aws_backup_vault.primary.name
    schedule          = "cron(0 5 * * ? *)"
    lifecycle {
      delete_after = 35
    }
    copy_action {
      destination_vault_arn = aws_backup_vault.secondary.arn
      lifecycle {
        delete_after = 35
      }
    }
  }
  tags = var.tags
}

data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  provider           = aws.primary
  name               = "${var.name}-backup"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  provider   = aws.primary
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_selection" "aurora" {
  provider     = aws.primary
  name         = "${var.name}-aurora"
  plan_id      = aws_backup_plan.aurora.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = [aws_rds_cluster.primary.arn, aws_rds_cluster.secondary.arn]
}
