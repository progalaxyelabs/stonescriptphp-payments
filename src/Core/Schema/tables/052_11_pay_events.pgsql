-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: pay_events
--
-- Append-only event log written INSIDE the transaction that causes the event (pay_apply_capture),
-- so an event exists if and only if its effect does. This is how a platform reacts to a payment
-- without overriding the library: a consumer reads rows past a persisted cursor (id is the
-- cursor) and applies its domain effects idempotently.
--
--   payment.applied     a capture was applied exactly once (payload: order, purpose, invoice, payment, amounts)
--   entitlement.changed a subscription period or one-time licence was granted
--   wallet.credited     a wallet top-up grant was created
CREATE TABLE pay_events (
    id            BIGSERIAL PRIMARY KEY,
    event_type    TEXT NOT NULL,
    tenant_id     UUID NOT NULL,
    platform_code VARCHAR(50) NOT NULL,
    order_ref     TEXT,
    payload       JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX pay_events_type ON pay_events (event_type, id);
CREATE INDEX pay_events_order ON pay_events (order_ref) WHERE order_ref IS NOT NULL;
