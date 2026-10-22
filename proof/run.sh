#!/usr/bin/env bash
# Game day against the proof cluster. Every step appends a timestamped event
# to proof/.out/events.jsonl; proof/collect.py turns Prometheus data, k6
# summaries and these events into docs/results/.
set -euo pipefail
cd "$(dirname "$0")/.."
source proof/versions.env
OUT=proof/.out; mkdir -p "$OUT"; EV=$OUT/events.jsonl; : > "$EV"
STEADY=${STEADY:-7m}
log()  { printf '\n\033[1m[run %s] %s\033[0m\n' "$(date +%T)" "$*"; }
mark() { printf '{"t":%s,"event":"%s","detail":%s}\n' "$(date +%s)" "$1" "${2:-null}" >> "$EV"; log "$1"; }
json() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'; }

k6job() { # name script duration-env
  local name=$1 script=$2; shift 2
  kubectl -n loadgen delete job "$name" --ignore-not-found >/dev/null
  kubectl -n loadgen create configmap "$name-script" --from-file=script.js="$script" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  local envs=""; for kv in "$@"; do envs+="{\"name\":\"${kv%%=*}\",\"value\":\"${kv#*=}\"},"; done
  cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: { name: $name, namespace: loadgen }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: $K6_IMAGE
          args: [run, --quiet, /s/script.js]
          env: [${envs%,}]
          resources: { requests: { cpu: 200m, memory: 128Mi }, limits: { cpu: "2", memory: 768Mi } }
          volumeMounts: [{ name: s, mountPath: /s }]
      volumes: [{ name: s, configMap: { name: $name-script } }]
YAML
}
k6wait() { kubectl -n loadgen wait --for=condition=complete --for=condition=failed "job/$1" --timeout=20m >/dev/null 2>&1 || true
  kubectl -n loadgen logs "job/$1" > "$OUT/$1.log" 2>&1 || true; }
apps_ready() { # all orderflow app pods ready?
  kubectl -n orderflow get pods -l app.kubernetes.io/part-of=orderflow \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -qv true && return 1 || return 0; }

kubectl create namespace loadgen --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ---------------------------------------------------------------- policy gate
log "Kyverno admission: a root pod without probes/limits must be rejected"
if out=$(kubectl apply -f proof/manifests/root-pod.yaml 2>&1); then
  mark policy_violation_admitted "$(echo "$out" | json)"; kubectl delete -f proof/manifests/root-pod.yaml
else
  mark policy_violation_rejected "$(echo "$out" | json)"
fi

# ------------------------------------------------------------------- game day
kubectl -n orderflow delete podchaos,networkchaos --all >/dev/null 2>&1 || true
mark gameday_start
k6job gameday proof/k6/gameday.js STEADY="$STEADY"
sleep 90
mark chaos_payments_pod_kill; kubectl apply -f proof/chaos/payments-pod-kill.yaml
sleep 60
mark chaos_payments_latency_start; kubectl apply -f proof/chaos/payments-latency.yaml
sleep 75
mark chaos_payments_latency_end
mark chaos_nats_outage_start; kubectl apply -f proof/chaos/nats-outage.yaml
sleep 50
mark chaos_nats_outage_end
sleep 40
mark chaos_db_failover_start; t0=$(date +%s)
kubectl apply -f proof/chaos/db-failover.yaml
sleep 3
until kubectl -n orderflow exec postgres-0 -- pg_isready -h 127.0.0.1 -q 2>/dev/null; do sleep 1; done
mark db_writable "$(( $(date +%s) - t0 ))"
until apps_ready; do sleep 1; done
mark services_recovered "$(( $(date +%s) - t0 ))"
k6wait gameday
mark gameday_end
kubectl -n orderflow delete podchaos,networkchaos --all >/dev/null 2>&1 || true

# ------------------------------------------------- canary: bad release via git
log "bad release: payments pointed at a PSP host that does not exist (config regression)"
sleep 30
WT=/tmp/orderflow-bad-release; rm -rf "$WT"; git worktree prune
git branch -D proof/bad-release >/dev/null 2>&1 || true
git worktree add -q -b proof/bad-release "$WT" HEAD
cat >> "$WT/gitops/orderflow/overlays/kind/kustomization.yaml" <<'YAML'
  # BAD RELEASE (proof only): wrong PSP endpoint
  - target: { kind: Rollout, name: payments }
    patch: |-
      - op: test
        path: /spec/template/spec/containers/0/env/8/name
        value: PROVIDER_URL
      - op: replace
        path: /spec/template/spec/containers/0/env/8/value
        value: http://payprovider-v2.orderflow:8090
YAML
sed -i 's#targetRevision: HEAD#targetRevision: proof/bad-release#' "$WT/gitops/apps/kind/applications.yaml"
git -C "$WT" -c user.name=proof -c user.email=proof@localhost commit -qam "proof: bad payments release"
k6job canary proof/k6/canary.js DURATION=7m
sleep 20
mark bad_release_promoted
kubectl -n argocd patch application root --type merge -p '{"spec":{"source":{"targetRevision":"proof/bad-release"}}}'
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite >/dev/null
phase=""
for i in $(seq 1 60); do
  phase=$(kubectl -n orderflow get rollout payments -o jsonpath='{.status.phase}/{.status.abort}' 2>/dev/null)
  echo "  payments rollout: $phase"
  [[ "$phase" == Degraded/true ]] && break
  sleep 10
done
if [[ "$phase" == Degraded/true ]]; then mark canary_aborted "$(kubectl -n orderflow get rollout payments -o jsonpath='{.status.message}' | json)"
else mark canary_not_aborted "\"$phase\""; fi
kubectl -n orderflow get analysisrun -o json > "$OUT/analysisruns.json"
kubectl argo rollouts -n orderflow get rollout payments --no-color > "$OUT/rollout-payments.txt" 2>&1 || true
# revert: point Argo back at main; Argo syncs the good spec back
kubectl -n argocd patch application root --type merge -p '{"spec":{"source":{"targetRevision":"HEAD"}}}'
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite >/dev/null
for i in $(seq 1 30); do
  sleep 10; p=$(kubectl -n orderflow get rollout payments -o jsonpath='{.status.phase}')
  [[ "$p" == Healthy ]] && break
done
mark release_reverted
k6wait canary
git worktree remove --force "$WT"; git branch -D proof/bad-release >/dev/null

kubectl get events -A --field-selector reason=SuccessfulRescale -o json > "$OUT/rescale-events.json"
kubectl -n orderflow get hpa -o wide > "$OUT/hpa.txt"
log "done; now: python3 proof/collect.py"
