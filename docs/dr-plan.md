# Disaster recovery plan

## Topology: active/passive across two regions

| | Primary: us-east-1 | DR: us-west-2 |
|---|---|---|
| EKS | serving traffic, Karpenter sized to load | warm: system nodes + 1 replica per service, Karpenter scales up on failover |
| Aurora PostgreSQL | Global Database **writer** cluster (2 instances, Multi-AZ) | Global Database **secondary** cluster (1 reader instance) |
| Secrets | Secrets Manager (source) | replica secret (same ARN suffix) |
| DNS | Route 53 failover record PRIMARY + health check | SECONDARY record |
| GitOps | Argo CD in each cluster reconciles the same `main` | same |
| Backups | Aurora PITR 14 days + AWS Backup daily, 35 days | AWS Backup copy (cross-region) |

## Objectives

| Scenario | RPO | RTO | Mechanism |
|---|---|---|---|
| Pod / node loss | 0 | < 1 min | ReplicaSets, PDBs, topology spread, Karpenter |
| AZ loss | 0 | < 5 min | 3 AZs, zone-spread pods, Aurora Multi-AZ writer failover (~30 s) |
| Aurora writer instance failure | 0 | < 1 min | Aurora in-region failover |
| **Region loss** | **< 5 s** (Global DB lag, typically < 1 s) | **< 15 min** | managed Global DB failover + Route 53 |
| Logical corruption (bad migration, bad delete) | ≤ 5 min (PITR) | < 2 h | Aurora PITR / AWS Backup restore to a new cluster |
| Region loss *and* cluster config lost | 0 for config | < 45 min | new EKS from Terraform + Argo CD app-of-apps from git |

RPO for region loss is bounded by Aurora Global Database replication lag,
alarmed at 1 s. NATS JetStream is *not* replicated across regions. That is
a deliberate choice: every event is first written to a Postgres outbox in the
same transaction as the state change, so the outbox relay in the DR region
re-publishes anything that was not acknowledged. Events are reconstructible
from the database. The database is the single source of truth.

## Region failover procedure

[runbooks/region-failover.md](runbooks/region-failover.md) is the step-by-step
version. Decision owner: incident commander. Target: decide within 5 min of
the primary region being declared impaired.

1. **Declare.** Route 53 health checks are red, AWS Health Dashboard or our own probes confirm a regional problem, and it is not just our deploy (check Argo CD history).
2. **Fence writes in the primary** if it is reachable: scale `orders` and `payments` to 0 in us-east-1, so no writer sends traffic to a database that is about to stop being the writer.
3. **Promote Aurora in us-west-2.**
   - Region healthy enough: `aws rds failover-global-cluster --global-cluster-identifier orderflow-prod --target-db-cluster-identifier <us-west-2 cluster ARN>` (managed, RPO 0).
   - Region down: `aws rds switchover-global-cluster` is not possible. Use `--allow-data-loss` failover (RPO = replication lag at failure time).
4. **Scale DR.** Merge the pre-approved PR `gitops/orderflow/overlays/prod-dr` (replica floor = prod) or let KEDA/HPA react; Karpenter provisions nodes in ~60 s.
5. **DNS.** Route 53 fails over automatically once the primary health check fails (3 × 30 s). To force it, set the primary health check to inverted.
6. **Verify.** SLO dashboards in the DR region: error ratio, p99, saga completion; outbox backlog draining.
7. **Communicate** every 30 min until resolved.

Failback is the same procedure in reverse, done during business hours, after
the old primary has been rebuilt as a secondary and has caught up (lag < 1 s).

## Testing

| What | How | Cadence |
|---|---|---|
| Pod kill, network latency, NATS outage, DB restart, bad release | `make prove` (kind) / `prove` workflow | weekly (CI schedule) and on every platform change |
| AZ failure | AWS FIS: `aws:network:disrupt-connectivity` on one AZ's subnets in staging | monthly |
| Aurora writer failover | `aws rds failover-db-cluster` in staging | monthly |
| Region failover | full game day in staging using the runbook, timed | quarterly |
| Restore from backup | restore the latest AWS Backup recovery point to a scratch cluster and run consistency checks | monthly |

What the kind proof can and cannot show: it shows the *application's*
behaviour when its dependencies fail (reconnects, outbox, idempotency, saga
compensation, canary aborts). It cannot show Aurora's or Route 53's failover
timing. Those are measured in staging with the procedures above.
