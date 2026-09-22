-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Invoicing :: functions :: inv_issue_invoice — split from 035_invoice_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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
-- 2. ISSUE AN INVOICE  (calls the pure tax engine, then freezes the result)
-- =====================================================================
-- Takes the SAME party/line/currency inputs as inv_compute_invoice (030) PLUS
-- the persistence metadata, computes the GST document, and writes inv_invoices +
-- inv_invoice_lines. Returns the new invoice id. p_initial_status must be a
-- non-payable, non-terminal starting state ('draft' or 'issued').
--
-- TAX SCHEME DISPATCH (wired 2026-09-22, ER068): billing_country_code now
-- resolves its tax REGIME through inv_resolve_tax_scheme (033) — the same
-- JOIN-on-country DATA pattern inv_resolve_gateway already uses for payment
-- routing — instead of unconditionally calling the India GST engine
-- (inv_compute_invoice) for every country. Before this wiring, ANY 2-letter
-- billing_country_code (not just 'IN') silently ran through the India engine
-- with no country check at all — a real bug this closes. Today
-- inv_tax_scheme seeds exactly one active row ('IN' -> 'in_gst'), so
-- behaviour for India is unchanged; a country with no active inv_tax_scheme
-- row now fails loud at ER065 (via the resolver) instead of silently getting
-- an India GST computation that was never valid for it. Adding a new country
-- means: (1) implement its compute engine, (2) add ONE CASE branch below
-- calling it, (3) INSERT its inv_tax_scheme row — never a dynamic/EXECUTEd
-- function-name dispatch.

