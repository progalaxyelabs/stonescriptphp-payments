-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Invoicing :: functions :: inv_transition_invoice_status — split from 035_invoice_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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
-- 3. GUARDED STATUS LIFECYCLE  (edges are DATA; no silent no-op)
-- =====================================================================
-- Move an invoice from its current status to p_to_status. The edge must exist in
-- inv_invoice_status_transitions or it is ER054. 'paid' is NEVER reached this
-- way — it is reached ONLY by recording a successful payment (inv_record_payment),
-- which guarantees the due->paid edge fires exactly once against exactly one
-- successful payment. p_at is [NOW-CANDIDATE] (the moment the transition happens).
--
-- TENANT ISOLATION (ER067, added 2026-09-22): see inv_resolve_gateway's note
-- above. p_tenant_id/p_platform_code are REQUIRED — this function mutates
-- invoice status (issued/void/cancelled/due) and must not let a caller
-- transition another tenant's invoice.

CREATE OR REPLACE FUNCTION inv_transition_invoice_status(
    p_invoice_id BIGINT, p_tenant_id UUID, p_platform_code VARCHAR(50), p_to_status TEXT, p_by TEXT, p_at TIMESTAMPTZ DEFAULT now()  -- p_at [NOW-CANDIDATE] trailing+defaulted
) RETURNS TEXT AS $$
DECLARE
    v_from TEXT;
    v_inv_tenant_id UUID;
    v_inv_platform_code VARCHAR(50);
BEGIN
    SELECT status, tenant_id, platform_code INTO v_from, v_inv_tenant_id, v_inv_platform_code
      FROM inv_invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'invoice % does not exist', p_invoice_id USING ERRCODE = 'ER053';
    END IF;

    IF v_inv_tenant_id IS DISTINCT FROM p_tenant_id OR v_inv_platform_code IS DISTINCT FROM p_platform_code THEN
        RAISE EXCEPTION 'invoice % does not belong to tenant %/% — refusing to transition another tenant''s invoice.',
            p_invoice_id, p_tenant_id, p_platform_code USING ERRCODE = 'ER067';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM inv_invoice_statuses WHERE status = p_to_status) THEN
        RAISE EXCEPTION 'invalid target status "%".', p_to_status USING ERRCODE = 'ER059';
    END IF;

    IF p_to_status = 'paid' THEN
        RAISE EXCEPTION 'an invoice is marked paid ONLY by recording a successful payment (inv_record_payment), never by a direct status transition.'
            USING ERRCODE = 'ER056';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM inv_invoice_status_transitions t
                    WHERE t.from_status = v_from AND t.to_status = p_to_status) THEN
        RAISE EXCEPTION 'illegal invoice status transition % -> % (invoice %).', v_from, p_to_status, p_invoice_id
            USING ERRCODE = 'ER054';
    END IF;

    UPDATE inv_invoices SET
        status       = p_to_status,
        issued_at    = CASE WHEN p_to_status = 'issued'    THEN p_at ELSE issued_at    END,
        voided_at    = CASE WHEN p_to_status = 'void'      THEN p_at ELSE voided_at    END,
        cancelled_at = CASE WHEN p_to_status = 'cancelled' THEN p_at ELSE cancelled_at END
    WHERE id = p_invoice_id;

    RETURN p_to_status;
END;
$$ LANGUAGE plpgsql;
