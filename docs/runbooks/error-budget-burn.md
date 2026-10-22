# Error budget fast burn

**Alert:** `OrderflowErrorBudgetFastBurn`: 1h and 5m 5xx ratio > 1.44%.

## Diagnose
1. Which service? `sum by (service, route, code) (rate(orderflow_http_requests_total{code=~"5.."}[5m]))`
2. Did something change? Argo CD sync history, `kubectl argo rollouts -n orderflow list rollouts`, recent Karpenter disruptions (`kubectl get events -A --field-selector reason=Disrupting`).
3. Dependency? `orderflow_circuit_breaker_state` (2 = open) → [payments PSP](#psp); DB connection errors in logs → Aurora; `orderflow_outbox_publish_errors_total` → [nats-outage](nats-outage.md).

## Mitigate
- Bad release: `kubectl argo rollouts -n orderflow abort <svc>` then revert the promotion PR (git is the source of truth; Argo will otherwise re-sync it).
- <a id="psp"></a>PSP failing: the breaker sheds load on purpose. Orders keep being accepted and payment retries happen from the saga. Open a ticket with the PSP. Don't restart pods, it resets the breaker and amplifies the outage.
- Capacity: check HPA/KEDA at max (`kubectl -n orderflow get hpa`); raise `maxReplicas` via PR.
