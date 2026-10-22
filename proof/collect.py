#!/usr/bin/env python3
"""Turn a proof run into docs/results: report.md, charts, raw data.

Reads proof/.out (events, k6 logs, AnalysisRuns) and queries Prometheus
(port-forwarded by `make prove` to PROM_URL). Nothing here is synthesized:
every number in the report comes from one of those sources, and missing data
is reported as missing.
"""
import json, os, sys, time, urllib.parse, urllib.request, datetime as dt
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

PROM = os.environ.get("PROM_URL", "http://127.0.0.1:9090")
OUT = "proof/.out"
RES = "docs/results"
os.makedirs(f"{RES}/raw", exist_ok=True)
NOPROBE = 'route!~".*(healthz|readyz|metrics)"'

events = [json.loads(l) for l in open(f"{OUT}/events.jsonl") if l.strip()]
ev = {e["event"]: e for e in events}
T0 = ev["gameday_start"]["t"]; T1 = ev["gameday_end"]["t"]
C0 = ev.get("bad_release_promoted", {}).get("t"); C1 = ev.get("release_reverted", {}).get("t")

def q(path, **params):
    url = f"{PROM}/api/v1/{path}?" + urllib.parse.urlencode(params)
    with urllib.request.urlopen(url, timeout=30) as r:
        d = json.load(r)
    assert d["status"] == "success", d
    return d["data"]["result"]

def rng(expr, start, end, step=10):
    return q("query_range", query=expr, start=start, end=end, step=step)

def inst(expr, at):
    r = q("query", query=expr, time=at)
    return float(r[0]["value"][1]) if r else float("nan")

def k6(name):
    try:
        s = open(f"{OUT}/{name}.log").read()
        return json.loads(s.split("===K6_SUMMARY_JSON===")[1].split("===END===")[0])
    except Exception as e:  # report as missing, never invent
        print(f"k6 summary {name} missing: {e}", file=sys.stderr); return None

dur = f"{T1 - T0}s"
total = inst(f'sum(increase(orderflow_http_requests_total{{{NOPROBE}}}[{dur}]))', T1)
errors = inst(f'sum(increase(orderflow_http_requests_total{{code=~"5..",{NOPROBE}}}[{dur}]))', T1)
edge_total = inst(f'sum(increase(orderflow_http_requests_total{{service="orders",{NOPROBE}}}[{dur}]))', T1)
edge_err = inst(f'sum(increase(orderflow_http_requests_total{{service="orders",code=~"5..",{NOPROBE}}}[{dur}]))', T1)
p99_orders = inst(f'histogram_quantile(0.99, sum by (le) (increase(orderflow_http_request_duration_seconds_bucket{{service="orders",{NOPROBE}}}[{dur}])))', T1)
p99_pay = inst(f'histogram_quantile(0.99, sum by (le) (increase(orderflow_http_request_duration_seconds_bucket{{service="payments",{NOPROBE}}}[{dur}])))', T1)
saga = {r["metric"].get("status", "?"): float(r["value"][1]) for r in
        q("query", query=f'sum by (status) (increase(orderflow_saga_transitions_total[{dur}]))', time=T1)}
lat_windows = rng(f'histogram_quantile(0.99, sum by (le) (rate(orderflow_http_request_duration_seconds_bucket{{service="orders",{NOPROBE}}}[1m])))', T0 + 60, T1)
vals = [float(v) for _, v in (lat_windows[0]["values"] if lat_windows else []) if v not in ("NaN", "+Inf")]
lat_ok = sum(1 for v in vals if v < 0.3) / len(vals) if vals else float("nan")

# ---- charts
def ts(series): return [dt.datetime.fromtimestamp(float(t)) for t, _ in series], [float(v) if v not in ("NaN", "+Inf") else float("nan") for _, v in series]
def annotate(ax, lo, hi):
    for e in events:
        if lo <= e["t"] <= hi and e["event"].startswith(("chaos", "db_", "services_", "bad_release", "canary_")):
            ax.axvline(dt.datetime.fromtimestamp(e["t"]), color="grey", ls=":", lw=1)
            ax.text(dt.datetime.fromtimestamp(e["t"]), ax.get_ylim()[1] * 0.97, e["event"].replace("chaos_", ""), rotation=90, va="top", fontsize=7)

