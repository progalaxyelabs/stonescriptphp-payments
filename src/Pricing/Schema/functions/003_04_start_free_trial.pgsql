-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: functions :: start_free_trial — split from 003_pricing_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: functions
--   get_pricing_plans()               -- public pricing page: only what's currently sellable
--   get_customer_pricing_plan(id)     -- a customer's own pinned plan, regardless of catalog changes
--   cancel_subscription_pricing_plan(customer_pricing_plan_id)
--
--
-- NO now()/CURRENT_DATE/CURRENT_TIME anywhere (same rule as 001/002):
-- cancel_subscription_pricing_plan takes the cancellation timestamp as an
-- explicit parameter instead of stamping now(). Auto-population comes back
-- once the system is proved end to end.
--
-- Custom SQLSTATE error codes (5 chars, hard Postgres limit — verified live,
-- a longer code like 'INVERR001' is rejected as "unrecognized exception
-- condition"). The API layer catches on these, not on message text:
--   ER001  customer does not exist                                    -> 404
--   ER002  customer_pricing_plan does not exist                       -> 404
--   ER003  customer_pricing_plan already cancelled                    -> 409
--   ER004  customer_pricing_plan is a one-time plan, not a subscription -> 400
--   ER005  customer has already used the free trial                   -> 409
--   ER006  no active free trial plan is configured                    -> 500 (ops error, not the caller's fault)
--   ER007  cannot cancel a free trial — it only ends by expiry         -> 400
--   ER008  target subscription_pricing_plan is not currently sellable  -> 400
--   ER009  insufficient credit balance to consume the requested amount  -> 409
--   ER010  customer is already enrolled in this consumption plan (only one row, ever) -> 409
--   ER011  target consumption_pricing_plan is not currently sellable    -> 400
--   ER012  customer is not enrolled in any consumption plan             -> 400
--
-- Proration convention (switching cadence mid-cycle only — see
-- renew_subscription_pricing_plan): whole DAYS for a monthly-cadence plan
-- being ended, whole MONTHS for an annual-cadence plan being ended, on the
-- tax-exclusive amount, rounded to the nearest paisa. Same convention
-- already established in the subscription billing lifecycle design.
-- The credit is COMPUTED and RETURNED only — there is no ledger/wallet
-- table yet to bank it against a future charge.

-- Never called as part of customer registration. A separate, explicit API
-- call, invoked whenever the caller decides to actually start the trial.
-- One trial per customer, ever — used, running, or expired all count.

CREATE OR REPLACE FUNCTION start_free_trial(p_tenant_id UUID, p_platform_code VARCHAR(50), p_started_at TIMESTAMPTZ, p_created_by TEXT)
RETURNS customer_pricing_plans AS $$
DECLARE
    v_trial_pricing_plan_id BIGINT;
    v_trial_subscription_pricing_plan_id BIGINT;
    v_row customer_pricing_plans;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    SELECT pp.id, spp.id INTO v_trial_pricing_plan_id, v_trial_subscription_pricing_plan_id
    FROM pricing_plans pp
    JOIN subscription_pricing_plans spp ON spp.pricing_plan_id = pp.id
    WHERE pp.is_trial = true AND pp.is_active = true AND spp.is_active = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no active free trial plan is configured' USING ERRCODE = 'ER006';
    END IF;

    -- Any prior row against the trial plan counts as "used" — active,
    -- expired, or otherwise. No second trial, ever.
    IF EXISTS (
        SELECT 1 FROM customer_pricing_plans
        WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND pricing_plan_id = v_trial_pricing_plan_id
    ) THEN
        RAISE EXCEPTION 'tenant % (platform %) has already used the free trial', p_tenant_id, p_platform_code USING ERRCODE = 'ER005';
    END IF;

    INSERT INTO customer_pricing_plans
        (tenant_id, platform_code, pricing_plan_id, subscription_pricing_plan_id, started_at, created_at, created_by)
    VALUES
        (p_tenant_id, p_platform_code, v_trial_pricing_plan_id, v_trial_subscription_pricing_plan_id, p_started_at, p_started_at, p_created_by)
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;
