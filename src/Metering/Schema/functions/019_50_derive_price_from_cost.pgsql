-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: functions :: derive_price_from_cost — split from 019_passthrough_cost_plus.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: COST-PLUS PASSTHROUGH billing (Case 6)
-- =====================================================================
-- A cost-plus / managed-service example: the customer is billed a MEASURED
-- monthly cost (an upstream provider's landed bill, ex-tax) marked up.
-- consumption_pricing_plans'
-- rate_per_unit cannot express this: the basis is not a fixed rate on a
-- countable unit, it is a VARIABLE measured cost that differs every period and
-- is only known after the fact. So the plan carries the MARGIN CONFIG and each
-- period a MEASUREMENT supplies the cost basis; the charge is DERIVED.
--
-- MARGIN AS CONFIG, NOT A CONSTANT: the plan stores a margin MODE +
-- PERCENTAGE as columns with sensible defaults, and the charge is derived —
-- there is NO hardcoded multiplier (× 1.10, × 1.5 …) buried in function
-- logic. The two legitimate conventions:
--   'on_cost'  (markup):       charge = COGS × (1 + pct/100)      [example: 10%]
--   'on_price' (gross margin): charge = COGS / (1 − pct/100)
-- Whichever percentage the operator wants is a one-row UPDATE to margin_pct,
-- not a code change and not a design blocker.
--
-- Integer paisa in and out; margin_pct is a NUMERIC config value (fractions
-- allowed, e.g. 3.68) — a percentage is not money. GST is added by the invoice
-- module; is_amount_tax_exclusive says the measured cost / derived charge is
-- ex-GST.
--
-- New SQLSTATE:  ER019  no active passthrough plan for this pricing_plan  -> 400

-- Derive a selling price (integer paisa) from a measured cost and a margin
-- config — the single cost-plus primitive, mirroring salesCalc.computeBasePrice.
-- No margin number is hardcoded here; both come in as arguments.
-- The only numeric literal below is 100 — the percent basis (the definition of
-- "percent"), a formula constant, NOT a business value: mode and pct are both
-- arguments read from config. Identical shape to salesCalc.ts computeBasePrice.

CREATE OR REPLACE FUNCTION derive_price_from_cost(p_cogs BIGINT, p_margin_mode TEXT, p_margin_pct NUMERIC)
RETURNS BIGINT AS $$
BEGIN
    IF p_margin_mode = 'on_cost' THEN
        RETURN ROUND(p_cogs * (1 + p_margin_pct / 100));
    ELSIF p_margin_mode = 'on_price' THEN
        IF p_margin_pct >= 100 THEN
            RAISE EXCEPTION 'on_price margin %% must be < 100 (got %)', p_margin_pct USING ERRCODE = 'ER019';
        END IF;
        RETURN ROUND(p_cogs / (1 - p_margin_pct / 100));
    ELSE
        RAISE EXCEPTION 'unknown margin_mode %', p_margin_mode USING ERRCODE = 'ER019';
    END IF;
END;
$$ LANGUAGE plpgsql IMMUTABLE;
