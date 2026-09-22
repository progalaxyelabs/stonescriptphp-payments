-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: functions :: get_customer_purchase_history — split from 003_pricing_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

-- Full purchase ledger: every customer_pricing_plans row (active, expired,
-- cancelled, or switched-away) whose started_at falls in [p_from, p_to].
-- No expiry/cancellation filtering here — this is history, not entitlement.

CREATE OR REPLACE FUNCTION get_customer_purchase_history(p_tenant_id UUID, p_platform_code VARCHAR(50), p_from TIMESTAMPTZ, p_to TIMESTAMPTZ)
RETURNS TABLE (
    customer_pricing_plan_id BIGINT,
    pricing_plan_id          BIGINT,
    pricing_plan_name        TEXT,
    is_subscription          BOOLEAN,
    price_plan_id            BIGINT,
    duration                 INTEGER,
    duration_uom             TEXT,
    amount                   BIGINT,
    is_amount_tax_exclusive  BOOLEAN,
    started_at               TIMESTAMPTZ,
    cancelled_at             TIMESTAMPTZ,
    cancel_reason            TEXT
) AS $$
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    RETURN QUERY
    SELECT cpp.id, pp.id, pp.name, pp.is_subscription,
           spp.id, spp.duration, spp.duration_uom, spp.amount, spp.is_amount_tax_exclusive,
           cpp.started_at, cpp.cancelled_at, cpp.cancel_reason
    FROM customer_pricing_plans cpp
    JOIN pricing_plans pp ON pp.id = cpp.pricing_plan_id
    JOIN subscription_pricing_plans spp ON spp.id = cpp.subscription_pricing_plan_id
    WHERE cpp.tenant_id = p_tenant_id AND cpp.platform_code = p_platform_code
      AND cpp.started_at BETWEEN p_from AND p_to

    UNION ALL

    SELECT cpp.id, pp.id, pp.name, pp.is_subscription,
           otp.id, otp.duration, otp.duration_uom, otp.amount, otp.is_amount_tax_exclusive,
           cpp.started_at, cpp.cancelled_at, cpp.cancel_reason
    FROM customer_pricing_plans cpp
    JOIN pricing_plans pp ON pp.id = cpp.pricing_plan_id
    JOIN one_time_pricing_plans otp ON otp.id = cpp.one_time_pricing_plan_id
    WHERE cpp.tenant_id = p_tenant_id AND cpp.platform_code = p_platform_code
      AND cpp.started_at BETWEEN p_from AND p_to

    ORDER BY started_at;
END;
$$ LANGUAGE plpgsql;