def chart(name, title, ylabel, queries, lo, hi, hline=None, logy=False):
    fig, ax = plt.subplots(figsize=(11, 4))
    for label, expr in queries:
        for s in rng(expr, lo, hi):
            x, y = ts(s["values"])
            ax.plot(x, y, label=label.format(**s["metric"]) if "{" in label else label, lw=1.4)
    if hline: ax.axhline(hline[0], color="red", ls="--", lw=1, label=hline[1])
    if logy: ax.set_yscale("symlog", linthresh=0.001)
    ax.set_title(title); ax.set_ylabel(ylabel); ax.grid(alpha=.3); ax.legend(fontsize=8, loc="upper left")
    annotate(ax, lo, hi); fig.autofmt_xdate(); fig.tight_layout(); fig.savefig(f"{RES}/{name}.png", dpi=110); plt.close(fig)

chart("gameday-error-ratio", "5xx ratio (all services, excl. probes) during game day", "ratio",
      [("error ratio", f'sum(rate(orderflow_http_requests_total{{code=~"5..",{NOPROBE}}}[1m])) / sum(rate(orderflow_http_requests_total{{{NOPROBE}}}[1m]))')],
      T0, T1, hline=(0.001, "SLO 99.9%"), logy=True)
chart("gameday-p99", "p99 latency by service (1m windows)", "seconds",
      [("{service}", f'histogram_quantile(0.99, sum by (le, service) (rate(orderflow_http_request_duration_seconds_bucket{{service=~"orders|payments",{NOPROBE}}}[1m])))')],
      T0, T1, hline=(0.3, "orders SLO 300ms"))
chart("gameday-replicas", "Replicas (HPA / KEDA-managed HPA)", "replicas",
      [("{horizontalpodautoscaler}", 'kube_horizontalpodautoscaler_status_current_replicas{namespace="orderflow"}')], T0, T1)
chart("gameday-saga", "Saga transitions per second by resulting status", "transitions/s",
      [("{status}", 'sum by (status) (rate(orderflow_saga_transitions_total[1m]))')], T0, T1)
if C0 and C1:
    chart("canary-error-ratio", "Bad release: payments 5xx ratio, canary vs stable", "ratio",
          [("pod hash {rollouts_pod_template_hash}", f'sum by (rollouts_pod_template_hash) (rate(orderflow_http_requests_total{{service="payments",code=~"5..",{NOPROBE}}}[1m])) / sum by (rollouts_pod_template_hash) (rate(orderflow_http_requests_total{{service="payments",{NOPROBE}}}[1m]))')],
          C0 - 60, C1 + 60, hline=(0.01, "canary gate 1%"))

# ---- scaling events
rescale = []
try:
    for it in json.load(open(f"{OUT}/rescale-events.json"))["items"]:
        rescale.append((it.get("lastTimestamp") or it.get("eventTime"), it["involvedObject"]["name"], it["message"]))
except Exception as e:
    print("rescale events missing:", e, file=sys.stderr)
rescale.sort()

# ---- canary analysis
analysis = []
try:
    for ar in json.load(open(f"{OUT}/analysisruns.json"))["items"]:
        for m in ar.get("status", {}).get("metricResults", []):
            last = (m.get("measurements") or [{}])[-1]
            analysis.append((ar["metadata"]["name"], m["name"], m.get("phase"), m.get("successful", 0), m.get("failed", 0), last.get("value")))
except Exception as e:
    print("analysis runs missing:", e, file=sys.stderr)

g = k6("gameday"); c = k6("canary")
def k6m(d, metric, stat):
    try: return d["metrics"][metric]["values"][stat]
    except Exception: return float("nan")

def fmt(x, pct=False, ms=False):
    if x != x: return "n/a"
    return f"{x*100:.3f}%" if pct else f"{x*1000:.0f} ms" if ms else f"{x:,.0f}"
avail = 1 - errors / total if total else float("nan")
edge_avail = 1 - edge_err / edge_total if edge_total else float("nan")
budget = (1 - avail) / 0.001 if avail == avail else float("nan")
ts_ = lambda t: dt.datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M:%S")
cancel = saga.get("CANCELLED", 0) + saga.get("REFUNDED", 0)

