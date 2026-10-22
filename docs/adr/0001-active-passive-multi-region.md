# 0001. Active/passive multi-region, not active/active

Status: accepted · 2026-10

## Context
Orders and payments need strong consistency: an order must not be paid twice or shipped from stock that doesn't exist. Active/active across regions means multi-writer databases (conflict resolution) or a global consensus store (latency on every write).

## Decision
One writer region (us-east-1) and a warm standby (us-west-2): Aurora Global Database, EKS in both regions reconciled from the same git, Route 53 failover routing.

## Consequences
- RPO is the Global DB lag (seconds), not zero, for an unplanned region loss. Planned switchover is RPO 0.
- DR costs ~40% of primary (warm nodes, one Aurora reader), not 100%.
- Failover is a decision plus a runbook, not automatic: automatic regional failover on a flaky health check is a bigger risk than 10 minutes of human decision.
- Revisit if the RTO target drops below ~5 minutes or the read latency outside the US becomes a product problem.