CREATE OR REPLACE FUNCTION inv_issue_invoice(
    p_invoice_number        TEXT,
    p_tenant_id             UUID,
    p_platform_code         VARCHAR(50),
    p_charge_source         TEXT,
    p_charge_ref            TEXT,
    p_period_start          TIMESTAMPTZ,    -- BUSINESS INPUT
    p_period_end            TIMESTAMPTZ,    -- BUSINESS INPUT
    p_due_date              TIMESTAMPTZ,    -- BUSINESS INPUT (billing layer computes it, e.g. period_end + net terms)
    p_billing_country_code  TEXT,
    p_billing_state         TEXT,           -- frozen snapshot at issue
    p_seller                inv_party_input,
    p_buyer                 inv_party_input,
    p_supply_type           TEXT,
    p_document_type         TEXT,
    p_price_is_inclusive    BOOLEAN,
    p_round_off             BOOLEAN,
    p_currency              TEXT,
    p_fx_rate               TEXT,
    p_amount_inr            TEXT,
    p_issue_date            TIMESTAMPTZ,    -- BUSINESS INPUT: the invoice document date
    p_lines                 inv_line_input[],
    p_gateway_override_code TEXT,           -- NULL => resolve by rule at pay time
    p_created_by            TEXT,
    p_created_at            TIMESTAMPTZ DEFAULT now(),    -- [NOW-CANDIDATE] trailing+defaulted: prod omits, tests pass explicit
    p_initial_status        TEXT DEFAULT 'issued'
) RETURNS BIGINT AS $$
DECLARE
    v_ci     inv_computed_invoice;
    v_cl     inv_computed_line;
    v_id     BIGINT;
    v_no     INTEGER := 0;
    v_issued TIMESTAMPTZ;
    v_scheme_type TEXT;
    v_tax_country_code TEXT;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    IF p_billing_country_code IS NULL OR p_billing_country_code !~ '^[A-Za-z]{2}$' THEN
        RAISE EXCEPTION 'billing_country_code "%" must be a 2-letter ISO country code (it routes the gateway).', p_billing_country_code
            USING ERRCODE = 'ER060';
    END IF;

    IF p_initial_status IS NULL OR p_initial_status NOT IN ('draft', 'issued') THEN
        RAISE EXCEPTION 'an invoice may only be created in ''draft'' or ''issued'' status (got "%").', p_initial_status
            USING ERRCODE = 'ER059';
    END IF;

    IF p_gateway_override_code IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM inv_gateways WHERE code = p_gateway_override_code AND is_active) THEN
        RAISE EXCEPTION 'gateway_override_code "%" is not a known active gateway.', p_gateway_override_code
            USING ERRCODE = 'ER058';
    END IF;

    -- ER069 (added 2026-09-22, dev-critique finding): p_supply_type was
    -- previously validated nowhere as an explicit enum — inv_compute_invoice
    -- (030) treats anything NOT EXACTLY 'export_lut'/'export_with_igst' as
    -- domestic (its own implicit ELSE branch), while the tax-scheme dispatch
    -- just below treats anything NOT EXACTLY 'domestic' as export. A typo
    -- (e.g. 'Domestic', 'export') would silently be classified DIFFERENTLY
    -- by the two checks within the SAME call — reject it here, once, before
    -- either classification runs, rather than let it diverge.
    IF p_supply_type NOT IN ('domestic', 'export_lut', 'export_with_igst') THEN
        RAISE EXCEPTION 'supply_type "%" is invalid (expected ''domestic'', ''export_lut'', or ''export_with_igst'').', p_supply_type
            USING ERRCODE = 'ER069';
    END IF;

    -- resolve which tax regime governs this INVOICE (DATA + JOIN, never a
    -- dynamic function-name dispatch — see inv_resolve_tax_scheme, 033).
    --
    -- Which COUNTRY drives that resolution depends on supply_type, and is
    -- deliberately NOT always billing_country_code:
    --   - 'domestic': the buyer and seller share one jurisdiction, so the
    --     buyer's billing_country_code IS the invoice's tax jurisdiction —
    --     a domestic invoice billed to an unmapped country is a real
    --     config/data error (ER065), never silently run through India GST.
    --   - 'export_lut' / 'export_with_igst': these are, BY DEFINITION,
    --     cross-border — the buyer's billing_country_code is deliberately
    --     NOT the seller's jurisdiction, so it is never a valid tax-scheme
    --     lookup key here. An Indian-registered seller's export invoice
    --     stays governed by India GST law regardless of which foreign
    --     country the buyer bills from (that is exactly what LUT/IGST
    --     export treatment means). This package implements exactly one
    --     seller jurisdiction today (India), so exports resolve via 'IN'
    --     until a per-tenant seller/home-country field exists to look this
    --     up as DATA too (tracked as a known follow-on, not a placeholder
    --     value invented here) — it is STILL resolved through
    --     inv_resolve_tax_scheme (never bypassed), so a future multi-seller-
    --     country package only needs to change this one lookup, not the
    --     CASE dispatch below.
    -- ER070 (added 2026-09-22, dev-critique finding): inv_party_input has no
    -- seller-country field to check, so nothing structurally proves the
    -- 'IN' export shortcut above is actually correct for THIS invoice's
    -- seller — assert the one signal this package DOES have (a well-formed
    -- Indian GSTIN on the seller) before taking it, rather than defaulting
    -- silently for every export invoice regardless of who the seller is.
    -- inv_compute_invoice (030) still independently validates the seller's
    -- GSTIN shape/registration-status further down for the actual GST math
    -- — this is an EARLIER, narrower check specifically gating the tax-
    -- scheme SHORTCUT, not a replacement for that validation.
    IF p_supply_type <> 'domestic' AND (p_seller.gstin IS NULL OR btrim(p_seller.gstin) = '') THEN
        RAISE EXCEPTION 'an export invoice (supply_type "%") requires the seller to carry a GSTIN — this package only implements an India-seller export tax scheme (LUT/IGST) and refuses to assume it without that evidence.', p_supply_type
            USING ERRCODE = 'ER070';
    END IF;

    v_tax_country_code := CASE WHEN p_supply_type = 'domestic' THEN p_billing_country_code ELSE 'IN' END;
    v_scheme_type := inv_resolve_tax_scheme(v_tax_country_code);

    -- CASE-dispatch to the ONE hardcoded, statically-named engine per scheme
    -- (never EXECUTE/dynamic dispatch by constructed name). Today only
    -- 'in_gst' has a wired engine; every other scheme_type value is a
    -- config/data error until this package ships that country's engine.
    CASE v_scheme_type
        WHEN 'in_gst' THEN
            v_ci := inv_compute_invoice(
                p_seller, p_buyer, p_supply_type, p_document_type, p_price_is_inclusive, p_round_off,
                p_currency, p_fx_rate, p_amount_inr, p_invoice_number, p_issue_date, p_lines);
        ELSE
            RAISE EXCEPTION 'tax scheme "%" (resolved for billing country "%") has no wired compute engine in this package — only ''in_gst'' is implemented today.',
                v_scheme_type, upper(v_tax_country_code) USING ERRCODE = 'ER068';
    END CASE;

    -- system issue stamp: set only when we open directly in 'issued'
    v_issued := CASE WHEN p_initial_status = 'issued' THEN p_created_at ELSE NULL END;

    INSERT INTO inv_invoices (
        invoice_number, tenant_id, platform_code, charge_source, charge_ref,
        period_start, period_end,
        document_type, tax_treatment, place_of_supply_code, hsn_sac,
        taxable_value_minor, cgst_minor, sgst_minor, igst_minor, round_off_minor, gross_total_minor,
        currency, fx_rate, amount_inr_minor,
        billing_country_code, billing_state_snapshot,
        gateway_override_code,
        status, due_date, issued_at, created_at, created_by)
    VALUES (
        v_ci.invoice_number, p_tenant_id, p_platform_code, p_charge_source, p_charge_ref,
        p_period_start, p_period_end,
        v_ci.document_type, v_ci.tax_treatment, v_ci.place_of_supply_code, (v_ci.lines[1]).hsn_sac,
        v_ci.taxable_value_minor, v_ci.cgst_minor, v_ci.sgst_minor, v_ci.igst_minor, v_ci.round_off_minor, v_ci.gross_total_minor,
        v_ci.currency, v_ci.fx_rate, v_ci.amount_inr_minor,
        upper(p_billing_country_code), p_billing_state,
        p_gateway_override_code,
        p_initial_status, p_due_date, v_issued, p_created_at, p_created_by)
    RETURNING id INTO v_id;

    FOREACH v_cl IN ARRAY v_ci.lines LOOP
        v_no := v_no + 1;
        INSERT INTO inv_invoice_lines (
            invoice_id, line_no, description, hsn_sac, quantity_milli, unit_price_minor, gst_rate,
            taxable_value_minor, cgst_minor, sgst_minor, igst_minor, line_total_minor)
        VALUES (
            v_id, v_no, v_cl.description, v_cl.hsn_sac, v_cl.quantity_milli, v_cl.unit_price_minor, v_cl.gst_rate,
            v_cl.taxable_value_minor, v_cl.cgst_minor, v_cl.sgst_minor, v_cl.igst_minor, v_cl.line_total_minor);
    END LOOP;

    RETURN v_id;
END;
$$ LANGUAGE plpgsql;
