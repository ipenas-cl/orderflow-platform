# Latency SLO (orders p99 > 300 ms)

**Alert:** `OrderflowLatencySLO`.

1. Saturation? CPU throttling: `rate(container_cpu_cfs_throttled_periods_total{namespace="orderflow"}[5m])`. Replicas at max? Pending pods (`kubectl get pods -A --field-selector status.phase=Pending`) → Karpenter limits / instance availability.
2. Database? Aurora `DBLoad`, slow-query log (`log_min_duration_statement=500`) in CloudWatch Logs.
3. Noisy neighbour? Node pressure events; move to a dedicated NodePool via PR.
4. Mitigate: scale out via PR (raise `minReplicas`), or roll back the last release.
