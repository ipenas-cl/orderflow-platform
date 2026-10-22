# Service level objectives

SLOs are about what the customer experiences, so they are measured at the
edge (`orders` accepts an order, `payments` answers a charge). Probes and
`/metrics` are excluded from every ratio.

| SLI | Measurement | SLO (30-day window) | Error budget |
|---|---|---|---|
| Availability | `orderflow_http_requests_total`: non-5xx / all | **99.9%** | 43 min of full outage, or 0.1% of requests |
| Latency (accept an order) | `orderflow_http_request_duration_seconds`, `POST /v1/orders` p99 | **p99 < 300 ms** in 99% of 1-minute windows | 7.2 h of slow windows |
| Saga completion | `orderflow_saga_transitions_total`: orders that reach a terminal state (DELIVERED, CANCELLED, REFUNDED) | **99%** within 5 min | 1% stuck orders |

A `CANCELLED` order is not an error. It is the saga working: stock was
released or the payment refunded. A *stuck* order (no terminal state) is the
error.

## Alerting: multi-window burn rate

From the Google SRE workbook; rules are in `gitops/platform/monitoring/slo-rules.yaml`.

| Alert | Condition | Meaning | Action |
|---|---|---|---|
| `OrderflowErrorBudgetFastBurn` (page) | 1h **and** 5m error ratio > 14.4 × 0.1% | 2% of the monthly budget gone in 1 h | [runbook](runbooks/error-budget-burn.md) |
| `OrderflowLatencySLO` (page) | orders p99 > 300 ms for 10 min | customer-visible slowness | [runbook](runbooks/latency.md) |
| `SagaCompensationSpike` (ticket) | cancelled / created > 20% for 10 min | a dependency is declining or failing | [runbook](runbooks/saga-compensations.md) |
| `AuroraReplicationLagHigh` (page) | global DB lag > 1 s for 5 min | RPO at risk | [runbook](runbooks/region-failover.md) |

## Release gating

Every canary is judged by `gitops/orderflow/base/analysis-template.yaml`
against **its own pods only** (label `rollouts_pod_template_hash`):

- 5xx ratio < 1% (one failed measurement aborts)
- p99 < 300 ms (two failed measurements abort)

A canary can afford a short burst above the long-run budget rate. It cannot
afford anything that looks like an outage. If it aborts, Argo Rollouts scales
the canary to zero and keeps the stable ReplicaSet, with no human involved.

## Error budget policy

- Budget remaining > 50%: normal release cadence.
- 0–50%: releases need a second reviewer and happen in business hours.
- Exhausted: feature freeze for the service; only reliability work and fixes ship until the 30-day window recovers.
