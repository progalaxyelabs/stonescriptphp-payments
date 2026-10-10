-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_gst_compute_line — split from Gst/030_gst_tax_engine.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

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

-- Compute one line (assumes it has already passed inv_gst_validate_line, which
-- inv_compute_invoice runs upfront for every line). Mirrors TaxEngine::computeLine
-- + splitTax, including the review-C4 inclusive-price MRP invariant.

CREATE OR REPLACE FUNCTION inv_gst_compute_line(
    p_line inv_line_input, p_mode TEXT, p_price_is_inclusive BOOLEAN
) RETURNS inv_computed_line AS $$
DECLARE
    v_qty_milli  BIGINT := inv_money_quantity_to_milli_units(p_line.quantity);
    v_unit_minor BIGINT := inv_money_to_minor_units(p_line.unit_price);
    v_disc_minor BIGINT := inv_money_to_minor_units(COALESCE(p_line.line_discount, '0'));
    v_rate_bp    INTEGER := inv_money_rate_to_basis_points(p_line.gst_rate);
    v_gross      BIGINT;
    v_gross_ad   BIGINT;
    v_taxable    BIGINT;
    v_line_gst   BIGINT;
    v_half       BIGINT;
    v_cgst       BIGINT;
    v_sgst       BIGINT;
    v_igst       BIGINT;
    v_total      BIGINT;
    r            inv_computed_line;
BEGIN
    v_gross    := inv_money_half_up_divide(v_qty_milli * v_unit_minor, 1000); -- 1000 = milli-units/unit
    v_gross_ad := v_gross - v_disc_minor;

    IF p_price_is_inclusive THEN
        -- Reverse-compute: taxable = gross / (1 + rate); lineGst is the residual
        -- so taxable + lineGst == gross_after_discount exactly. 10000 = rate scale.
        v_taxable  := inv_money_half_up_divide(v_gross_ad * 10000, 10000 + v_rate_bp);
        v_line_gst := v_gross_ad - v_taxable;
    ELSE
        v_taxable  := v_gross_ad;
        v_line_gst := inv_money_half_up_divide(v_taxable * v_rate_bp, 10000);
    END IF;

    -- splitTax
    IF p_mode = 'no_tax' THEN
        v_cgst := NULL; v_sgst := NULL; v_igst := NULL;
    ELSIF p_mode = 'export_lut' THEN
        v_cgst := 0; v_sgst := 0; v_igst := 0;
    ELSIF p_mode = 'intrastate' THEN
        -- The line's TOTAL tax is rounded once; CGST is half of it rounded half-up and SGST is the REMAINDER,
        -- so the two heads always sum to the rounded total (an odd paisa goes to CGST, never billed twice).
        -- Rounding the two halves independently would over-bill an odd total by one paisa per line.
        -- [CA TO CONFIRM: that an unequal CGST/SGST split of one paisa is acceptable on a tax invoice.]
        v_half := inv_money_half_up_divide(v_line_gst, 2);  -- 2 = CGST share
        v_cgst := v_half; v_sgst := v_line_gst - v_half; v_igst := 0;
    ELSIF p_mode = 'interstate' THEN
        v_cgst := 0; v_sgst := 0; v_igst := v_line_gst;
    ELSE
        RAISE EXCEPTION 'Unknown internal tax split mode "%".', p_mode USING ERRCODE = 'ER050';
    END IF;

    IF p_price_is_inclusive AND p_mode <> 'no_tax' THEN
        -- lineTotal is the MRP the customer agreed to pay — it must
        -- NEVER exceed gross_after_discount. Any equal-halves paisa is absorbed
        -- into taxable_value, never billed on top.
        v_total   := v_gross_ad;
        v_taxable := v_total - COALESCE(v_cgst,0) - COALESCE(v_sgst,0) - COALESCE(v_igst,0);
    ELSIF p_mode = 'no_tax' THEN
        v_total := v_taxable;
    ELSE
        v_total := v_taxable + COALESCE(v_cgst,0) + COALESCE(v_sgst,0) + COALESCE(v_igst,0);
    END IF;

    r.description         := p_line.description;
    r.hsn_sac             := p_line.hsn_sac;
    r.quantity_milli      := v_qty_milli;
    r.quantity_str        := inv_money_quantity_milli_to_decimal_string(v_qty_milli);
    r.unit_price_minor    := v_unit_minor;
    r.gst_rate            := p_line.gst_rate;
    r.taxable_value_minor := v_taxable;
    r.cgst_minor          := v_cgst;
    r.sgst_minor          := v_sgst;
    r.igst_minor          := v_igst;
    r.line_total_minor    := v_total;
    r.taxable_value_str   := inv_money_to_decimal_string(v_taxable);
    r.cgst_str            := CASE WHEN v_cgst IS NULL THEN NULL ELSE inv_money_to_decimal_string(v_cgst) END;
    r.sgst_str            := CASE WHEN v_sgst IS NULL THEN NULL ELSE inv_money_to_decimal_string(v_sgst) END;
    r.igst_str            := CASE WHEN v_igst IS NULL THEN NULL ELSE inv_money_to_decimal_string(v_igst) END;
    r.line_total_str      := inv_money_to_decimal_string(v_total);
    RETURN r;
END;
$$ LANGUAGE plpgsql STABLE;
