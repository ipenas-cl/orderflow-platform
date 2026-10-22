# Canary aborted

**Signal:** Argo CD app `orderflow` Degraded; `kubectl argo rollouts -n orderflow get rollout <svc>` shows `Degraded … RolloutAborted`.

Nothing is broken for customers: the canary was scaled to zero and the stable ReplicaSet kept serving. What's left to do is make git match reality.

1. Why? `kubectl -n orderflow get analysisrun -l rollouts-pod-template-hash=<canary hash> -o yaml` shows failing metric and measured values.
2. Revert the promotion PR (or merge a fix). Argo syncs, Rollouts returns to Healthy.
3. Never "retry" the same image without a change; it will fail the same way and burn budget again.
