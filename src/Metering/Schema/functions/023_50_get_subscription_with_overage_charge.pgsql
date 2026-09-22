-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: functions :: get_subscription_with_overage_charge — split from 023_subscription_plus_overage.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: base recurring subscription + metered OVERAGE, billed
-- together for ONE customer (Case 4)
-- =====================================================================
-- A recurring add-on plan example: a flat monthly base fee that INCLUDES
-- an allowance of metered usage, with usage beyond the allowance billed as
-- overage. Two things were missing:
--  (a) a customer holding BOTH a recurring subscription AND metered usage, and
--      ONE combined charge over them — the schema already allows multiple
--      customer_pricing_plans rows per customer (a subscription child + a
--      consumption child), so no change needed for the "billed together" half;
--  (b) an INCLUDED ALLOWANCE on the base plan — genuinely new. A subscription
--      price row had no way to say "this plan bundles N units; meter the rest".
--
-- SCHEMA CHANGE (migration, not an edit to 001) — why: (b) needs a home for
-- "units bundled into the base fee". The natural owner is the subscription
-- price row itself (the allowance is a property of the priced period), so this
-- ADDs two nullable columns to subscription_pricing_plans. Nullable + no
-- default keeps every existing row and test unchanged (NULL = no bundled
-- allowance = a pure flat sub). Additive and backward-compatible; done as a
-- forward migration per the house rule (never rewrite 001 in place).
--
-- The overage rate reuses the existing consumption engine (record_usage /
-- consumption_pricing_plans, 015/016) under its OWN pricing_plan, so per-event
-- rate pinning + no-grandfathering come for free. The allowance is depleted
-- across usage events in time order, and only the beyond-allowance quantity of
-- each event is charged at THAT event's pinned rate (so a rate change
-- mid-period is handled honestly). Example config prices; the SHAPE (flat base
-- + included allowance + metered overage) is the decided add-on model.
--
-- New SQLSTATE:  ER021  no active base subscription for the plan in the period -> 400

-- Combined charge for a base subscription + its metered overage over a period.
-- base_charge  = the postpaid subscription amount for the covering period
-- included     = units bundled into that base (0 if the plan bundles none)
-- used         = total metered usage in the window (from the consumption engine)
-- overage      = MAX(0, used - included)
-- overage_charge = the beyond-allowance quantity of each usage event × that
--                  event's PINNED rate (allowance consumed in usage_at order)
-- total        = base_charge + overage_charge, billed as one line-pair.

CREATE OR REPLACE FUNCTION get_subscription_with_overage_charge(
    p_tenant_id UUID,
    p_platform_code VARCHAR(50),
    p_base_pricing_plan_id BIGINT,
    p_overage_pricing_plan_id BIGINT,
    p_period_start TIMESTAMPTZ,
    p_period_end TIMESTAMPTZ
)
RETURNS TABLE (
    base_charge      BIGINT,
    included_quantity BIGINT,
    used_quantity    BIGINT,
    overage_quantity BIGINT,
    overage_charge   BIGINT,
    total_charge     BIGINT
) AS $$
DECLARE
    v_base RECORD;
    v_included BIGINT;
    v_allowance_left BIGINT;
    v_used BIGINT := 0;
    v_overage_charge BIGINT := 0;
    v_event RECORD;
    v_chargeable BIGINT;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    -- The base postpaid subscription period covering p_period_start.
    SELECT spp.amount, COALESCE(spp.included_quantity, 0) AS included
    INTO v_base
    FROM customer_pricing_plans cpp
    JOIN subscription_pricing_plans spp ON spp.id = cpp.subscription_pricing_plan_id
    WHERE cpp.tenant_id = p_tenant_id AND cpp.platform_code = p_platform_code
      AND cpp.pricing_plan_id = p_base_pricing_plan_id
      AND cpp.cancelled_at IS NULL
      AND cpp.started_at <= p_period_start
      AND cpp.started_at + (spp.duration || ' ' || spp.duration_uom)::interval > p_period_start
    ORDER BY cpp.started_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'tenant % (platform %) has no active base subscription for pricing_plan % at %',
            p_tenant_id, p_platform_code, p_base_pricing_plan_id, p_period_start USING ERRCODE = 'ER021';
    END IF;

    v_included := v_base.included;
    v_allowance_left := v_included;

    -- Deplete the allowance across usage events in time order; charge only the
    -- beyond-allowance quantity of each, at that event's pinned rate.
    FOR v_event IN
        SELECT cue.quantity_consumed, cp.rate_per_unit
        FROM consumption_usage_events cue
        JOIN consumption_pricing_plans cp ON cp.id = cue.consumption_pricing_plan_id
        WHERE cue.tenant_id = p_tenant_id AND cue.platform_code = p_platform_code
          AND cp.pricing_plan_id = p_overage_pricing_plan_id
          AND cue.usage_at >= p_period_start
          AND cue.usage_at < p_period_end
        ORDER BY cue.usage_at ASC
    LOOP
        v_used := v_used + v_event.quantity_consumed;
        IF v_allowance_left >= v_event.quantity_consumed THEN
            v_allowance_left := v_allowance_left - v_event.quantity_consumed;
            v_chargeable := 0;
        ELSE
            v_chargeable := v_event.quantity_consumed - v_allowance_left;
            v_allowance_left := 0;
        END IF;
        v_overage_charge := v_overage_charge + ROUND(v_chargeable * v_event.rate_per_unit::numeric);
    END LOOP;

    RETURN QUERY SELECT
        v_base.amount,
        v_included,
        v_used,
        GREATEST(0, v_used - v_included),
        v_overage_charge,
        v_base.amount + v_overage_charge;
END;
$$ LANGUAGE plpgsql;
