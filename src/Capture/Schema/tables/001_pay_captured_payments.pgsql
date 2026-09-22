-- package: progalaxyelabs/stonescriptphp-pay v0.3.0
-- stonescriptphp-pay :: Capture :: tables :: pay_captured_payments
--
-- THE canonical, safe-by-default idempotent payment-CAPTURE primitive for the
-- whole StoneScriptPHP ecosystem. StoneScriptPHP is the default runtime a
-- non-technical customer's app gets auto-provisioned on — every scaffolded
-- project inherits whatever pattern this table + its function
-- (001_pay_record_captured_payment.pgsql) implement, so it must be correct
-- by construction, not by caller discipline.
--
-- SCOPE (deliberately narrow): this table records the FACT that a given
-- gateway transaction was captured, exactly once. It owns NO business side
-- effect (no wallet credit, no subscription extension, no invoice
-- transition) — those belong to the CONSUMER's own domain table/function
-- (subscription_payments+sub_activate, scan_credit_transactions+
-- scan_credit_purchase_apply, inv_payments+inv_record_payment, ...). A
-- consumer composes its own idempotent side effect ON TOP of this primitive
-- by gating on `pay_record_captured_payment()`'s `o_already_applied` output
-- (see that function's docblock for the exact composition contract).
--
-- IDEMPOTENCY KEY: (gateway_code, gateway_txn_ref) — the gateway's own
-- payment/transaction id, namespaced by gateway (so 'razorpay':'pay_ABC'
-- and 'paypal':'pay_ABC' — however unlikely a real collision — are never
-- conflated). A webhook redelivery (routine — Razorpay/PayPal redeliver
-- payment.captured at-least-once on timeout) replays the SAME
-- (gateway_code, gateway_txn_ref) and must be recognised as the SAME
-- payment, never recorded twice.
--
-- `reference` is an OPAQUE, caller-owned correlation key — an order id, a
-- subscription's (platform_code, tenant_id) composite rendered as a string,
-- an invoice id, a wallet top-up id, ... `pay` never interprets it; it exists
-- so the caller can find "which payments did I record for X" without
-- maintaining a second index.
CREATE TABLE IF NOT EXISTS pay_captured_payments (
    id              BIGSERIAL PRIMARY KEY,
    gateway_code    TEXT NOT NULL,                 -- e.g. 'razorpay', 'paypal' — see StoneScriptPHP\Billing\Contracts\GatewayCode
    gateway_txn_ref TEXT NOT NULL,                  -- the gateway's own payment/capture/txn id — THE idempotency key (paired with gateway_code)
    reference       TEXT NOT NULL,                  -- caller-owned opaque correlation key (order id / subscription ref / invoice id / ...)
    amount_minor    BIGINT NOT NULL,                -- paisa/cents, in `currency`
    currency        TEXT NOT NULL,                  -- ISO 4217
    status          TEXT NOT NULL,                  -- 'success' | 'failed' (app-validated enum, see the function's guard)
    captured_at     TIMESTAMPTZ NOT NULL,           -- the GATEWAY's own capture time (business input, never our now())
    raw_payload     JSONB,                          -- the verified webhook/return-path payload, for audit/reconciliation
    created_by      TEXT NOT NULL,                  -- attribution string identifying the calling system (e.g. 'webhook:razorpay')
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- "Correct by construction, not by caller discipline" (see the header
    -- above) applies to the table's own guardrails too, not just the
    -- function's: a direct INSERT (a consumer's own migration, a fix-up
    -- script) that bypasses pay_record_captured_payment() is still held to
    -- the same enum + non-negative-amount rules the function enforces.
    CONSTRAINT pay_captured_payments_status_valid CHECK (status IN ('success', 'failed')),
    CONSTRAINT pay_captured_payments_amount_nonneg CHECK (amount_minor >= 0)
);

-- THE exactly-once guarantee. A plain, non-partial UNIQUE index (every
-- captured payment — success or failed — carries a real gateway_txn_ref, so
-- there is no NULL case to special-case with a partial index, unlike
-- subscription_payments.gateway_payment_id which is genuinely optional for
-- non-gateway activations). Two concurrent INSERTs targeting the SAME
-- (gateway_code, gateway_txn_ref) serialize at the index level: the second
-- blocks on the first's uncommitted row, then — once the first commits —
-- conflicts and affects 0 rows. See 001_pay_record_captured_payment.pgsql
-- for why this alone is a complete concurrency guarantee for THIS table
-- (no advisory lock / exception-savepoint needed, because this primitive has
-- no side effect of its own to roll back).
CREATE UNIQUE INDEX IF NOT EXISTS pay_captured_payments_gateway_txn_unique
    ON pay_captured_payments (gateway_code, gateway_txn_ref);

CREATE INDEX IF NOT EXISTS pay_captured_payments_reference
    ON pay_captured_payments (reference);
