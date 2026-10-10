-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: pay_orders
--
-- A server-created payment order: the library's own record of "this tenant is being asked to
-- pay this amount, for this purpose, through this gateway". Created BEFORE the gateway order
-- exists, with an idempotency key, so a client retry can never produce a second order.
--
--   order_ref        library-generated opaque id; sent to the gateway as notes.order_id (and the
--                    receipt) and echoed back on every webhook: the routing key that ties a
--                    capture to this row. Never guessed from an e-mail address.
--   idempotency_key  supplied by the caller, unique per (tenant, platform). The same key with the
--                    same request returns the SAME order; the same key with a different request
--                    is refused (PY036).
--   purpose          closed set: subscription_period | one_time_license | wallet_topup | invoice_payment
--   catalog_ref      the plan / pack the purpose sells (a plan id as text), for the first three
--   invoice_id       invoice_payment: the existing invoice being paid. Capture-first purposes:
--                    NULL until the capture issues the invoice, then the issued invoice.
--   amount_minor     fixed server-side at creation; a capture for any other amount is refused
--   mode             live | test, derived from the gateway key by the caller; a capture in the
--                    other mode is refused, and the invoice is numbered from a series of the
--                    same mode
--   series_code      capture-first: the numbering series the invoice is issued from
--   invoice_spec     capture-first: what to put on the invoice (buyer, supply, lines). The amount
--                    the spec produces is checked equal to amount_minor at creation AND at capture
--   status           created (no gateway order yet) -> open (gateway order attached) -> paid | cancelled. Forward only:
--                    a cancelled or paid order never reopens. invoice_id, once set, never changes.
--
-- SQLSTATEs: PY030 order/catalog problem at creation, PY031 capture does not match the order
-- (amount, currency, tenant, platform, gateway, mode), PY032 capture for an order that is not
-- open (already paid / cancelled), PY033 capture reference conflict, PY034 quoted amount does not
-- match the invoice the spec produces, PY036 idempotency key reused with a different request.
CREATE TABLE pay_orders (
    id                  BIGSERIAL PRIMARY KEY,
    order_ref           TEXT NOT NULL UNIQUE,
    tenant_id           UUID NOT NULL,
    platform_code       VARCHAR(50) NOT NULL,
    idempotency_key     TEXT NOT NULL CHECK (btrim(idempotency_key) <> '' AND length(idempotency_key) <= 200),
    request_hash        TEXT NOT NULL,
    purpose             TEXT NOT NULL CHECK (purpose IN ('subscription_period', 'one_time_license', 'wallet_topup', 'invoice_payment')),
    catalog_ref         TEXT,
    invoice_id          BIGINT REFERENCES inv_invoices(id),
    amount_minor        BIGINT NOT NULL CHECK (amount_minor > 0),
    currency            TEXT NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    gateway_code        TEXT NOT NULL REFERENCES inv_gateways(code),
    mode                TEXT NOT NULL CHECK (mode IN ('live', 'test')),
    series_code         TEXT,
    invoice_spec        JSONB,
    status              TEXT NOT NULL DEFAULT 'created' CHECK (status IN ('created', 'open', 'paid', 'cancelled')),
    gateway_order_id    TEXT,
    gateway_create_lease_until TIMESTAMPTZ,       -- one caller at a time creates the gateway order (pay_order_begin_gateway_create)
    captured_payment_id BIGINT REFERENCES pay_captured_payments(id),
    payment_id          BIGINT REFERENCES inv_payments(id),
    paid_at             TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL,
    UNIQUE (tenant_id, platform_code, idempotency_key)
);
CREATE UNIQUE INDEX pay_orders_gateway_order ON pay_orders (gateway_code, gateway_order_id) WHERE gateway_order_id IS NOT NULL;
CREATE INDEX pay_orders_tenant ON pay_orders (tenant_id, platform_code, created_at);
