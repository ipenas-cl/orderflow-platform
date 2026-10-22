# 0003. Canary releases gated by SLO analysis

Status: accepted · 2026-10

## Context
Tests and staging don't catch configuration regressions, a wrong endpoint or a bad secret. Production traffic does.

## Decision
Argo Rollouts canaries for every service. A background AnalysisRun queries Prometheus for the **canary's own pods** (by `rollouts-pod-template-hash`): 5xx ratio < 1% and p99 < 300 ms. Failing → automatic abort. Prod steps are 10% → 25% → 50% → 100% over 25 minutes; kind uses 50% for speed.

## Consequences
- Without a service mesh, weights are approximated by replica ratio. This is good enough at our replica counts; a mesh or ALB weighted target groups would make them exact (revisit with Gateway API).
- Low-traffic services can pass analysis on no data (`isNaN` counts as pass). Accepted for internal services; edges always have traffic.
- `make prove` deploys a bad release on purpose and checks that it gets aborted, so the gate itself is tested.
