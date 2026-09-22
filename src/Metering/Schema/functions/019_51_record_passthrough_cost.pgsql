-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: functions :: record_passthrough_cost — split from 019_passthrough_cost_plus.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

-- Record a measured period cost, pinning the passthrough plan (and thus its
-- margin config) currently active for the plan — resolved fresh at record time
-- (no grandfathering).

CREATE OR REPLACE FUNCTION record_passthrough_cost(
    p_tenant_id UUID,
    p_platform_code VARCHAR(50),
    p_pricing_plan_id BIGINT,
    p_period_start TIMESTAMPTZ,
    p_period_end TIMESTAMPTZ,
    p_measured_cost BIGINT,
    p_recorded_at TIMESTAMPTZ,
    p_created_by TEXT
)
RETURNS passthrough_cost_measurements AS $$
DECLARE
    v_plan_id BIGINT;
    v_row passthrough_cost_measurements;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    SELECT ppp.id INTO v_plan_id
    FROM passthrough_pricing_plans ppp
    JOIN pricing_plans pp ON pp.id = ppp.pricing_plan_id
    WHERE ppp.pricing_plan_id = p_pricing_plan_id
      AND ppp.is_active = true
      AND pp.is_active = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no active passthrough plan for pricing_plan %', p_pricing_plan_id USING ERRCODE = 'ER019';
    END IF;

    INSERT INTO passthrough_cost_measurements
        (tenant_id, platform_code, passthrough_pricing_plan_id, period_start, period_end, measured_cost, created_at, created_by)
    VALUES
        (p_tenant_id, p_platform_code, v_plan_id, p_period_start, p_period_end, p_measured_cost, p_recorded_at, p_created_by)
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;
