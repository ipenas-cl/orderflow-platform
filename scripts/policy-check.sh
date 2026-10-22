#!/usr/bin/env bash
# Offline Kyverno check: every pod template in an overlay (Deployments,
# StatefulSets and Argo Rollouts, which Kyverno's autogen doesn't cover) is
# turned into a Pod and validated against our policies.
set -euo pipefail
cd "$(dirname "$0")/.."
OVERLAY=${1:-gitops/orderflow/overlays/kind}
KYVERNO=${KYVERNO:-kyverno}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
kustomize build "$OVERLAY" | python3 -c '
import sys, yaml
out = []
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") in ("Deployment", "StatefulSet", "Rollout"):
        t = d["spec"]["template"]
        out.append({"apiVersion": "v1", "kind": "Pod",
                    "metadata": {"name": d["kind"].lower() + "-" + d["metadata"]["name"],
                                 "namespace": d["metadata"].get("namespace", "orderflow"),
                                 "labels": t["metadata"].get("labels", {})},
                    "spec": t["spec"]})
yaml.safe_dump_all(out, sys.stdout)
' > "$tmp/pods.yaml"
cat > "$tmp/values.yaml" <<'YAML'
apiVersion: cli.kyverno.io/v1alpha1
kind: Values
namespaceSelector:
  - name: orderflow
    labels: { policy.orderflow.dev/enforce: "true" }
YAML
echo "pods to check: $(grep -c '^kind: Pod' "$tmp/pods.yaml")"
"$KYVERNO" apply gitops/platform/kyverno-policies/require-non-root.yaml \
  gitops/platform/kyverno-policies/require-probes.yaml \
  gitops/platform/kyverno-policies/require-limits.yaml \
  --resource "$tmp/pods.yaml" --values-file "$tmp/values.yaml" 2>&1 | grep -v 'deprecated'
