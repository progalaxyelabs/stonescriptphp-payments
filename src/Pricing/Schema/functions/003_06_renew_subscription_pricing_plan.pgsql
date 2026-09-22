-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: functions :: renew_subscription_pricing_plan — split from 003_pricing_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

-- Handles BOTH a plain renewal (same cadence) and a plan switch (different
-- cadence, e.g. monthly <-> annual), keyed only by which subscription_pricing_plan_id
-- the caller targets — always the CURRENTLY sellable price row for that
-- cadence, so a price increase only ever bites at the next renewal, never
-- retroactively (you cannot target a superseded, is_active=false row).
--
--   Same cadence as the customer's current live row -> plain renewal:
--     new period starts at GREATEST(p_effective_at, old_expires_at) — renew
--     early and it queues up with zero loss; renew late and the gap is honest.
--
--   Different cadence -> a switch:
--     if the old plan hasn't lapsed yet, it is cut over immediately: the old
--     row is cancelled AT p_effective_at (cancel_reason='switched_plan') and
--     the new row starts right then, mid-cycle. The unused portion of the
--     old plan is PRORATED (see the convention noted above the SQLSTATE list)
--     and returned as prorated_credit_paisa — not yet banked anywhere.
--
--   No live previous row of this plan identity -> treated as a fresh
--   subscribe, starting at p_effective_at.

CREATE OR REPLACE FUNCTION renew_subscription_pricing_plan(
    p_tenant_id UUID,
    p_platform_code VARCHAR(50),
    p_subscription_pricing_plan_id BIGINT,
    p_effective_at TIMESTAMPTZ,
    p_created_by TEXT
)
RETURNS TABLE (
    customer_pricing_plan_id     BIGINT,
    pricing_plan_id              BIGINT,
    subscription_pricing_plan_id BIGINT,
    started_at                   TIMESTAMPTZ,
    expires_at                   TIMESTAMPTZ,
    is_switch                    BOOLEAN,
    prorated_credit_paisa        BIGINT  -- NULL when not applicable (plain renewal, or nothing to prorate)
) AS $$
DECLARE
    v_target RECORD;
    v_prev RECORD;
    v_prev_expires_at TIMESTAMPTZ;
    v_new_started_at TIMESTAMPTZ;
    v_is_switch BOOLEAN := false;
    v_credit BIGINT := NULL;
    v_new_id BIGINT;
    v_elapsed_months INT;
    v_unused_months INT;
    v_total_days INT;
    v_unused_days INT;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    SELECT spp.id, spp.pricing_plan_id, spp.duration, spp.duration_uom, spp.amount, spp.is_amount_tax_exclusive
    INTO v_target
    FROM subscription_pricing_plans spp
    JOIN pricing_plans pp ON pp.id = spp.pricing_plan_id
    WHERE spp.id = p_subscription_pricing_plan_id
      AND spp.is_active = true
      AND pp.is_active = true
      AND pp.is_trial = false;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'subscription_pricing_plan % is not currently sellable (inactive, trial, or does not exist)', p_subscription_pricing_plan_id USING ERRCODE = 'ER008';
    END IF;

    -- The customer's current live row for this SAME plan identity, if any.
    SELECT cpp.id, cpp.pricing_plan_id, cpp.subscription_pricing_plan_id, cpp.started_at,
           spp.duration, spp.duration_uom, spp.amount
    INTO v_prev
    FROM customer_pricing_plans cpp
    JOIN subscription_pricing_plans spp ON spp.id = cpp.subscription_pricing_plan_id
    WHERE cpp.tenant_id = p_tenant_id AND cpp.platform_code = p_platform_code
      AND cpp.pricing_plan_id = v_target.pricing_plan_id
      AND cpp.cancelled_at IS NULL
    ORDER BY cpp.started_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        v_new_started_at := p_effective_at;
    ELSE
        v_prev_expires_at := v_prev.started_at + (v_prev.duration || ' ' || v_prev.duration_uom)::interval;

        IF v_prev.duration = v_target.duration AND v_prev.duration_uom = v_target.duration_uom THEN
            -- plain renewal: same cadence, seamless, nothing to prorate
            v_new_started_at := GREATEST(p_effective_at, v_prev_expires_at);
        ELSE
            v_is_switch := true;
            IF p_effective_at < v_prev_expires_at THEN
                IF v_prev.duration_uom = 'month' AND v_prev.duration >= 12 THEN
                    v_elapsed_months := EXTRACT(YEAR FROM age(p_effective_at, v_prev.started_at))::int * 12
                                       + EXTRACT(MONTH FROM age(p_effective_at, v_prev.started_at))::int;
                    v_unused_months := v_prev.duration - v_elapsed_months;
                    v_credit := ROUND(v_prev.amount * v_unused_months::numeric / v_prev.duration);
                ELSE
                    v_total_days := (v_prev_expires_at::date - v_prev.started_at::date);
                    v_unused_days := (v_prev_expires_at::date - p_effective_at::date);
                    v_credit := ROUND(v_prev.amount * v_unused_days::numeric / v_total_days);
                END IF;

                UPDATE customer_pricing_plans
                SET cancelled_at = p_effective_at, cancel_reason = 'switched_plan'
                WHERE id = v_prev.id;
            END IF;
            v_new_started_at := p_effective_at;
        END IF;
    END IF;

    INSERT INTO customer_pricing_plans
        (tenant_id, platform_code, pricing_plan_id, subscription_pricing_plan_id, started_at, created_at, created_by)
    VALUES
        (p_tenant_id, p_platform_code, v_target.pricing_plan_id, v_target.id, v_new_started_at, p_effective_at, p_created_by)
    RETURNING id INTO v_new_id;

    RETURN QUERY
    SELECT v_new_id, v_target.pricing_plan_id, v_target.id, v_new_started_at,
           v_new_started_at + (v_target.duration || ' ' || v_target.duration_uom)::interval,
           v_is_switch, v_credit;
END;
$$ LANGUAGE plpgsql;
