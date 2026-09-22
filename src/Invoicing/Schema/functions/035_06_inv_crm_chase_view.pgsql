-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Invoicing :: functions :: inv_crm_chase_view — split from 035_invoice_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: persisted-invoice FUNCTIONS — issue, guarded status
--   lifecycle, data-driven gateway routing, idempotent single-success payments,
--   the checkout/already-paid guard, and the CRM chase projections.
--
-- Every FORMULA is here; every VALUE it needs is a DATA row from 034 (gateways,
-- routing rules, the status set, the legal transitions). The only literals in
-- these bodies are enum/mode LABELS used as control tokens ('paid','success',
-- 'INR', ...) — structural identifiers exactly like the 'intrastate'/'no_tax'
-- mode tokens the tax engine (030) branches on, NOT business numbers. There is
-- not a single bare price / rate / duration / count constant in any body.
-- Integer paisa throughout. NO now()/CURRENT_DATE — see [NOW-CANDIDATE] tags.

-- =====================================================================
-- 6. CRM CHASE MINIMAL-SUBSET PROJECTIONS
-- =====================================================================
-- The static minimal record (see [MINIMAL] tags in 034): who owes, on which
-- platform, how much, currency, due date, status, and settling gateway. No GST
-- internals. Only unpaid, chaseable invoices appear.
--
-- NO display name here (no "customer_name"/"tenant_name" column, no join to a
-- local identity fixture): tenant_id/platform_code are opaque, resolved-from-
-- auth values with no cross-DB FK (see the identity-column note on
-- inv_invoices). The CRM/dunning UI resolves a human-readable tenant name by
-- calling the auth/tenant service with tenant_id, exactly like every other
-- ecosystem consumer of an opaque tenant_id — it is never re-derived here.

CREATE OR REPLACE VIEW inv_crm_chase_view AS
SELECT
    i.id                AS invoice_id,
    i.invoice_number,
    i.tenant_id,
    i.platform_code,
    i.gross_total_minor AS amount_minor,
    i.currency,
    i.due_date,
    i.status,
    g.gateway_code,
    g.checkout_endpoint
FROM inv_invoices i
LEFT JOIN LATERAL (SELECT * FROM inv_resolve_gateway(i.id, i.tenant_id, i.platform_code)) g ON TRUE
WHERE i.status IN ('issued', 'due');
