# Saga compensation spike

**Alert:** `SagaCompensationSpike`: more than 20% of new orders end CANCELLED/REFUNDED.

Compensation is the saga working. A spike means a dependency is saying "no" a lot.

1. Which step? `sum by (status) (rate(orderflow_saga_transitions_total[5m]))`. Many CANCELLED right after STOCK_RESERVED = payments declining/failing; CANCELLED from PENDING = out of stock.
2. Payments: provider decline rate vs error rate (`orderflow_provider_calls_total` by result). Declines are business (tell the business); errors are ours or the PSP's → [error-budget-burn](error-budget-burn.md#psp).
3. Inventory: a bulk import may have zeroed stock. Check the admin backoffice.
4. Dead letters: `orderflow_consumer_messages_total{result="dead_letter"}`. Each one is logged as `message dead-lettered` with consumer, subject and event id; the event is still in the ORDERFLOW stream, so after the fix replay it with `nats stream get ORDERFLOW <seq>` + republish (dedupe makes this safe).
