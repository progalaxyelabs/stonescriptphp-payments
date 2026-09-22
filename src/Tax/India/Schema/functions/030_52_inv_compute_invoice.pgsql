-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_compute_invoice — split from Gst/030_gst_tax_engine.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: the GST tax-computation engine — PORT of `Lib/TaxEngine.php`
--   (document-type/title/legend derivation, place-of-supply resolution,
--    CGST/SGST/IGST split, inclusive-price reverse computation + MRP invariant,
--    multi-line totals, optional nearest-unit round-off) and the full RESULT
--    ASSEMBLY the PHP render projection used to build (SQL-first design:
--    the function returns the COMPLETE computed document, incl. canonical 2dp
--    decimal renders; PHP is pure transport/packaging).
--
-- ALL arithmetic is integer paisa via 024. UNIT-scale literals only, annotated:
-- 100 (paisa/rupee), 1000 (milli-units/unit), 10000 (rate ten-thousandths),
-- 2 (a tax amount halved into two equal heads). Every business VALUE is DATA (026).
--
--   ER043 seller.registration_status required        ER044 document_type not issuable this phase
--   ER045 unlawful document_type for seller status   ER046 non-zero gst_rate on an exempt line
--   ER047 seller GST state unresolvable              ER048 registered buyer GST state unresolvable
--   ER049 round_off outside RndOffAmt range          ER050 unknown internal tax-split mode
--
-- NO now()/CURRENT_DATE: p_issue_date is a GENUINE BUSINESS INPUT (the invoice
-- date), always caller-supplied — NOT a "now" candidate. (This engine allocates
-- no counter and inserts no rows — Phase 1 has no persistence, matching the PHP.)

-- The whole-invoice engine. Validates parties/lines/header, derives the
-- document, resolves place of supply, computes every line + totals + optional
-- round-off, and returns the COMPLETE computed document.

CREATE OR REPLACE FUNCTION inv_compute_invoice(
    p_seller             inv_party_input,
    p_buyer              inv_party_input,
    p_supply_type        TEXT,
    p_document_type      TEXT,
    p_price_is_inclusive BOOLEAN,
    p_round_off          BOOLEAN,
    p_currency           TEXT,
    p_fx_rate            TEXT,
    p_amount_inr         TEXT,
    p_invoice_number     TEXT,
    p_issue_date         TIMESTAMPTZ,   -- BUSINESS INPUT: the invoice date (not a "now" candidate)
    p_lines              inv_line_input[]
) RETURNS inv_computed_invoice AS $$
DECLARE
    v_line        inv_line_input;
    v_cline       inv_computed_line;
    v_clines      inv_computed_line[] := ARRAY[]::inv_computed_line[];
    v_doc_type    TEXT;
    v_taxed       BOOLEAN;
    v_seller_code TEXT;
    v_buyer_code  TEXT;
    v_buyer_gstin BOOLEAN;
    v_mode        TEXT;
    v_pos_code    TEXT;
    v_treatment   TEXT;
    v_tax_t       BIGINT := 0;   -- taxable total
    v_cgst_t      BIGINT;
    v_sgst_t      BIGINT;
    v_igst_t      BIGINT;
    v_gross       BIGINT;
    v_round_off   BIGINT := NULL;
    v_nearest     BIGINT;
    v_max_ro      BIGINT;
    res           inv_computed_invoice;
