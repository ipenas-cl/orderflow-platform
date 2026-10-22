// Light, steady payments traffic so the canary analysis has data to judge.
import http from "k6/http";
import { check } from "k6";
const PAYMENTS = __ENV.PAYMENTS_URL || "http://payments.orderflow:8080";
export const options = {
  scenarios: { payments: { executor: "constant-arrival-rate", rate: 10, timeUnit: "1s",
    duration: __ENV.DURATION || "6m", preAllocatedVUs: 20, maxVUs: 60 } },
};
export default function () {
  const key = `canary-${__VU}-${__ITER}-${Date.now()}`;
  const r = http.post(`${PAYMENTS}/v1/payments`,
    JSON.stringify({ order_id: key, amount_cents: 500, currency: "USD" }),
    { headers: { "Content-Type": "application/json", "Idempotency-Key": key }, timeout: "10s" });
  check(r, { "not 5xx": (x) => x.status < 500 });
}
export function handleSummary(data) {
  return { stdout: "\n===K6_SUMMARY_JSON===\n" + JSON.stringify(data) + "\n===END===\n" };
}
