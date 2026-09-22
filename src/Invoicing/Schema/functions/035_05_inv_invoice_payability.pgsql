-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Invoicing :: functions :: inv_invoice_payability — split from 035_invoice_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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
-- 5. CHECKOUT / ALREADY-PAID GUARD  (the SQL authority behind the pay page)
-- =====================================================================
-- Given an invoice, say whether it is payable and, when it is, hand back the
-- gateway checkout target so the central pay page can render the button. When it
-- is NOT payable the reason tells the page to show "already paid, no button"
-- (reason 'already_paid') or that the invoice is not in a payable state.
--
-- TENANT ISOLATION (ER067, added 2026-09-22): see inv_resolve_gateway's note
-- above — p_invoice_id alone has no tenant boundary; the caller (the "is this
-- payable" page/API, which knows the caller's tenant from their auth session)
-- MUST supply the tenant it believes owns the invoice, checked before any
-- amount/gateway/checkout detail is returned. A mismatch raises ER067 — this
-- is the one function every checkout/pay-page code path calls FIRST, so this
-- is the primary place a cross-tenant read is blocked.

CREATE OR REPLACE FUNCTION inv_invoice_payability(p_invoice_id BIGINT, p_tenant_id UUID, p_platform_code VARCHAR(50))
RETURNS TABLE (
    invoice_id        BIGINT,
    is_payable        BOOLEAN,
    status            TEXT,
    reason            TEXT,          -- 'payable' | 'already_paid' | 'not_payable_status'
    gross_total_minor BIGINT,
    currency          TEXT,
    gateway_code      TEXT,          -- NULL unless payable
    checkout_endpoint TEXT           -- NULL unless payable
) AS $$
DECLARE
    v_inv        inv_invoices;
    v_has_edge   BOOLEAN;
    v_has_success BOOLEAN;
    v_reason     TEXT;
    v_payable    BOOLEAN;
    v_gw         RECORD;
BEGIN
    SELECT * INTO v_inv FROM inv_invoices WHERE id = p_invoice_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'invoice % does not exist', p_invoice_id USING ERRCODE = 'ER053';
    END IF;

    IF v_inv.tenant_id IS DISTINCT FROM p_tenant_id OR v_inv.platform_code IS DISTINCT FROM p_platform_code THEN
        RAISE EXCEPTION 'invoice % does not belong to tenant %/% — refusing to disclose payability for another tenant''s invoice.',
            p_invoice_id, p_tenant_id, p_platform_code USING ERRCODE = 'ER067';
    END IF;

    v_has_success := EXISTS (SELECT 1 FROM inv_payments p WHERE p.invoice_id = p_invoice_id AND p.status = 'success');
    v_has_edge    := EXISTS (SELECT 1 FROM inv_invoice_status_transitions t WHERE t.from_status = v_inv.status AND t.to_status = 'paid');

    IF v_inv.status = 'paid' OR v_has_success THEN
        v_payable := false; v_reason := 'already_paid';
    ELSIF v_has_edge THEN
        v_payable := true;  v_reason := 'payable';
    ELSE
        v_payable := false; v_reason := 'not_payable_status';
    END IF;

    IF v_payable THEN
        SELECT g.gateway_code, g.checkout_endpoint INTO v_gw FROM inv_resolve_gateway(p_invoice_id, v_inv.tenant_id, v_inv.platform_code) g;
    END IF;

    RETURN QUERY SELECT
        p_invoice_id, v_payable, v_inv.status, v_reason,
        v_inv.gross_total_minor, v_inv.currency,
        (CASE WHEN v_payable THEN v_gw.gateway_code END),
        (CASE WHEN v_payable THEN v_gw.checkout_endpoint END);
END;
$$ LANGUAGE plpgsql STABLE;
