# orderflow-platform

[![iac](https://github.com/ipenas-cl/orderflow-platform/actions/workflows/iac.yml/badge.svg)](https://github.com/ipenas-cl/orderflow-platform/actions/workflows/iac.yml)

How [orderflow](https://github.com/ipenas-cl/orderflow) (five hexagonal Go
services, saga + outbox, NATS, Stripe, Auth0) runs in production, and the
evidence that it survives failure. Writing the services is the easy part; this
repo is the other part: infrastructure, delivery, scaling, SLOs, chaos and
what on-call does at 3 a.m.

| Layer | What is here |
|---|---|
| **Infrastructure (Terraform)** | Multi-region active/passive AWS: VPC per region, EKS + Karpenter, Aurora Global Database (Postgres), Route 53 health-checked failover, WAF, IRSA, remote state with locking. `terraform/` |
| **GitOps (Argo CD)** | App-of-apps per environment (kind, dev, staging, prod, prod-dr) with Kustomize overlays. `gitops/` |
| **Progressive delivery** | Argo Rollouts canary; Prometheus analysis on error ratio and p99 aborts a bad release automatically. |
| **Autoscaling** | HPA on CPU for the HTTP edge, KEDA on NATS queue depth for consumers, Karpenter for nodes. |
| **Policy as code** | Pod Security `restricted` + Kyverno (non-root, probes, limits, signed images in prod), checked in CI and at admission. |
| **Supply chain** | Build → SBOM (syft) → scan (Trivy) → sign (cosign keyless) → promote by GitOps PR. `.github/workflows/supply-chain.yml` |
| **SRE** | SLOs with multi-window burn-rate alerts, DR plan with RTO/RPO, runbooks, game-day guide, ADRs, cost estimate. `docs/` |
| **Proof** | `make prove`: a real kind cluster, real load, real chaos, a deliberately bad release, and a generated report. `proof/` |

## Architecture

```
                 Route 53 (health-checked failover)
                    │                         │
           ┌────────▼────────┐       ┌────────▼────────┐
           │  us-east-1      │       │  us-west-2 (DR) │
           │  WAF → ALB      │       │  WAF → ALB      │
           │  EKS + Karpenter│       │  EKS (scaled    │
           │  orders,payments│       │  down, warm)    │
           │  inventory,     │       │                 │
           │  fulfillment,   │       │                 │
           │  admin, NATS    │       │                 │
           │  Aurora primary ├──────►│ Aurora secondary│
           └─────────────────┘ global└─────────────────┘
                                 replication
   Argo CD (per cluster) ◄── this repo (gitops/)  ◄── PRs from supply-chain
```

Decisions and trade-offs are in [`docs/adr/`](docs/adr/) (why active/passive,
why KEDA on queue depth, how secrets reach pods, state layout).

## Quickstart: run the proof on your machine

Needs Docker, kind ≥ 0.24, kubectl, helm, kubectl-argo-rollouts, python3
with matplotlib; ~6 GB RAM, ~8 GB free disk; about 30 minutes.

```bash
git clone https://github.com/ipenas-cl/orderflow-platform && cd orderflow-platform
make images   # clones ipenas-cl/orderflow next to this repo at release/orderflow.ref and builds it
make prove    # kind cluster + add-ons + Argo CD sync + game day + bad canary + report
open docs/results/report.md
make down
```

Static checks only (no cluster): `make lint` (terraform fmt/validate,
tflint, checkov, kustomize render, Kyverno CLI on every pod template).

Nothing here creates AWS resources unless you run `terraform apply` yourself
in `terraform/envs/*`; see [`docs/cost.md`](docs/cost.md) before you do.

## Latest proof run

Oct 22, 2026, 2-node kind cluster, ~14 min of k6 load (20 rps orders + 5 rps
payments, burst to 80 rps) while Chaos Mesh killed a payments pod, slowed the
payment provider by 300 ms, took NATS down for 45 s and killed Postgres.

| | Result | SLO |
|---|---|---|
| Availability, all services | **99.906%** (10 5xx of 10,780) | 99.9% |
| p99 `POST /v1/orders`, whole run | **17 ms** | < 300 ms |
| 1-minute windows under the p99 target | 86% (misses are the injected-latency and outage minutes) | 99% over 30 days |
| Postgres killed → writable again | **1.2 s** | RTO < 60 s |
| Saga | 2,486 delivered and 431 compensated during the window | every order reaches a terminal state |
| Autoscaling | 5 rescale events during the burst | |
| Bad canary (payments pointed at a dead host) | **aborted and rolled back by the analysis, no human** | |
| Root pod / pod without probes or limits | rejected at admission (Pod Security, Kyverno) | rejected |

Orders still paid but not yet delivered when the window closed are waiting on
the simulated carrier (fulfillment advances shipments on a timer); after the
run that backlog kept draining to DELIVERED at roughly 350 orders a minute.

Full report with timeline and charts: [`docs/results/report.md`](docs/results/report.md).
Host quirks found along the way (nftables kube-proxy, missing netem) are in
[`proof/README.md`](proof/README.md).

## Docs

- [SLOs and alerting](docs/slo.md)
- [DR plan: RTO/RPO, region failover](docs/dr-plan.md)
- [Runbooks](docs/runbooks/)
- [Game day](docs/game-day.md)
- [ADRs](docs/adr/)
- [Cost estimate](docs/cost.md)

## Honest limits

- The AWS layer is validated (`terraform validate`, tflint, checkov) and
  costed, not kept running: a live multi-region stack costs real money every
  month. The kind proof exercises everything above the cloud layer.
- On kind, Postgres is a single StatefulSet; "DB failover" means the pod is
  killed and rescheduled, a stand-in for Aurora failover.
- Where the host kernel lacks `tc netem`, network latency is injected at the
  payment provider simulator instead of with Chaos Mesh; the report says which.

MIT licensed.
