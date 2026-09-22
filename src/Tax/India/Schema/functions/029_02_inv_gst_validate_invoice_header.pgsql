-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_gst_validate_invoice_header — split from Gst/029_gst_line_and_invoice_validation.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

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

-- Validate invoice-header rules. Mirrors InvoiceInput's constructor (line-count,
-- amount_inr sign, currency/fx/amount_inr consistency, party roles). The invoice
-- number is validated separately by inv_number_assert_lawful (027).

CREATE OR REPLACE FUNCTION inv_gst_validate_invoice_header(
    p_currency      TEXT,
    p_fx_rate       TEXT,
    p_amount_inr    TEXT,
    p_seller_role   TEXT,
    p_buyer_role    TEXT,
    p_line_count    INTEGER
) RETURNS VOID AS $$
DECLARE
    v_amount_minor BIGINT;
BEGIN
    IF p_line_count < 1 THEN
        RAISE EXCEPTION 'An invoice must have at least one line.' USING ERRCODE = 'ER037';
    END IF;

    IF p_amount_inr IS NOT NULL THEN
        v_amount_minor := inv_money_to_minor_units(p_amount_inr);
        IF v_amount_minor < 0 THEN
            RAISE EXCEPTION 'amount_inr must not be negative — got %.', inv_money_to_decimal_string(v_amount_minor)
                USING ERRCODE = 'ER039';
        END IF;
    END IF;

    IF p_currency = 'INR' THEN
        IF p_fx_rate IS NOT NULL OR p_amount_inr IS NOT NULL THEN
            RAISE EXCEPTION 'currency is ''INR'' — fx_rate and amount_inr must both be absent; there is nothing to convert.'
                USING ERRCODE = 'ER038';
        END IF;
    ELSE
        IF p_fx_rate IS NULL OR p_amount_inr IS NULL THEN
            RAISE EXCEPTION 'currency "%" is not INR — fx_rate and amount_inr are both required.', p_currency
                USING ERRCODE = 'ER038';
        END IF;
        PERFORM inv_money_assert_positive_decimal_string(p_fx_rate, 'fx_rate');
    END IF;

    IF p_seller_role <> 'seller' THEN
        RAISE EXCEPTION 'seller''s party must carry role ''seller''.' USING ERRCODE = 'ER042';
    END IF;
    IF p_buyer_role <> 'buyer' THEN
        RAISE EXCEPTION 'buyer''s party must carry role ''buyer''.' USING ERRCODE = 'ER042';
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;
