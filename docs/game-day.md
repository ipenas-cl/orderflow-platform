# Game day guide

A game day is a rehearsal: we break things on purpose, on a schedule, with a
hypothesis written down first. `make prove` is the automated, repeatable core
of it. The quarterly staging game day adds the parts a laptop can't fake
(Aurora, Route 53, AZs).

## Roles

| Role | Responsibility |
|---|---|
| Game master | runs the script, injects faults, keeps time |
| Incident commander | responds as in a real incident, using only the runbooks |
| Observer / scribe | timestamps every observation; writes the report |

## Before

- [ ] Announce the window in #eng and on the status page (staging) / no announcement needed (kind).
- [ ] Error budget > 50% (we don't spend budget we don't have).
- [ ] Dashboards open: SLO, Rollouts, KEDA/HPA, NATS, Postgres.
- [ ] Abort criteria agreed: customer-visible errors in prod, or any data loss.

## Scenarios and hypotheses

Each one is in `proof/chaos/` and in the run order of `proof/run.sh`.

| # | Fault | Hypothesis (written before running) | Signals |
|---|---|---|---|
| 1 | Kyverno: apply a root pod without probes/limits | rejected at admission | `kubectl apply` error |
| 2 | `payments` pod killed | other replica serves; PDB keeps ≥1; no 5xx at orders edge (payment is async) | error ratio, saga |
| 3 | +300 ms latency on payments for 60 s (NetworkChaos; fallback: on the PSP payments calls) | orders p99 unaffected (async); payments p99 rises; circuit breaker does not open (< timeout) | p99 by service |
| 4 | NATS down for 45 s | orders keeps accepting (outbox in Postgres); events delivered after recovery; no message lost | outbox backlog, saga transitions resume |
| 5 | Postgres killed (failover stand-in) | services go unready (readiness pings DB), traffic shifts away, recover without restarts; recovery < 60 s | time to DB writable, time to all ready |
| 6 | Burst 20 → 80 rps | HPA/KEDA add replicas; p99 stays under SLO after scale-out | replicas chart |
| 7 | Bad release (payments → wrong PSP host) | canary analysis fails on the canary's own 5xx; auto-abort; stable untouched | AnalysisRun phase, canary error chart |

## During

- The scribe records timestamps (the proof writes `proof/.out/events.jsonl`).
- If an abort criterion trips: stop injecting (`kubectl -n orderflow delete podchaos,networkchaos --all`) and switch to incident mode.

## After

- Compare each hypothesis with what happened. The report is
  `docs/results/report.md` for the automated run.
- Every surprise becomes a ticket: a runbook fix, an alert, or a code change.
- Track: time to detect, time to mitigate, budget consumed.

## Running it

```bash
make prove            # ~25 min end to end on 4 vCPU / 16 GB
make prove STEADY=3m  # shorter steady phase
make down
```
