# 0006. Secrets from Secrets Manager via External Secrets and IRSA

Status: accepted · 2026-10

## Context
No secrets in git, no long-lived cloud keys in clusters, and the DR region must have the same secrets without manual copying.

## Decision
Secrets Manager is the source of truth (DB credentials managed by Aurora; PSP keys by us), replicated to us-west-2 by Terraform. External Secrets Operator syncs them into Kubernetes using an IRSA role scoped to `orderflow/<env>/*`. Workloads needing AWS APIs (payments) get their own IRSA role. No node-role permissions.

## Consequences
- Rotation in Secrets Manager reaches pods within `refreshInterval` (1h); pods read env at start, so rotation needs a rollout. Acceptable for DB passwords (Aurora keeps both during rotation).
- The kind proof generates a random DB password at runtime instead; nothing secret is ever committed.
