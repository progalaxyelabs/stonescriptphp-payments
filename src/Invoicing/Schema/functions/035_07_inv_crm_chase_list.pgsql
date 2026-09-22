-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Invoicing :: functions :: inv_crm_chase_list — split from 035_invoice_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

-- Same minimal subset + the is_overdue flag against a caller-supplied instant.
-- p_as_of is [NOW-CANDIDATE] (the "today" the chase is run for). Overdue = a due
-- invoice whose due_date has passed as of p_as_of. This drives the nudge order.

CREATE OR REPLACE FUNCTION inv_crm_chase_list(p_as_of TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (
    invoice_id        BIGINT,
    invoice_number    TEXT,
    tenant_id         UUID,
    platform_code     VARCHAR(50),
    amount_minor      BIGINT,
    currency          TEXT,
    due_date          TIMESTAMPTZ,
    status            TEXT,
    gateway_code      TEXT,
    is_overdue        BOOLEAN
) AS $$
    SELECT
        v.invoice_id, v.invoice_number, v.tenant_id, v.platform_code,
        v.amount_minor, v.currency, v.due_date, v.status, v.gateway_code,
        (v.status = 'due' AND v.due_date IS NOT NULL AND v.due_date < p_as_of) AS is_overdue
    FROM inv_crm_chase_view v
    ORDER BY (v.status = 'due' AND v.due_date IS NOT NULL AND v.due_date < p_as_of) DESC,
             v.due_date NULLS LAST, v.invoice_id;
$$ LANGUAGE sql STABLE;
