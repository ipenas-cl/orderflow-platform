# One region of the platform: VPC across 3 AZs, EKS (private endpoint,
# encrypted secrets, control-plane logs), Karpenter for node autoscaling and
# IRSA roles with least privilege for platform controllers.
data "aws_region" "this" {}

data "aws_caller_identity" "this" {}

locals {
  azs  = var.azs
  tags = merge(var.tags, { Environment = var.environment, ManagedBy = "terraform", Project = "orderflow" })
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name             = var.name
  cidr             = var.vpc_cidr
  azs              = local.azs
  private_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets   = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 48 + i)]
  database_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, 64 + i)]

  enable_nat_gateway     = true
  single_nat_gateway     = var.environment != "prod"
  one_nat_gateway_per_az = var.environment == "prod"

  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true
  flow_log_max_aggregation_interval    = 60

  create_database_subnet_group   = true
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1, "karpenter.sh/discovery" = var.name }
  tags                = local.tags
}

resource "aws_kms_key" "eks" {
  description             = "${var.name} EKS secrets envelope encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
  tags                    = local.tags
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

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name                    = var.name
  cluster_version                 = var.kubernetes_version
  vpc_id                          = module.vpc.vpc_id
  subnet_ids                      = module.vpc.private_subnets
  cluster_endpoint_public_access  = false
  cluster_endpoint_private_access = true
  enable_irsa                     = true
  cluster_enabled_log_types       = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  create_kms_key                  = false
  cluster_encryption_config       = { resources = ["secrets"], provider_key_arn = aws_kms_key.eks.arn }

  authentication_mode = "API"
  access_entries = {
    for i, arn in var.admin_role_arns : "admin-${i}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  cluster_addons = {
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni                = { most_recent = true, before_compute = true, configuration_values = jsonencode({ enableNetworkPolicy = "true" }) }
    eks-pod-identity-agent = { most_recent = true }
    aws-ebs-csi-driver     = { most_recent = true }
  }

  # Small, fixed node group for Karpenter itself and critical add-ons.
  # Application capacity is provisioned by Karpenter NodePools (gitops/platform/karpenter).
  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = var.system_node_instance_types
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      labels         = { "node-role/system" = "true" }
      taints         = { critical = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" } }
      metadata_options = {
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }

  node_security_group_tags = { "karpenter.sh/discovery" = var.name }
  tags                     = local.tags
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.24"

  cluster_name                    = module.eks.cluster_name
  enable_v1_permissions           = true
  enable_pod_identity             = true
  create_pod_identity_association = true
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
  tags = local.tags
}
