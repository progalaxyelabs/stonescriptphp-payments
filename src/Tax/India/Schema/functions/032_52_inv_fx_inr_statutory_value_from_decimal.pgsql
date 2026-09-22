-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: functions :: inv_fx_inr_statutory_value_from_decimal — split from Gst/032_gst_fx_statutory_value.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

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

-- Convenience: foreign amount as a decimal string ("162.76") -> INR paisa.

CREATE OR REPLACE FUNCTION inv_fx_inr_statutory_value_from_decimal(
    p_currency TEXT, p_rate_date DATE, p_foreign_amount TEXT
) RETURNS BIGINT AS $$
    SELECT inv_fx_inr_statutory_value_minor(p_currency, p_rate_date, inv_money_to_minor_units(p_foreign_amount));
$$ LANGUAGE sql STABLE;
