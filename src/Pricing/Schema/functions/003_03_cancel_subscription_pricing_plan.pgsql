-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: functions :: cancel_subscription_pricing_plan — split from 003_pricing_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

CREATE OR REPLACE FUNCTION cancel_subscription_pricing_plan(p_customer_pricing_plan_id BIGINT, p_cancelled_at TIMESTAMPTZ, p_cancel_reason TEXT)
RETURNS customer_pricing_plans AS $$
DECLARE
    v_row customer_pricing_plans;
BEGIN
    SELECT * INTO v_row
    FROM customer_pricing_plans
    WHERE id = p_customer_pricing_plan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'customer_pricing_plan % does not exist', p_customer_pricing_plan_id USING ERRCODE = 'ER002';
    END IF;

    -- Only subscriptions are "cancelled" — a one-time plan is already
    -- consumed/finished, there is nothing to cancel out of.
    IF v_row.subscription_pricing_plan_id IS NULL THEN
        RAISE EXCEPTION 'customer_pricing_plan % is a one-time plan, not a subscription — cannot cancel', p_customer_pricing_plan_id USING ERRCODE = 'ER004';
    END IF;

    -- A free trial cannot be manually cancelled — it only ends by expiry.
    IF EXISTS (SELECT 1 FROM pricing_plans WHERE id = v_row.pricing_plan_id AND is_trial = true) THEN
        RAISE EXCEPTION 'customer_pricing_plan % is a free trial — it cannot be cancelled, it expires automatically', p_customer_pricing_plan_id USING ERRCODE = 'ER007';
    END IF;

    IF v_row.cancelled_at IS NOT NULL THEN
        RAISE EXCEPTION 'customer_pricing_plan % is already cancelled (at %)', p_customer_pricing_plan_id, v_row.cancelled_at USING ERRCODE = 'ER003';
    END IF;

    UPDATE customer_pricing_plans
    SET cancelled_at = p_cancelled_at, cancel_reason = p_cancel_reason
    WHERE id = p_customer_pricing_plan_id
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;
