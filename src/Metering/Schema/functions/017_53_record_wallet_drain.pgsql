-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: functions :: record_wallet_drain — split from 017_wallet_tables_and_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: PREPAID CREDIT WALLET drained by a metered RATE
-- =====================================================================
-- Example of a metered credit-wallet model: ONE shared credit wallet with
-- a fixed per-credit price and an optional minimum top-up; usage SKUs
-- DRAIN the wallet by metered usage at a per-SKU RATE expressed in
-- CREDITS, not paisa. A recurring add-on plan may grant credits per
-- period.
--
-- WHY NEW TABLES (the gap this closes) — neither existing credit system fits:
--   * one_time_pricing_plans + is_credit_system (013/014) debits an INTEGER
--     quantity with NO rate, and only ever from FIXED-quantity purchased packs.
--     It cannot express "arbitrary ₹ top-up" nor "drained by metered usage
--     at a rate".
--   * consumption_pricing_plans (015/016) meters usage at a rate but bills it
--     POSTPAID in paisa — there is no prepaid balance to draw down, no
--     sufficiency gate, no expiry/forfeiture.
--   The wallet is the missing third shape: a PREPAID balance (like credits)
--   drawn down by METERED usage at a RATE (like consumption).
--
-- SCHEMA-TENSION DECISION (asked for explicitly): a wallet is NOT a
-- plan-enrollment, so it gets its OWN tables keyed by tenant_id/platform_code and does
-- NOT take a customer_pricing_plans row. There is no single "plan the
-- customer is on" — the customer holds a BALANCE and may use ANY SKU against
-- it. Forcing it into customer_pricing_plans (and its exactly-one-child
-- CHECK) would mismodel it. The wallet-topup and drain-rate CATALOG objects
-- ARE children of pricing_plans (so they can be priced/superseded like every
-- other plan), but the customer's wallet itself is the grants+drains ledger.
--   Consequence, stated honestly: the fixed-pack credit path
--   (013/014) is a degenerate special case of this wallet (a single,
--   fixed-quantity, non-metered grant). In a real build the two credit
--   engines SHOULD converge onto this one; I deliberately did NOT rewrite the
--   proven 013/014 path — it keeps passing untouched — but flag the
--   convergence as the recommended real-build step.
--
-- Integer paisa & integer credits everywhere. Fractional-credit dishonesty is
-- avoided by (a) requiring a top-up to be a whole multiple of the credit unit
-- price and (b) denominating drain rates as whole credits per unit of a
-- unit_of_measure chosen granular enough to stay integral (illustrative here).
-- NO now()/CURRENT_DATE anywhere — every timestamp is an explicit parameter.
--
-- New custom SQLSTATEs (continuing the ERxxx scheme from 003):
--   ER013  top-up amount is below the plan's minimum floor            -> 400
--   ER014  top-up amount is not a whole multiple of the credit price  -> 400
--   ER015  wallet-topup / drain plan is not currently sellable        -> 400
--   ER016  insufficient wallet balance for the requested drain        -> 409
--   ER017  a free-credit grant already exists for this grant_key      -> 409
--   ER018  no active drain rate for the requested (plan, sku)         -> 400

-- Record a metered drain against the wallet. Resolves the CURRENTLY active
-- rate for (plan, sku) fresh at record time (no grandfathering), computes the
-- credit debit = ROUND(quantity * credits_per_unit), and gates on sufficient
-- balance AS OF p_usage_at (ER016) before recording — never a silent negative
-- balance. (Any application-layer policy — such as a usage grace period or a
-- "never hard-stop" behavior — sits on top of this gate, out of scope for the pricing model.)

CREATE OR REPLACE FUNCTION record_wallet_drain(
    p_tenant_id UUID,
    p_platform_code VARCHAR(50),
    p_pricing_plan_id BIGINT,
    p_sku_code TEXT,
    p_usage_at TIMESTAMPTZ,
    p_quantity BIGINT,
    p_created_by TEXT
)
RETURNS wallet_drain_events AS $$
DECLARE
    v_rate RECORD;
    v_debit BIGINT;
    v_balance BIGINT;
    v_row wallet_drain_events;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    IF to_regclass('pay_config') IS NOT NULL AND EXISTS (SELECT 1 FROM pay_config WHERE config_key = 'wallet_v2:' || p_platform_code AND config_value = '1') THEN
        RAISE EXCEPTION 'platform % has migrated to wallet v2: the v1 wallet functions no longer mint or debit credit for it (wallet_drain / the capture path are the source).', p_platform_code USING ERRCODE = 'PY074';
    END IF;
    SELECT wdr.id, wdr.credits_per_unit
    INTO v_rate
    FROM wallet_drain_rates wdr
    JOIN pricing_plans pp ON pp.id = wdr.pricing_plan_id
    WHERE wdr.pricing_plan_id = p_pricing_plan_id
      AND wdr.sku_code = p_sku_code
      AND wdr.is_active = true
      AND pp.is_active = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no active drain rate for pricing_plan % sku %', p_pricing_plan_id, p_sku_code USING ERRCODE = 'ER018';
    END IF;

    v_debit := ROUND(p_quantity * v_rate.credits_per_unit::numeric);

    v_balance := get_wallet_balance(p_tenant_id, p_platform_code, p_usage_at);
    IF v_balance < v_debit THEN
        RAISE EXCEPTION 'tenant % (platform %) has insufficient wallet balance (% credits available, % required) as of %',
            p_tenant_id, p_platform_code, v_balance, v_debit, p_usage_at USING ERRCODE = 'ER016';
    END IF;

    INSERT INTO wallet_drain_events
        (tenant_id, platform_code, wallet_drain_rate_id, usage_at, quantity_consumed, credits_debited, created_at, created_by)
    VALUES
        (p_tenant_id, p_platform_code, v_rate.id, p_usage_at, p_quantity, v_debit, p_usage_at, p_created_by)
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;
