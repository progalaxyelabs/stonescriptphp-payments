-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_gst_validate_line — split from Gst/029_gst_line_and_invoice_validation.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: line + invoice-header validation
--   PORT of `Dto/InvoiceLineInput.php` and `Dto/InvoiceInput.php` constructors.
--
-- All the DTO-construction validation the PHP did, now in SQL. The engine
-- (030) calls these; the differential tests also call
-- them directly to reproduce the pure-construction negative cases.
--
--   ER030 hsn_sac required        ER031 quantity must be > 0
--   ER032 gst_rate out of [0,1]   ER033 gst_rate not a lawful slab
--   ER034 unit_price negative     ER035 line_discount negative
--   ER036 discount exceeds gross  ER037 invoice needs >= 1 line
--   ER038 currency/fx/amount_inr consistency   ER039 amount_inr negative

-- Validate one line exactly in PHP InvoiceLineInput's constructor order.
CREATE OR REPLACE FUNCTION inv_gst_validate_line(
    p_description        TEXT,
    p_hsn_sac            TEXT,
    p_quantity           TEXT,
    p_unit_price         TEXT,
    p_gst_rate           NUMERIC,
    p_line_discount      TEXT,
    p_allow_unlisted_rate BOOLEAN
) RETURNS VOID AS $$
DECLARE
    v_qty_milli   BIGINT;
    v_unit_minor  BIGINT;
    v_disc_minor  BIGINT;
    v_gross       BIGINT;
BEGIN
    IF btrim(p_hsn_sac) = '' THEN
        RAISE EXCEPTION 'hsn_sac is required on every invoice line.' USING ERRCODE = 'ER030';
    END IF;

    v_qty_milli := inv_money_quantity_to_milli_units(p_quantity);
    IF v_qty_milli <= 0 THEN
        RAISE EXCEPTION 'quantity must be greater than zero.' USING ERRCODE = 'ER031';
    END IF;

    IF p_gst_rate < 0 OR p_gst_rate > 1 THEN
        RAISE EXCEPTION 'gst_rate must be between 0 and 1 — got %.', p_gst_rate USING ERRCODE = 'ER032';
    END IF;
    IF NOT p_allow_unlisted_rate AND NOT inv_gst_is_allowed_rate(p_gst_rate) THEN
        RAISE EXCEPTION 'gst_rate % is not one of the lawful GST slabs. Pass allow_unlisted_rate=true to bypass deliberately for a newly-notified slab.', p_gst_rate
            USING ERRCODE = 'ER033';
    END IF;

    v_unit_minor := inv_money_to_minor_units(p_unit_price);
    IF v_unit_minor < 0 THEN
        RAISE EXCEPTION 'unit_price must not be negative.' USING ERRCODE = 'ER034';
    END IF;

    v_disc_minor := inv_money_to_minor_units(p_line_discount);
    IF v_disc_minor < 0 THEN
        RAISE EXCEPTION 'line_discount must not be negative.' USING ERRCODE = 'ER035';
    END IF;

    -- 1000 = milli-units per unit (quantity x unit_price -> paisa).
    v_gross := inv_money_half_up_divide(v_qty_milli * v_unit_minor, 1000);
    IF v_disc_minor > v_gross THEN
        RAISE EXCEPTION 'line_discount (%) must not exceed quantity x unit_price (%) — a negative line is not issuable in this phase.',
            inv_money_to_decimal_string(v_disc_minor), inv_money_to_decimal_string(v_gross) USING ERRCODE = 'ER036';
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;
