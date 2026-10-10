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
    v_series_id BIGINT;
    v_number TEXT;
    v_mode TEXT;
    v_series_code TEXT;
    v_alloc RECORD;
    v_new_number TEXT;
    v_new_fy TEXT;
    v_new_seq BIGINT;
BEGIN
    SELECT status, tenant_id, platform_code, series_id, invoice_number, mode
      INTO v_from, v_inv_tenant_id, v_inv_platform_code, v_series_id, v_number, v_mode
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

    -- L7.1: a series invoice opened as a draft is numbered on the draft -> issued
    -- edge, in this transaction, so an abandoned draft never burns a serial. The
    -- document date (hence the financial year) is the moment of issue, p_at.
    IF p_to_status = 'issued' AND v_series_id IS NOT NULL AND v_number IS NULL THEN
        PERFORM _inv_assert_schema_current();
        SELECT series_code INTO v_series_code FROM inv_series WHERE id = v_series_id;
        -- The tax was computed when the draft was created. Do not number a document whose basis moved
        -- since: the seller's registration / GSTIN / state, or a GST rate that is no longer an allowed slab.
        IF EXISTS (SELECT 1 FROM inv_invoices d JOIN inv_series s ON s.id = d.series_id JOIN inv_issuers i ON i.id = s.issuer_id
                    WHERE d.id = p_invoice_id
                      AND (d.seller_registration_status IS DISTINCT FROM i.registration_status
                           OR d.seller_gstin IS DISTINCT FROM i.gstin
                           OR (i.state_code IS NOT NULL AND d.seller_state_code IS DISTINCT FROM i.state_code))) THEN
            RAISE EXCEPTION 'invoice %: the seller''s registration, GSTIN or state changed since this draft was computed; its tax would be wrong. Cancel the draft and create a new one.', p_invoice_id
                USING ERRCODE = 'PY015';
        END IF;
        IF EXISTS (SELECT 1 FROM inv_invoice_lines l WHERE l.invoice_id = p_invoice_id
                    AND NOT EXISTS (SELECT 1 FROM inv_gst_rate_slabs r WHERE r.rate = l.gst_rate)) THEN
            RAISE EXCEPTION 'invoice %: a line carries a GST rate that is no longer an allowed slab; its tax would be wrong. Cancel the draft and create a new one.', p_invoice_id
                USING ERRCODE = 'PY015';
        END IF;
        PERFORM set_config('pay.issuing', 'on', true);
        SELECT * INTO v_alloc FROM _inv_series_allocate(v_series_code, p_at, v_mode);
        v_new_number := v_alloc.o_invoice_number;
        v_new_fy := v_alloc.o_fy_label;
        v_new_seq := v_alloc.o_number_seq;
        PERFORM set_config('pay.issuing', 'off', true);
    END IF;

    UPDATE inv_invoices SET
        status       = p_to_status,
        invoice_number = COALESCE(v_new_number, invoice_number),
        fy_label       = COALESCE(v_new_fy, fy_label),
        number_seq     = COALESCE(v_new_seq, number_seq),
        issue_date     = CASE WHEN v_new_number IS NOT NULL
                              THEN (p_at AT TIME ZONE 'Asia/Kolkata')::DATE ELSE issue_date END,
        issued_at    = CASE WHEN p_to_status = 'issued'    THEN p_at ELSE issued_at    END,
        voided_at    = CASE WHEN p_to_status = 'void'      THEN p_at ELSE voided_at    END,
        cancelled_at = CASE WHEN p_to_status = 'cancelled' THEN p_at ELSE cancelled_at END
    WHERE id = p_invoice_id;

    RETURN p_to_status;
END;
$$ LANGUAGE plpgsql;
