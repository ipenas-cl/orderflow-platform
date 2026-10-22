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
k6wait() { # wait for the Job to finish (complete or failed), then keep its log
  for i in $(seq 1 240); do
    [[ -n "$(kubectl -n loadgen get job "$1" -o jsonpath='{.status.completionTime}{.status.failed}')" ]] && break
    sleep 5
  done
  kubectl -n loadgen logs "job/$1" > "$OUT/$1.log" 2>&1 || true; }
cleanup_chaos() {
  kubectl -n orderflow delete podchaos,networkchaos,httpchaos --all --wait=false >/dev/null 2>&1 || true
  for k in networkchaos httpchaos podchaos; do
    for n in $(kubectl -n orderflow get $k -o name 2>/dev/null); do
      kubectl -n orderflow patch "$n" --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
    done
  done; }

kubectl create namespace loadgen --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ---------------------------------------------------------------- policy gate
log "admission: violating pods must be rejected"
for m in root-pod no-probes-pod; do
  if out=$(kubectl apply -f proof/manifests/$m.yaml 2>&1); then
    mark "policy_${m//-/_}_admitted" "$(echo "$out" | json)"; kubectl delete -f proof/manifests/$m.yaml
  else
    mark "policy_${m//-/_}_rejected" "$(echo "$out" | json)"
  fi
done

# ------------------------------------------------------------------- game day
cleanup_chaos
mark gameday_start
k6job gameday proof/k6/gameday.js STEADY="$STEADY"
sleep 90
mark chaos_payments_pod_kill; kubectl apply -f proof/chaos/payments-pod-kill.yaml
sleep 60
mark chaos_payments_latency_start; kubectl apply -f proof/chaos/payments-latency.yaml
sleep 10
if [[ "$(kubectl -n orderflow get networkchaos payments-latency -o jsonpath='{.status.conditions[?(@.type=="AllInjected")].status}')" != True ]]; then
  # tc netem missing in this kernel (CONFIG_NET_SCH_NETEM): record that, then fall back
  mark networkchaos_not_injected "$(kubectl -n orderflow get networkchaos payments-latency -o jsonpath='{.status.experiment.containerRecords[0].phase}' | json)"
  # recovery can't remove a qdisc that was never added; drop the finalizer
  kubectl -n orderflow delete networkchaos payments-latency --wait=false
  kubectl -n orderflow patch networkchaos payments-latency --type merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  # fallback: same fault one hop further, on payments' dependency, using the
  # PSP simulator's runtime fault switch (application-level injection)
  kubectl -n orderflow port-forward svc/payprovider 18090:8090 >/dev/null 2>&1 & pf=$!; sleep 2
  before=$(curl -fsS localhost:18090/admin/chaos)
  curl -fsS -X PUT localhost:18090/admin/chaos -H 'Content-Type: application/json' \
    -d "$(echo "$before" | python3 -c 'import json,sys; c=json.load(sys.stdin); c.update(latency_ms=300, jitter_ms=100); print(json.dumps(c))')" >/dev/null
  mark chaos_psp_latency_start "$(curl -fsS localhost:18090/admin/chaos | json)"
  sleep 60
  curl -fsS -X PUT localhost:18090/admin/chaos -H 'Content-Type: application/json' -d "$before" >/dev/null
  kill $pf
else
  sleep 65
fi
mark chaos_payments_latency_end
mark chaos_nats_outage_start; kubectl apply -f proof/chaos/nats-outage.yaml
sleep 50
mark chaos_nats_outage_end
sleep 40
mark chaos_db_failover_start
uid=$(kubectl -n orderflow get pod postgres-0 -o jsonpath='{.metadata.uid}'); t0=$(date +%s.%N)
kubectl apply -f proof/chaos/db-failover.yaml
until [[ "$(kubectl -n orderflow get pod postgres-0 -o jsonpath='{.metadata.uid}' 2>/dev/null)" != "$uid" ]] \
   && kubectl -n orderflow exec postgres-0 -- pg_isready -h 127.0.0.1 -q 2>/dev/null; do sleep 0.5; done
db_s=$(python3 -c "import time; print(round(time.time()-$t0,1))")
mark db_writable "$db_s"
# watch app readiness for 90 s: did anything go unready, and when was everything ready again?
total=$(kubectl -n orderflow get pods -l app.kubernetes.io/part-of=orderflow --no-headers | wc -l); min=$total; last_bad=0
for i in $(seq 1 90); do
  r=$(kubectl -n orderflow get pods -l app.kubernetes.io/part-of=orderflow -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c true || true)
  (( r < min )) && min=$r; (( r < total )) && last_bad=$(python3 -c "import time; print(round(time.time()-$t0,1))")
  sleep 1
done
mark services_recovered "{\"db_writable_s\": $db_s, \"app_pods\": $total, \"min_ready\": $min, \"all_ready_after_s\": $last_bad}"
k6wait gameday
mark gameday_end
cleanup_chaos

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
