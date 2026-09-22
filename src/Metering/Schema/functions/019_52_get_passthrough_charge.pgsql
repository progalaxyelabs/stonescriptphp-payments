-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: functions :: get_passthrough_charge — split from 019_passthrough_cost_plus.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

-- Total passthrough charge over a window: each measurement's COGS derived
-- through the margin config it was pinned to, for periods whose period_start
-- falls in [p_from, p_to]. Each measurement keeps the margin it was recorded
-- under, never today's.

CREATE OR REPLACE FUNCTION get_passthrough_charge(p_tenant_id UUID, p_platform_code VARCHAR(50), p_from TIMESTAMPTZ, p_to TIMESTAMPTZ)
RETURNS BIGINT AS $$
DECLARE
    v_total BIGINT;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    SELECT COALESCE(SUM(derive_price_from_cost(pcm.measured_cost, ppp.margin_mode, ppp.margin_pct)), 0)
    INTO v_total
    FROM passthrough_cost_measurements pcm
    JOIN passthrough_pricing_plans ppp ON ppp.id = pcm.passthrough_pricing_plan_id
    WHERE pcm.tenant_id = p_tenant_id AND pcm.platform_code = p_platform_code
      AND pcm.period_start BETWEEN p_from AND p_to;

    RETURN v_total;
END;
$$ LANGUAGE plpgsql;