lines = [
"# Proof results", "",
f"Run: {ts_(T0)} to {ts_(T1)} (box local time, America/Santiago) on a 2-node kind cluster. "
"Generated by `proof/collect.py` from Prometheus, k6 summaries and Kubernetes objects. Raw data: [`raw/`](raw/).", "",
"## Summary", "",
"| | Result | Target |", "|---|---|---|",
f"| Availability, all services (non-5xx / all) | {fmt(avail, pct=True)} ({fmt(errors)} 5xx of {fmt(total)}) | 99.9% |",
f"| Availability, orders edge | {fmt(edge_avail, pct=True)} | 99.9% |",
f"| Error budget burned in this run (vs 99.9%) | {budget:.1f}x the allowed rate | < 1x over 30 days |" if budget == budget else "| Error budget | n/a | |",
f"| p99 orders (Prometheus, whole run) | {fmt(p99_orders, ms=True)} | < 300 ms |",
f"| p99 payments (Prometheus, whole run) | {fmt(p99_pay, ms=True)} | n/a (internal) |",
f"| 1-minute windows with orders p99 < 300 ms | {fmt(lat_ok, pct=True)} | 99% |",
f"| k6 orders: requests / failed / p99 | {fmt(k6m(g,'http_reqs','count'))} / {fmt(k6m(g,'http_req_failed','rate'), pct=True)} / {k6m(g,'http_req_duration','p(99)'):.0f} ms | |" if g else "| k6 game-day summary | missing | |",
f"| Saga transitions | {', '.join(f'{k}={v:,.0f}' for k, v in sorted(saga.items()))} | |",
f"| Saga compensations (CANCELLED + REFUNDED) | {cancel:,.0f} | every non-happy path ends compensated |",
f"| DB failover: DB writable / all services ready | {ev.get('db_writable',{}).get('detail','n/a')} s / {ev.get('services_recovered',{}).get('detail','n/a')} s | RTO target (kind) 60 s |",
f"| Autoscaling events (SuccessfulRescale) | {len(rescale)} | |",
f"| Bad canary release | {'auto-aborted' if 'canary_aborted' in ev else 'NOT aborted'} | auto-rollback, no human |",
f"| Kyverno: root pod without probes/limits | {'rejected' if 'policy_violation_rejected' in ev else 'ADMITTED'} | rejected |",
"", "## Timeline", "", "| Time | Event | Detail |", "|---|---|---|"]
for e in events:
    d = e.get("detail")
    d = "" if d is None else (str(d)[:160].replace("|", "/").replace("\n", " ") + (" s" if isinstance(d, int) else ""))
    lines.append(f"| {dt.datetime.fromtimestamp(e['t']).strftime('%H:%M:%S')} | `{e['event']}` | {d} |")
lines += ["", "## Charts", "",
"![error ratio](gameday-error-ratio.png)", "", "![p99](gameday-p99.png)", "",
"![replicas](gameday-replicas.png)", "", "![saga](gameday-saga.png)", ""]
if C0 and C1: lines += ["![canary](canary-error-ratio.png)", ""]
lines += ["## Canary analysis (bad release)", "", "| AnalysisRun | Metric | Phase | Successful | Failed | Last value |", "|---|---|---|---|---|---|"]
lines += [f"| {a} | {m} | {p} | {s} | {f} | {v} |" for a, m, p, s, f, v in analysis] or ["| (none recorded) | | | | | |"]
if c:
    lines += ["", f"Canary-phase k6 traffic: {fmt(k6m(c,'http_reqs','count'))} payments requests, "
              f"{fmt(k6m(c,'http_req_failed','rate'), pct=True)} failed (includes the 5xx served by the bad canary before it was aborted)."]
lines += ["", "## Autoscaling events", "", "| Time (UTC) | Object | Message |", "|---|---|---|"]
lines += [f"| {t} | {n} | {m} |" for t, n, m in rescale] or ["| (none) | | |"]
open(f"{RES}/report.md", "w").write("\n".join(lines) + "\n")
json.dump({"availability": avail, "errors": errors, "total": total, "edge_availability": edge_avail,
           "p99_orders_s": p99_orders, "p99_payments_s": p99_pay, "latency_windows_ok": lat_ok,
           "saga": saga, "events": events, "rescale": rescale, "analysis": analysis},
          open(f"{RES}/raw/summary.json", "w"), indent=1, default=str)
for f in ["events.jsonl", "analysisruns.json", "rollout-payments.txt", "hpa.txt"]:
    if os.path.exists(f"{OUT}/{f}"):
        open(f"{RES}/raw/{f}", "w").write(open(f"{OUT}/{f}").read())
for n, d in (("gameday", g), ("canary", c)):
    if d: json.dump({k: v.get("values") for k, v in d["metrics"].items()}, open(f"{RES}/raw/k6-{n}.json", "w"), indent=1)
print("\n".join(lines[:22]))
