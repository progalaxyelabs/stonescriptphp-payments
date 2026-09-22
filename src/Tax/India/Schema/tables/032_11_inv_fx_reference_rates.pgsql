-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Tax/India :: tables :: inv_fx_reference_rates — split from Gst/032_gst_fx_statutory_value.pgsql (SCOPE->BUCKET layout migration + Gst->Tax/India rename, 2026-09-14)

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

CREATE TABLE inv_fx_reference_rates (
    currency            TEXT NOT NULL,
    rate_date           DATE NOT NULL,     -- BUSINESS INPUT: the reference date (e.g. RBI rate date). Never "now".
    rate_per_unit_inr   NUMERIC NOT NULL,  -- INR per 1 unit of `currency`, 4dp (RBI convention)
    source              TEXT NOT NULL,
    PRIMARY KEY (currency, rate_date)
);
