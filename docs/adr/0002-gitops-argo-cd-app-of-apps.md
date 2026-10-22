# 0002. GitOps with Argo CD app-of-apps

Status: accepted · 2026-10

## Context
Clusters drift when people `kubectl apply`. After a region loss we need to rebuild a cluster from nothing, quickly and exactly.

## Decision
Argo CD in each cluster; one hand-applied root Application per environment (`gitops/bootstrap/root-<env>.yaml`) which owns every other Application (`gitops/apps/<env>`), with sync waves: add-ons (-10) → platform config (-5/-4) → workloads (0). `selfHeal` and `prune` on. CI never talks to clusters; it opens PRs.

## Consequences
- Rebuild = terraform apply + one `kubectl apply`. Rollback = git revert.
- Emergency changes must also go through git or they are reverted within 30 s. That is the point; the runbooks say so.
- Rollout `spec.replicas` is owned by HPA/KEDA; server-side diff keeps Argo from fighting them.
