# Database failover

**Signal:** readiness failing across services, connection errors, Aurora `failover` event.

1. Aurora in-region failover takes ~30 s; services' readiness pings Postgres, so they leave the Service endpoints and come back by themselves. No restarts needed (pgx pools reconnect).
2. If services stay unready > 2 min after Aurora reports available: check the writer endpoint DNS (`dig <cluster>.cluster-xxx.rds.amazonaws.com`) and security groups; then restart one pod to rule out stale pools.
3. Regional writer loss → [region-failover](region-failover.md).
4. Data check after any failover: count orders in non-terminal states older than 10 min; investigate if > 0.
