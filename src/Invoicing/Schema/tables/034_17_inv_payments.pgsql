-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Invoicing :: tables :: inv_payments — split from 034_invoice_persistence_tables.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: PERSISTED invoices + payments + gateway routing (DATA) +
--   status lifecycle set (DATA) + the CRM chase minimal-subset view.
--
-- This is the persistence layer that sits ON TOP of the pure GST tax-computation
-- engine (024-033). inv_compute_invoice() stays a pure calculator (STABLE, no
-- rows); inv_issue_invoice() (035) calls it and FREEZES the result into the
-- tables below. The charge side (subscription 022, wallet/overage 017/023,
-- passthrough 019, consumption 015/016) produces the amount; the GST engine adds
-- tax; this layer records the issued document, its payments, and how it settles.
--
-- ECOSYSTEM LAW honoured: every business VALUE is a DATA row, never a literal in
-- a function body — the gateways, the country->gateway routing rules, each
-- gateway's checkout endpoint, the legal status set, and the legal status
-- transitions are ALL rows here (035's functions carry only the FORMULA). Money
-- is INTEGER PAISA everywhere (024 law) — we deliberately DIVERGE from a reference
-- numeric(14,2) invoices.pgsql shape on TYPE while ALIGNING on shape/columns, because
-- the whole prototype is paisa-exact and never touches a float.
--
-- NO now()/CURRENT_DATE anywhere: every timestamp is an explicit caller param.
-- The "as-of-now" candidates for a later step-2 now() substitution are TAGGED
-- inline with the marker  [NOW-CANDIDATE]  (created_at columns and the state-
-- transition timestamps). Genuine business dates (issue_date, due_date, billing
-- period, a gateway's own captured_at) are NOT now-candidates and are so tagged.
--
-- New custom SQLSTATEs, continuing the ERxxx scheme (max in use before this file
-- was ER051; the spec's "after ER021" predates the 024-051 GST port):
--   ER052  no gateway route resolvable for the invoice's billing country   -> 400
--   ER053  invoice not found                                               -> 404
--   ER054  illegal invoice status transition                               -> 409
--   ER055  payment recorded against an already-paid invoice (dup guard)    -> 409
--   ER056  invoice is not payable from its current status                  -> 409
--   ER057  payment amount/currency does not match the invoice              -> 400
--   ER058  unknown or inactive gateway (override target or payment rail)   -> 400
--   ER059  invalid invoice status value (not a modelled status)            -> 400
--   ER060  billing_country_code is required and must be a 2-letter code    -> 400
--   ER061  invalid payment status value (expected 'success' | 'failed')    -> 400
--   ER066  gateway transaction already recorded against a DIFFERENT invoice -> 409
--   ER067  invoice does not belong to the caller's tenant/platform (isolation) -> 403
--   ER068  tax scheme resolved for the billing country has no wired compute engine -> 400
--   ER069  supply_type is not one of 'domestic' | 'export_lut' | 'export_with_igst' -> 400
--   ER070  export invoice with no seller GSTIN (cannot assume an India-seller export scheme) -> 400
--
-- ER067 LOAD-BEARING INVARIANT (dev-critique finding, 2026-09-22): the
-- `v_inv.tenant_id IS DISTINCT FROM p_tenant_id` checks in
-- inv_resolve_gateway/inv_invoice_payability/inv_record_payment/
-- inv_transition_invoice_status (035) and central_record_payment (037) rely
-- on inv_invoices.tenant_id/platform_code (and central_minimal_invoices'
-- copies) being NOT NULL — true today (see the column definitions below and
-- 037_15) — so a NULL-vs-NULL "not distinct" false-match can never occur on
-- the row side. If either column is ever made nullable, these checks MUST
-- be revisited.

-- =====================================================================
-- 7. PAYMENTS  (idempotent, single-success)
-- =====================================================================

CREATE TABLE inv_payments (
    id              BIGSERIAL PRIMARY KEY,
    invoice_id      BIGINT NOT NULL REFERENCES inv_invoices(id),
    gateway_code    TEXT NOT NULL REFERENCES inv_gateways(code),
    gateway_txn_ref TEXT NOT NULL,                  -- the gateway's own payment/txn id
    amount_minor    BIGINT NOT NULL,                -- paisa, in `currency`
    currency        TEXT NOT NULL,
    status          TEXT NOT NULL,                  -- 'success' | 'failed' (app-validated enum)
    captured_at     TIMESTAMPTZ NOT NULL,           -- the gateway's capture time (BUSINESS INPUT from the gateway, NOT our now)
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),           -- [NOW-CANDIDATE]
    created_by      TEXT NOT NULL
);
-- SINGLE-SUCCESS GUARANTEE (the real, concurrency-proof duplicate-payment guard):
-- at most ONE successful payment can ever exist per invoice. Two racing success
-- inserts cannot both win — one gets a unique_violation.
CREATE UNIQUE INDEX inv_payments_one_success_per_invoice
    ON inv_payments (invoice_id) WHERE status = 'success';
-- IDEMPOTENCY: the same gateway txn can never be recorded twice (a webhook
-- retry replays the SAME ref -> inv_record_payment returns the existing row).
CREATE UNIQUE INDEX inv_payments_gateway_txn_unique
    ON inv_payments (gateway_code, gateway_txn_ref);
CREATE INDEX inv_payments_invoice ON inv_payments (invoice_id);
