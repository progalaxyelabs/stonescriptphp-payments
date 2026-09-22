-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: functions :: record_usage — split from 003_pricing_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

-- Records a usage event, pinned to WHICHEVER consumption_pricing_plan is
-- currently active for the customer's enrolled plan identity — resolved
-- fresh at record time, never the rate the customer enrolled under. This is
-- the "no grandfathering" policy: a rate change applies to all NEW usage
-- immediately, and never rewrites the price of usage already recorded.

CREATE OR REPLACE FUNCTION record_usage(p_tenant_id UUID, p_platform_code VARCHAR(50), p_usage_at TIMESTAMPTZ, p_quantity BIGINT, p_created_by TEXT)
RETURNS consumption_usage_events AS $$
DECLARE
    v_enrollment RECORD;
    v_current_rate RECORD;
    v_row consumption_usage_events;
BEGIN
    SELECT pricing_plan_id INTO v_enrollment
    FROM customer_pricing_plans
    WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND consumption_pricing_plan_id IS NOT NULL;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'tenant % (platform %) is not enrolled in any consumption plan', p_tenant_id, p_platform_code USING ERRCODE = 'ER012';
    END IF;

    SELECT id INTO v_current_rate
    FROM consumption_pricing_plans
    WHERE pricing_plan_id = v_enrollment.pricing_plan_id AND is_active = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no active consumption_pricing_plan is currently configured for pricing_plan %', v_enrollment.pricing_plan_id USING ERRCODE = 'ER011';
    END IF;

    INSERT INTO consumption_usage_events
        (tenant_id, platform_code, consumption_pricing_plan_id, usage_at, quantity_consumed, created_at, created_by)
    VALUES
        (p_tenant_id, p_platform_code, v_current_rate.id, p_usage_at, p_quantity, p_usage_at, p_created_by)
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;
