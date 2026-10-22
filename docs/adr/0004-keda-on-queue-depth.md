# 0004. Scale consumers on queue depth (KEDA), edges on CPU (HPA)

Status: accepted · 2026-10

## Context
`payments`, `inventory` and `fulfillment` are mostly NATS consumers. CPU is a lagging signal for them: the queue grows long before CPU rises (they wait on the PSP and the DB).

## Decision
KEDA `nats-jetstream` scaler on each durable consumer's lag (threshold 20 pending messages per replica), plus a CPU trigger. `orders` and `admin` are request-driven: HPA on CPU. Both target the Rollout's scale subresource. Karpenter adds nodes when pods don't fit.

## Consequences
- After an outage the backlog drains faster (scale-out on lag), which is exactly when it matters.
- Scaling is bounded by `maxReplicaCount` and by the database. Raising the max is a PR, deliberately.
