-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: types :: inv_computed_invoice — split from Gst/030_gst_tax_engine.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

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

CREATE TYPE inv_computed_invoice AS (
    invoice_number      TEXT,
    numbered            BOOLEAN,
    document_type       TEXT,
    document_title      TEXT,
    statutory_legend    TEXT,
    no_itc_note         TEXT,
    issue_date          TIMESTAMPTZ,
    supply_type         TEXT,
    place_of_supply_code TEXT,
    place_of_supply_name TEXT,
    place_of_supply_resolved BOOLEAN,
    tax_treatment       TEXT,
    seller_state_code   TEXT,
    buyer_state_code    TEXT,
    buyer_effective_registration_status TEXT,
    currency            TEXT,
    fx_rate             TEXT,
    amount_inr_minor    BIGINT,
    taxable_value_minor BIGINT,
    cgst_minor          BIGINT,
    sgst_minor          BIGINT,
    igst_minor          BIGINT,
    round_off_minor     BIGINT,
    gross_total_minor   BIGINT,
    taxable_value_str   TEXT,
    cgst_str            TEXT,
    sgst_str            TEXT,
    igst_str            TEXT,
    round_off_str       TEXT,
    gross_total_str     TEXT,
    lines               inv_computed_line[]
);
