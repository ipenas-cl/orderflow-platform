# 0007. Terraform layout: one root per environment, regional module, remote state

Status: accepted · 2026-10

## Context
The blast radius of a `terraform apply` should be one environment, and the DR region must be identical to the primary by construction.

## Decision
`terraform/modules/region` (VPC, EKS, Karpenter, IRSA) is instantiated twice in `envs/prod` with different providers; Aurora Global, WAF and DNS failover are separate modules. State lives in S3 (versioned, KMS, access-logged) with DynamoDB locking, created once by `terraform/bootstrap`. CI runs `validate`, `tflint` and `checkov` on every PR; checkov exceptions are inline with a justification.

## Consequences
- prod is one state for both regions: simple to reason about, but a region outage can block `apply` against the dead region. The runbook works with `-target` on the DR module, and no Terraform is needed to fail over (Aurora/Route 53 are CLI actions).
