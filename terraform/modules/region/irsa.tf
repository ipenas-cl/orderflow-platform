# Least-privilege IAM for in-cluster controllers (IRSA). Each role can only be
# assumed by one service account and only reaches the resources it needs.

module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.46"

  role_name                             = "${var.name}-external-secrets"
  attach_external_secrets_policy        = true
  external_secrets_secrets_manager_arns = ["arn:aws:secretsmanager:${data.aws_region.this.name}:${data.aws_caller_identity.this.account_id}:secret:orderflow/${var.environment}/*"]
  external_secrets_kms_key_arns         = [aws_kms_key.eks.arn]
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
  tags = local.tags
}

module "lb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.46"

  role_name                              = "${var.name}-aws-lb-controller"
  attach_load_balancer_controller_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
  tags = local.tags
}

# Application service accounts: payments may read only its own secrets.
data "aws_iam_policy_document" "payments" {
  statement {
    sid       = "ReadOwnSecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:aws:secretsmanager:${data.aws_region.this.name}:${data.aws_caller_identity.this.account_id}:secret:orderflow/${var.environment}/payments-*"]
  }
}

resource "aws_iam_policy" "payments" {
  name   = "${var.name}-payments"
  policy = data.aws_iam_policy_document.payments.json
  tags   = local.tags
}

module "payments_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.46"

  role_name        = "${var.name}-payments"
  role_policy_arns = { payments = aws_iam_policy.payments.arn }
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["orderflow:payments"]
    }
  }
  tags = local.tags
}
