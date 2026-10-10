-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: pay_refund_queue
--
-- Money that arrived at the gateway and that the library COULD NOT apply: a capture for an order that is already paid or
-- cancelled, or for an invoice that was voided or paid in the meantime. pay_apply_capture rolls the attempted application
-- back (no invoice, number, payment or entitlement is created) and records the fact here instead of raising, so the entry
-- is committed and VISIBLE: a human must refund it (or apply it deliberately) and then closes the entry with
-- _pay_refund_queue_resolve(). One entry per (gateway, transaction): a redelivery does not add another.
--   reason  review_mismatch (tenant / platform / gateway / mode / amount / currency disagrees with the order, or a
--           transaction re-reported against another order) | unattributed (our order reference, no such order) |
--           order_not_open | invoice_not_payable | invoice_already_paid |
--           entitlement_conflict (a period paid for a postpaid entitlement) | paid_while_suspended (a payment for a suspended entitlement: a human decides) |
--           wallet_unfulfillable (a paid wallet top-up whose pack is gone, inactive or grants nothing)
--   last_alert_at  stamped by pay_refund_queue_alert_sent() when the AGEING alert for an entry that stays open was delivered
--   status  open -> refunded | applied_manually | dismissed
CREATE TABLE pay_refund_queue (
    id              BIGSERIAL PRIMARY KEY,
    gateway_code    TEXT NOT NULL,
    gateway_txn_ref TEXT NOT NULL,
    order_ref       TEXT,
    tenant_id       UUID,
    platform_code   VARCHAR(50),
    amount_minor    BIGINT NOT NULL,
    currency        TEXT NOT NULL,
    reason          TEXT NOT NULL,
    detail          TEXT,
    status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'refunded', 'applied_manually', 'dismissed')),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    resolved_at     TIMESTAMPTZ,
    resolved_by     TEXT,
    resolution_note TEXT,
    last_alert_at   TIMESTAMPTZ,
    UNIQUE (gateway_code, gateway_txn_ref)
);
CREATE INDEX pay_refund_queue_open ON pay_refund_queue (created_at) WHERE status = 'open';
