-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: functions :: consume_credits — split from 003_pricing_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

-- Validates sufficient balance AS OF p_consumed_at (via the same FIFO
-- simulation, computed before this event exists) before recording the
-- debit — never a silent negative balance.
-- Simplification (same as start_free_trial): one explicit timestamp used
-- for both consumed_at and created_at.

CREATE OR REPLACE FUNCTION consume_credits(p_tenant_id UUID, p_platform_code VARCHAR(50), p_consumed_at TIMESTAMPTZ, p_credits BIGINT, p_created_by TEXT)
RETURNS credit_consumptions AS $$
DECLARE
    v_balance BIGINT;
    v_row credit_consumptions;
BEGIN
    v_balance := get_customer_credit_balance(p_tenant_id, p_platform_code, p_consumed_at);

    IF v_balance < p_credits THEN
        RAISE EXCEPTION 'tenant % (platform %) has insufficient credits (% available, % requested) as of %',
            p_tenant_id, p_platform_code, v_balance, p_credits, p_consumed_at USING ERRCODE = 'ER009';
    END IF;

    INSERT INTO credit_consumptions (tenant_id, platform_code, consumed_at, credits_consumed, created_at, created_by)
    VALUES (p_tenant_id, p_platform_code, p_consumed_at, p_credits, p_consumed_at, p_created_by)
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;
