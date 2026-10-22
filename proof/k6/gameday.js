// Game-day load: steady order intake + idempotent payments, then a burst that
// should make the autoscalers act. Thresholds mirror the SLOs in docs/slo.md;
// k6 reports pass/fail but the proof judges SLOs from Prometheus.
import http from "k6/http";
import { check } from "k6";

const ORDERS = __ENV.ORDERS_URL || "http://orders.orderflow:8080";
const PAYMENTS = __ENV.PAYMENTS_URL || "http://payments.orderflow:8080";
const STEADY = __ENV.STEADY || "7m";
const SKUS = ["SKU-KEYBOARD", "SKU-MOUSE", "SKU-MONITOR"];

export const options = {
  discardResponseBodies: false,
  scenarios: {
    orders: {
      executor: "ramping-arrival-rate", startRate: 10, timeUnit: "1s",
      preAllocatedVUs: 60, maxVUs: 300,
      stages: [
        { target: 20, duration: "30s" },
        { target: 20, duration: STEADY },
        { target: 80, duration: "60s" },   // burst -> autoscaling
        { target: 80, duration: "90s" },
        { target: 0, duration: "20s" },
      ],
    },
    payments: { executor: "constant-arrival-rate", rate: 5, timeUnit: "1s", duration: "10m",
      preAllocatedVUs: 20, maxVUs: 100, exec: "payments" },
  },
  thresholds: {
    "http_req_failed{scenario:orders}": ["rate<0.01"],
    "http_req_duration{scenario:orders}": ["p(99)<300"],
  },
  summaryTrendStats: ["avg", "p(50)", "p(95)", "p(99)", "max"],
};

export default function () {
  const body = JSON.stringify({ customer_id: `k6-${__VU}`, currency: "USD",
    lines: [{ sku: SKUS[__ITER % SKUS.length], qty: 1, unit_price_cents: 1999 }] });
  const r = http.post(`${ORDERS}/v1/orders`, body, { headers: { "Content-Type": "application/json" }, timeout: "10s" });
  check(r, { "order accepted": (x) => x.status === 202 });
}

export function payments() {
  const key = `gd-${__VU}-${__ITER}-${Date.now()}`;
  const body = JSON.stringify({ order_id: key, amount_cents: 1000, currency: "USD" });
  const r = http.post(`${PAYMENTS}/v1/payments`, body,
    { headers: { "Content-Type": "application/json", "Idempotency-Key": key }, timeout: "10s" });
  check(r, { "payment not 5xx": (x) => x.status < 500 });
}

export function handleSummary(data) {
  return { stdout: "\n===K6_SUMMARY_JSON===\n" + JSON.stringify(data) + "\n===END===\n" };
}