BEGIN
    -- 1. Party construction-time validation (PHP PartyInput constructors).
    PERFORM inv_gst_validate_party(p_seller.role, p_seller.registration_status, p_seller.gstin);
    PERFORM inv_gst_validate_party(p_buyer.role,  p_buyer.registration_status,  p_buyer.gstin);

    -- 2. Line construction-time validation (PHP InvoiceLineInput constructors).
    FOREACH v_line IN ARRAY p_lines LOOP
        PERFORM inv_gst_validate_line(v_line.description, v_line.hsn_sac, v_line.quantity,
            v_line.unit_price, v_line.gst_rate, COALESCE(v_line.line_discount, '0'), v_line.allow_unlisted_rate);
    END LOOP;

    -- 3. Invoice-header validation (PHP InvoiceInput constructor).
    PERFORM inv_gst_validate_invoice_header(p_currency, p_fx_rate, p_amount_inr,
        p_seller.role, p_buyer.role, COALESCE(array_length(p_lines, 1), 0));
    IF p_invoice_number IS NOT NULL THEN
        PERFORM inv_number_assert_lawful(p_invoice_number);
    END IF;

    -- 4. Engine (TaxEngine::compute).
    IF p_seller.registration_status IS NULL THEN
        RAISE EXCEPTION 'seller.registration_status is required — it decides which document_type may be lawfully issued.'
            USING ERRCODE = 'ER043';
    END IF;

    -- derive document_type
    IF p_document_type IS NULL THEN
        v_doc_type := CASE WHEN p_seller.registration_status = 'regular' THEN 'tax_invoice' ELSE 'bill_of_supply' END;
    ELSIF p_document_type IN ('credit_note', 'receipt') THEN
        RAISE EXCEPTION 'document_type "%" is modelled but not issuable in this phase of the engine.', p_document_type
            USING ERRCODE = 'ER044';
    ELSIF p_document_type = 'tax_invoice' AND p_seller.registration_status <> 'regular' THEN
        RAISE EXCEPTION 'A "%" seller may never be issued a tax_invoice — only a bill_of_supply.', p_seller.registration_status
            USING ERRCODE = 'ER045';
    ELSE
        v_doc_type := p_document_type;
    END IF;
    v_taxed := v_doc_type <> 'bill_of_supply';

    -- zero-rate assertions (reject, never substitute)
    IF NOT v_taxed THEN
        FOREACH v_line IN ARRAY p_lines LOOP
            IF v_line.gst_rate <> 0 THEN
                RAISE EXCEPTION 'gst_rate must be 0 on every line when document_type is bill_of_supply — got % on "%".',
                    v_line.gst_rate, v_line.description USING ERRCODE = 'ER046';
            END IF;
        END LOOP;
    END IF;
    IF p_supply_type = 'export_lut' THEN
        FOREACH v_line IN ARRAY p_lines LOOP
            IF v_line.gst_rate <> 0 THEN
                RAISE EXCEPTION 'gst_rate must be 0 on every line when supply_type is export_lut — got % on "%".',
                    v_line.gst_rate, v_line.description USING ERRCODE = 'ER046';
            END IF;
        END LOOP;
    END IF;

    -- resolve place of supply + internal split mode (TaxEngine::resolveMode)
    v_seller_code := inv_gst_resolve_party_state_code(p_seller.gstin, p_seller.state_code, p_seller.address_state);
    v_buyer_code  := inv_gst_resolve_party_state_code(p_buyer.gstin,  p_buyer.state_code,  p_buyer.address_state);
    v_buyer_gstin := p_buyer.gstin IS NOT NULL AND btrim(p_buyer.gstin) <> '';

    IF NOT v_taxed THEN
        v_mode := 'no_tax'; v_pos_code := v_buyer_code; v_treatment := 'no_tax';
    ELSIF p_supply_type = 'export_lut' THEN
        v_mode := 'export_lut'; v_pos_code := v_buyer_code; v_treatment := 'export_lut';
    ELSIF p_supply_type = 'export_with_igst' THEN
        v_mode := 'interstate'; v_pos_code := v_buyer_code; v_treatment := 'export_with_igst';
    ELSE
        -- domestic
        IF v_seller_code IS NULL THEN
            RAISE EXCEPTION 'The seller''s GST state cannot be resolved — place of supply cannot be determined. This is never guessed.'
                USING ERRCODE = 'ER047';
        END IF;
        IF v_buyer_code IS NULL THEN
            IF v_buyer_gstin THEN
                RAISE EXCEPTION 'The buyer''s GST state cannot be resolved and the buyer carries a GSTIN (a registered recipient). Place of supply for a registered recipient must be known.'
                    USING ERRCODE = 'ER048';
            END IF;
            -- unregistered buyer + no address on record -> destination defaults
            -- to the SUPPLIER's own location (treated as intra-region).
            v_mode := 'intrastate'; v_pos_code := v_seller_code; v_treatment := 'intrastate';
        ELSIF v_seller_code = v_buyer_code THEN
            v_mode := 'intrastate'; v_pos_code := v_buyer_code; v_treatment := 'intrastate';
        ELSE
            v_mode := 'interstate'; v_pos_code := v_buyer_code; v_treatment := 'interstate';
        END IF;
    END IF;

    -- compute lines + totals
    FOREACH v_line IN ARRAY p_lines LOOP
        v_cline := inv_gst_compute_line(v_line, v_mode, p_price_is_inclusive);
        v_clines := array_append(v_clines, v_cline);
        v_tax_t := v_tax_t + v_cline.taxable_value_minor;
    END LOOP;

    IF v_mode = 'no_tax' THEN
        v_cgst_t := NULL; v_sgst_t := NULL; v_igst_t := NULL;
        v_gross := v_tax_t;
    ELSE
        SELECT COALESCE(SUM(COALESCE(l.cgst_minor,0)),0),
               COALESCE(SUM(COALESCE(l.sgst_minor,0)),0),
               COALESCE(SUM(COALESCE(l.igst_minor,0)),0)
          INTO v_cgst_t, v_sgst_t, v_igst_t
          FROM unnest(v_clines) l;
        v_gross := v_tax_t + v_cgst_t + v_sgst_t + v_igst_t;
    END IF;

    -- optional nearest-rupee round-off of the TOTAL only
    IF p_round_off THEN
        v_nearest := inv_money_half_up_divide(v_gross, 100) * 100;  -- 100 = paisa/rupee
        v_round_off := v_nearest - v_gross;
        v_max_ro := inv_gst_config_int('round_off_max_minor_units');
        IF abs(v_round_off) >= v_max_ro THEN
            RAISE EXCEPTION 'round_off of % is outside the e-invoice schema''s RndOffAmt range (-99.99..+99.99).',
                inv_money_to_decimal_string(v_round_off) USING ERRCODE = 'ER049';
        END IF;
        v_gross := v_nearest;
    END IF;

    -- 5. Assemble the complete computed document.
    res.invoice_number  := p_invoice_number;
    res.numbered        := p_invoice_number IS NOT NULL;
    res.document_type   := v_doc_type;
    res.document_title  := CASE
        WHEN v_doc_type = 'tax_invoice' THEN inv_gst_config_text('title_tax_invoice')
        WHEN p_seller.registration_status = 'unregistered' THEN inv_gst_config_text('title_unregistered_invoice')
        ELSE inv_gst_config_text('title_bill_of_supply')
    END;
    res.statutory_legend := CASE WHEN p_seller.registration_status = 'composition'
                                 THEN inv_gst_config_text('composition_legend') ELSE NULL END;
    res.no_itc_note      := CASE WHEN v_doc_type = 'bill_of_supply' THEN inv_gst_config_text('no_itc_note') ELSE NULL END;
    res.issue_date       := p_issue_date;
    res.supply_type      := p_supply_type;
    res.place_of_supply_code := v_pos_code;
    res.place_of_supply_name := CASE WHEN v_pos_code IS NULL THEN NULL ELSE inv_gst_state_name_for(v_pos_code) END;
    res.place_of_supply_resolved := v_pos_code IS NOT NULL;
    res.tax_treatment    := v_treatment;
    res.seller_state_code := v_seller_code;
    res.buyer_state_code  := v_buyer_code;
    res.buyer_effective_registration_status := inv_gst_effective_registration_status(p_buyer.registration_status, p_buyer.gstin);
    res.currency         := p_currency;
    res.fx_rate          := CASE WHEN p_currency = 'INR' THEN NULL ELSE inv_money_assert_positive_decimal_string(p_fx_rate, 'fx_rate') END;
    res.amount_inr_minor := CASE WHEN p_amount_inr IS NULL THEN NULL ELSE inv_money_to_minor_units(p_amount_inr) END;
    res.taxable_value_minor := v_tax_t;
    res.cgst_minor       := v_cgst_t;
    res.sgst_minor       := v_sgst_t;
    res.igst_minor       := v_igst_t;
    res.round_off_minor  := v_round_off;
    res.gross_total_minor := v_gross;
    res.taxable_value_str := inv_money_to_decimal_string(v_tax_t);
    res.cgst_str         := CASE WHEN v_cgst_t IS NULL THEN NULL ELSE inv_money_to_decimal_string(v_cgst_t) END;
    res.sgst_str         := CASE WHEN v_sgst_t IS NULL THEN NULL ELSE inv_money_to_decimal_string(v_sgst_t) END;
    res.igst_str         := CASE WHEN v_igst_t IS NULL THEN NULL ELSE inv_money_to_decimal_string(v_igst_t) END;
    res.round_off_str    := CASE WHEN v_round_off IS NULL THEN NULL ELSE inv_money_to_decimal_string(v_round_off) END;
    res.gross_total_str  := inv_money_to_decimal_string(v_gross);
    res.lines            := v_clines;
    RETURN res;
END;
$$ LANGUAGE plpgsql STABLE;
