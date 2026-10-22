# Region failover (us-east-1 → us-west-2)

**Alerts:** Route 53 `orderflow-prod-primary-health` failing, `AuroraReplicationLagHigh`, AWS Health event for us-east-1.

**Impact:** customers can't place orders, or the platform is about to lose them.

## Diagnose (≤ 5 min)
1. Is it us? Argo CD → `orderflow` app history: was there a sync in the last 30 min? If yes → [canary-aborted](canary-aborted.md) / roll back first.
2. Is it the region? AWS Health Dashboard; `aws ec2 describe-availability-zones --region us-east-1`; probes from outside AWS.
3. Replication lag right now: CloudWatch `AuroraGlobalDBReplicationLag` (ms). This is your RPO if you fail over now.

## Mitigate
```bash
# 1. fence writers in the primary (skip if unreachable)
kubectl --context prod-use1 -n orderflow scale rollout orders payments --replicas=0
# 2. promote Aurora in us-west-2
aws rds failover-global-cluster --region us-west-2 \
  --global-cluster-identifier orderflow-prod \
  --target-db-cluster-identifier arn:aws:rds:us-west-2:<acct>:cluster:orderflow-prod-secondary
#    region fully down: add --allow-data-loss (RPO = lag above)
# 3. scale DR to prod capacity (pre-approved PR)
gh pr merge --squash <prod-dr-scale PR>   # gitops/orderflow/overlays/prod-dr
# 4. DNS fails over on its own (3 x 30 s). Force it by inverting the primary health check:
aws route53 update-health-check --health-check-id <primary-id> --inverted
```

## Verify
- SLO dashboard (us-west-2): error ratio < 0.1%, orders p99 < 300 ms.
- `orderflow_outbox_published_total` rising; outbox backlog → 0.
- Place a test order; follow it to DELIVERED.

## Failback
Business hours only. Rebuild us-east-1 as a Global DB secondary, wait for lag < 1 s, `switchover-global-cluster` (RPO 0), then flip DNS back.
