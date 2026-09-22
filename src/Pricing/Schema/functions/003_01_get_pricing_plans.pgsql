-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: functions :: get_pricing_plans — split from 003_pricing_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

CREATE OR REPLACE FUNCTION get_pricing_plans()
RETURNS TABLE (
    pricing_plan_id         BIGINT,
    pricing_plan_name       TEXT,
    is_subscription         BOOLEAN,
    price_plan_id           BIGINT,
    duration                INTEGER,
    duration_uom            TEXT,
    amount                  BIGINT,
    is_amount_tax_exclusive BOOLEAN,
    is_post_paid            BOOLEAN,
    is_life_time            BOOLEAN,
    is_credit_system        BOOLEAN
) AS $$
BEGIN
    -- Only the CURRENT sellable price row of each active plan.
    -- A superseded child row (is_active = false) never appears here,
    -- even though a customer already pinned to it keeps seeing it (see below).
    RETURN QUERY
    SELECT pp.id, pp.name, pp.is_subscription,
           spp.id, spp.duration, spp.duration_uom, spp.amount, spp.is_amount_tax_exclusive,
           spp.is_post_paid, NULL::boolean, NULL::boolean
    FROM pricing_plans pp
    JOIN subscription_pricing_plans spp ON spp.pricing_plan_id = pp.id
    WHERE pp.is_active = true AND spp.is_active = true

    UNION ALL

    SELECT pp.id, pp.name, pp.is_subscription,
           otp.id, otp.duration, otp.duration_uom, otp.amount, otp.is_amount_tax_exclusive,
           NULL::boolean, otp.is_life_time, otp.is_credit_system
    FROM pricing_plans pp
    JOIN one_time_pricing_plans otp ON otp.pricing_plan_id = pp.id
    WHERE pp.is_active = true AND otp.is_active = true;
END;
$$ LANGUAGE plpgsql;
