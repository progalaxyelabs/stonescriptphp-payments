-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: types :: inv_computed_line — split from Gst/030_gst_tax_engine.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

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

CREATE TYPE inv_computed_line AS (
    description         TEXT,
    hsn_sac             TEXT,
    quantity_milli      BIGINT,
    quantity_str        TEXT,
    unit_price_minor    BIGINT,
    gst_rate            NUMERIC,
    taxable_value_minor BIGINT,
    cgst_minor          BIGINT,
    sgst_minor          BIGINT,
    igst_minor          BIGINT,
    line_total_minor    BIGINT,
    taxable_value_str   TEXT,
    cgst_str            TEXT,
    sgst_str            TEXT,
    igst_str            TEXT,
    line_total_str      TEXT
);
