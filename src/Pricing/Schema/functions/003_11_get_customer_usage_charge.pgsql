-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: functions :: get_customer_usage_charge — split from 003_pricing_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

-- Total postpaid charge for a billing period: sum of quantity * the rate
-- EACH event was pinned to at record time — never the rate active today.
-- Money follows the same paisa-integer rule as everywhere else; ROUND
-- guards against a caller ever picking a non-integer rate by mistake.

CREATE OR REPLACE FUNCTION get_customer_usage_charge(p_tenant_id UUID, p_platform_code VARCHAR(50), p_period_start TIMESTAMPTZ, p_period_end TIMESTAMPTZ)
RETURNS BIGINT AS $$
DECLARE
    v_total BIGINT;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    SELECT COALESCE(SUM(ROUND(cue.quantity_consumed * cpp.rate_per_unit::numeric)), 0)
    INTO v_total
    FROM consumption_usage_events cue
    JOIN consumption_pricing_plans cpp ON cpp.id = cue.consumption_pricing_plan_id
    WHERE cue.tenant_id = p_tenant_id AND cue.platform_code = p_platform_code
      AND cue.usage_at BETWEEN p_period_start AND p_period_end;

    RETURN v_total;
END;
$$ LANGUAGE plpgsql;