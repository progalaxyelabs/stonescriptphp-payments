-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_fx_inr_statutory_value_minor — split from Gst/032_gst_fx_statutory_value.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: dated FX reference rates + statutory INR value of a
--   foreign-currency (export) invoice.
--
-- BEYOND THE PHP ORACLE (flagged): the PHP TaxEngine takes amount_inr as a
-- caller-supplied passthrough — it never COMPUTES USD x rate. That fx logic
-- lived in a separate sales calculator. Here, for foreign-currency (export)
-- invoices, the statutory INR value is computed IN SQL,
-- with the RBI reference RATE as a dated DATA row (never a constant), so the
-- module owns it end-to-end.
--
-- Exactness: rate is stored as NUMERIC (RBI publishes 4dp). The value is
-- computed by the SAME pure-integer half-up identity as all other money:
-- INR_paisa = half_up_divide(foreign_minor x rate_ten_thousandths, 10000).
-- No float, no NUMERIC round in the money path. (10000 = ten-thousandths = the
-- 4dp rate scale — a unit constant.)
--
--   ER051  no FX reference rate on record for (currency, date)  -> 400

-- Statutory INR value (integer paisa) of a foreign amount already in minor units
-- (cents for USD), at a dated reference rate.

CREATE OR REPLACE FUNCTION inv_fx_inr_statutory_value_minor(
    p_currency TEXT, p_rate_date DATE, p_foreign_minor BIGINT
) RETURNS BIGINT AS $$
DECLARE
    v_rate NUMERIC;
    v_rate_tt BIGINT;
BEGIN
    SELECT rate_per_unit_inr INTO v_rate
      FROM inv_fx_reference_rates
     WHERE currency = p_currency AND rate_date = p_rate_date;
    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'no FX reference rate on record for % on %', p_currency, p_rate_date USING ERRCODE = 'ER051';
    END IF;
    -- rate_ten_thousandths: exact integer for a <=4dp rate. 10000 = 4dp scale.
    v_rate_tt := round(v_rate * 10000)::BIGINT;
    -- foreign_minor (cents) x INR-per-unit = INR x 100 = INR paisa, half-up.
    RETURN inv_money_half_up_divide(p_foreign_minor * v_rate_tt, 10000);
END;
$$ LANGUAGE plpgsql STABLE;
