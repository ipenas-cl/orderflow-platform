#!/usr/bin/env bash
# Bring up the proof cluster: kind + Argo CD + Rollouts + KEDA + Prometheus +
# Chaos Mesh + Kyverno + metrics-server, then let Argo CD deploy orderflow
# from this repo's HEAD commit.
set -euo pipefail
cd "$(dirname "$0")/.."
source proof/versions.env
CLUSTER=${CLUSTER:-orderflow}
ORDERFLOW_IMAGES=${ORDERFLOW_IMAGES:-orderflow}   # local image prefix: orderflow-<svc>:latest
log() { printf '\n\033[1m[up %s] %s\033[0m\n' "$(date +%T)" "$*"; }

if ! kind get clusters | grep -qx "$CLUSTER"; then
  log "creating kind cluster"
  sed "s#REPO_PATH#$PWD#" proof/kind.yaml > /tmp/kind-$CLUSTER.yaml
  kind create cluster --name "$CLUSTER" --config /tmp/kind-$CLUSTER.yaml --wait 120s
fi
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true

log "loading images into kind"
for s in orders payments inventory fulfillment admin payprovider devissuer; do
  docker tag "${ORDERFLOW_IMAGES}-$s:latest" "ghcr.io/ipenas-cl/orderflow/$s:0.1.0"
done
kind load docker-image --name "$CLUSTER" postgres:16-alpine nats:2.10-alpine \
  $(for s in orders payments inventory fulfillment admin payprovider devissuer; do echo ghcr.io/ipenas-cl/orderflow/$s:0.1.0; done)

log "helm add-ons"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null
helm repo add kedacore https://kedacore.github.io/charts >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add chaos-mesh https://charts.chaos-mesh.org >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo update >/dev/null
H="helm upgrade --install --wait --timeout 10m"
$H metrics-server metrics-server/metrics-server -n kube-system --version "$METRICS_SERVER_CHART" \
  --set 'args={--kubelet-insecure-tls}'
$H prometheus prometheus-community/prometheus -n monitoring --create-namespace --version "$PROMETHEUS_CHART" \
  -f proof/values/prometheus.yaml
$H kyverno kyverno/kyverno -n kyverno --create-namespace --version "$KYVERNO_CHART" -f proof/values/kyverno.yaml
$H argo-rollouts argo/argo-rollouts -n argo-rollouts --create-namespace --version "$ROLLOUTS_CHART" \
  --set dashboard.enabled=false --set controller.replicas=1
$H keda kedacore/keda -n keda --create-namespace --version "$KEDA_CHART"
$H chaos-mesh chaos-mesh/chaos-mesh -n chaos-mesh --create-namespace --version "$CHAOS_MESH_CHART" \
  -f proof/values/chaos-mesh.yaml
$H argocd argo/argo-cd -n argocd --create-namespace --version "$ARGOCD_CHART" -f proof/values/argocd.yaml

log "namespace + generated DB secret (random, never written to git)"
kubectl create namespace orderflow --dry-run=client -o yaml | kubectl apply -f -
if ! kubectl -n orderflow get secret orderflow-db >/dev/null 2>&1; then
  kubectl -n orderflow create secret generic orderflow-db \
    --from-literal=host=postgres --from-literal=username=orderflow \
    --from-literal=password="$(openssl rand -hex 16)" --from-literal=sslmode=disable
fi

log "git server + Argo CD root app (app-of-apps)"
kubectl apply -f proof/manifests/git-server.yaml
kubectl -n argocd rollout status deploy/git-server --timeout=180s
kubectl apply -f gitops/bootstrap/root-kind.yaml

log "waiting for Argo CD to sync orderflow"
for i in $(seq 1 90); do
  st=$(kubectl -n argocd get application orderflow -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)
  echo "  orderflow app: ${st:-<not yet created>}"
  [[ "$st" == "Synced/Healthy" ]] && break
  sleep 10
done
kubectl argo rollouts -n orderflow list rollouts
