# `make prove`

Runs the platform on a laptop-sized kind cluster and breaks it on purpose.

| Step | Script | What happens |
|---|---|---|
| up | `up.sh` | 2-node kind (zones `zone-a`/`zone-b`, nftables kube-proxy); metrics-server, Prometheus, Kyverno, Argo Rollouts, KEDA, Chaos Mesh, Argo CD (pinned in `versions.env`); random DB password into a Secret; an in-cluster git daemon serves **this repo's HEAD** so Argo CD syncs `gitops/bootstrap/root-kind.yaml` → `gitops/apps/kind` → Kyverno policies + `gitops/orderflow/overlays/kind`. |
| run | `run.sh` | policy check (a root pod must be rejected); k6 game day (`k6/gameday.js`: 20 rps orders + 5 rps payments, then a burst to 80 rps) while Chaos Mesh kills a payments pod, adds latency to payments, takes NATS down for 45 s and kills Postgres; then a **bad release** committed to a throwaway branch and synced by Argo CD, which the canary analysis must abort. |
| collect | `collect.py` | Prometheus queries + k6 summaries + AnalysisRuns + events → `docs/results/report.md`, charts, `raw/`. |

Requirements: Docker, kind ≥ 0.24, kubectl, helm, kubectl-argo-rollouts,
python3 with matplotlib, and the orderflow images built locally as
`orderflow-<service>:latest` (see the `prove` workflow). About 6 GB RAM, 4 GB disk.

## Host notes (things this proof ran into)

- **kube-proxy iptables mode fails** on kernels without `xt_statistic`
  ("Extension statistic revision 0 not supported"): Services with more than
  one endpoint get no rules, and DNS times out. `kind.yaml` uses the
  nftables proxier.
- **NetworkChaos needs `sch_netem`.** On kernels built without
  `CONFIG_NET_SCH_NETEM` (this box), `tc` fails with "Specified qdisc kind is
  unknown". Chaos Mesh HTTPChaos did not inject here either (stays "Not
  Injected/Wait"). `run.sh` detects the failed injection, records it as
  `networkchaos_not_injected`, and adds the latency one hop further instead:
  +300 ms ±100 ms on the PSP that payments calls, through the simulator's
  `PUT /admin/chaos` fault switch. GitHub-hosted runners have netem, so CI
  runs the real NetworkChaos.
- Docker hosts with both iptables-legacy and nft rules may drop forwarded
  traffic from user-defined bridges (kind nodes can't pull images). Check
  `iptables-legacy -S FORWARD` for a DROP policy.
