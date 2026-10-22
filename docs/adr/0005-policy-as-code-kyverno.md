# 0005. Admission policies with Kyverno; signed images only

Status: accepted · 2026-10

## Context
Every postmortem pattern we've seen: a pod without limits starving a node, a pod without readiness probe taking traffic while broken, a root container with a CVE, an unsigned image built on someone's laptop.

## Decision
Kyverno ClusterPolicies enforced in every namespace labelled `policy.orderflow.dev/enforce=true`: non-root + no privilege escalation, readiness+liveness probes, CPU/memory requests and memory limit, and cosign keyless signature (plus SPDX SBOM attestation) from this repo's `supply-chain` workflow for `ghcr.io/ipenas-cl/orderflow/*`. The same policies run in CI (Kyverno CLI) against rendered manifests.

## Consequences
- In kind the signature rule is in Audit because images are built locally; everything else is enforced, and the proof checks that a violating pod is rejected.
- Policy is in v1 `ClusterPolicy`; Kyverno ≥1.17 flags it as deprecated in favour of CEL `ValidatingPolicy`/`ImageValidatingPolicy`. Migration is tracked; the semantics are the same.
