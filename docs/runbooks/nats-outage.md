# NATS outage / outbox backlog

**Alerts:** `OutboxPublishFailing`, KEDA ScaledObject `Fallback=True`.

Producers write events to a Postgres outbox in the same transaction as the state change, so a NATS outage delays the saga but loses nothing.

1. NATS health: `kubectl -n orderflow exec nats-0 -- wget -qO- localhost:8222/healthz?js-enabled-only=true`; JetStream meta leader present (`/jsz`).
2. Disk? JetStream stops accepting writes when the file store is full: PVC usage.
3. After recovery: outbox backlog drains (`orderflow_outbox_published_total` spikes) and consumers catch up. KEDA scales consumers on lag, so expect a short scale-out.
4. If the backlog doesn't drain: restart the outbox relay (the service pod); it is idempotent: every event is published with its id as `Nats-Msg-Id`, and JetStream drops duplicates within a 2-minute window.
