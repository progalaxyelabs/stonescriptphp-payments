-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Invoicing :: functions :: inv_resolve_gateway — split from 035_invoice_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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
-- 1. GATEWAY ROUTING  (data-driven; precedence invoice > customer > country)
-- =====================================================================
-- Resolve which rail an invoice settles through. resolved_by records WHY, so the
-- pay page and audit can explain the choice. No fallback guessing: an
-- unroutable invoice raises ER052 (never a silent default rail).
--
-- TENANT ISOLATION (ER067, added 2026-09-22): p_invoice_id alone is a bare
-- surrogate BIGINT with no tenant boundary of its own — inv_invoices carries
-- tenant_id/platform_code precisely so every caller who resolves/mutates an
-- invoice by id can be constrained to the invoice it actually owns. The
-- caller MUST supply the tenant it believes owns the invoice; a mismatch
-- raises ER067 rather than silently resolving/leaking another tenant's
-- routing/payment data. Internal callers within THIS package that already
-- hold the invoice row (inv_invoice_payability, inv_crm_chase_view) pass the
-- row's own tenant_id/platform_code straight through — never a caller-
-- supplied value re-derived some other way.

CREATE OR REPLACE FUNCTION inv_resolve_gateway(p_invoice_id BIGINT, p_tenant_id UUID, p_platform_code VARCHAR(50))
RETURNS TABLE (
    gateway_code        TEXT,
    display_name        TEXT,
    settlement_currency TEXT,
    checkout_endpoint   TEXT,
    resolved_by         TEXT   -- 'invoice_override' | 'customer_override' | 'country_rule'
) AS $$
DECLARE
    v_inv       inv_invoices;
    v_code      TEXT;
    v_by        TEXT;
BEGIN
    SELECT * INTO v_inv FROM inv_invoices WHERE id = p_invoice_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'invoice % does not exist', p_invoice_id USING ERRCODE = 'ER053';
    END IF;

    IF v_inv.tenant_id IS DISTINCT FROM p_tenant_id OR v_inv.platform_code IS DISTINCT FROM p_platform_code THEN
        RAISE EXCEPTION 'invoice % does not belong to tenant %/% — refusing to resolve a gateway for another tenant''s invoice.',
            p_invoice_id, p_tenant_id, p_platform_code USING ERRCODE = 'ER067';
    END IF;

    -- (a) per-invoice override wins
    IF v_inv.gateway_override_code IS NOT NULL THEN
        v_code := v_inv.gateway_override_code; v_by := 'invoice_override';
    ELSE
        -- (b) per-tenant override
        SELECT o.gateway_code INTO v_code FROM inv_customer_gateway_overrides o
         WHERE o.tenant_id = v_inv.tenant_id AND o.platform_code = v_inv.platform_code;
        IF v_code IS NOT NULL THEN
            v_by := 'customer_override';
        ELSE
            -- (c) country routing rule: specific country beats the export wildcard
            SELECT r.gateway_code INTO v_code
              FROM inv_gateway_routing_rules r
             WHERE r.is_active
               AND (r.match_country_code = v_inv.billing_country_code OR r.match_country_code IS NULL)
             ORDER BY (r.match_country_code IS NULL), r.priority   -- non-wildcard first, then lowest priority
             LIMIT 1;
            v_by := 'country_rule';
        END IF;
    END IF;

    IF v_code IS NULL THEN
        RAISE EXCEPTION 'no gateway route for invoice % (billing country "%"): no active routing rule matches and no override is set. Add a routing-rule row or an override.',
            p_invoice_id, v_inv.billing_country_code USING ERRCODE = 'ER052';
    END IF;

    RETURN QUERY
    SELECT gw.code, gw.display_name, gw.settlement_currency, gw.checkout_endpoint, v_by
      FROM inv_gateways gw
     WHERE gw.code = v_code AND gw.is_active;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'invoice % resolves to gateway "%", which is not a known active gateway.', p_invoice_id, v_code
            USING ERRCODE = 'ER058';
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;
