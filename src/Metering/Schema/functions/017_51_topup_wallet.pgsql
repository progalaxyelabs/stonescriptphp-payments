-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: functions :: topup_wallet — split from 017_wallet_tables_and_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

-- Variable-amount top-up. Pay an arbitrary rupee amount (integer paisa), get
-- amount/credit_unit_price credits. Enforces the minimum floor (ER013) and a
-- whole-multiple rule (ER014) so we never floor-and-pocket a remainder (the
-- customer never loses paid money to rounding). Pins the unit price and, if
-- the plan sets a validity, the expiry.

CREATE OR REPLACE FUNCTION topup_wallet(
    p_tenant_id UUID,
    p_platform_code VARCHAR(50),
    p_wallet_topup_plan_id BIGINT,
    p_amount BIGINT,
    p_at TIMESTAMPTZ,
    p_created_by TEXT
)
RETURNS wallet_credit_grants AS $$
DECLARE
    v_plan RECORD;
    v_credits BIGINT;
    v_expires TIMESTAMPTZ;
    v_row wallet_credit_grants;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    IF to_regclass('pay_config') IS NOT NULL AND EXISTS (SELECT 1 FROM pay_config WHERE config_key = 'wallet_v2:' || p_platform_code AND config_value = '1') THEN
        RAISE EXCEPTION 'platform % has migrated to wallet v2: the v1 wallet functions no longer mint or debit credit for it (wallet_drain / the capture path are the source).', p_platform_code USING ERRCODE = 'PY074';
    END IF;
    SELECT wtp.id, wtp.credit_unit_price, wtp.min_topup_amount,
           wtp.credit_validity_duration, wtp.credit_validity_uom
    INTO v_plan
    FROM wallet_topup_plans wtp
    JOIN pricing_plans pp ON pp.id = wtp.pricing_plan_id
    WHERE wtp.id = p_wallet_topup_plan_id
      AND wtp.is_active = true
      AND pp.is_active = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'wallet_topup_plan % is not currently sellable (inactive or does not exist)', p_wallet_topup_plan_id USING ERRCODE = 'ER015';
    END IF;

    IF p_amount < v_plan.min_topup_amount THEN
        RAISE EXCEPTION 'top-up amount % is below the minimum of % paisa', p_amount, v_plan.min_topup_amount USING ERRCODE = 'ER013';
    END IF;

    IF p_amount % v_plan.credit_unit_price <> 0 THEN
        RAISE EXCEPTION 'top-up amount % is not a whole multiple of the credit unit price % paisa', p_amount, v_plan.credit_unit_price USING ERRCODE = 'ER014';
    END IF;

    v_credits := p_amount / v_plan.credit_unit_price;

    IF v_plan.credit_validity_duration IS NULL THEN
        v_expires := NULL;
    ELSE
        v_expires := p_at + (v_plan.credit_validity_duration || ' ' || v_plan.credit_validity_uom)::interval;
    END IF;

    INSERT INTO wallet_credit_grants
        (tenant_id, platform_code, source, wallet_topup_plan_id, granted_credits, amount_paid, unit_price_pinned, granted_at, expires_at, created_at, created_by)
    VALUES
        (p_tenant_id, p_platform_code, 'topup', v_plan.id, v_credits, p_amount, v_plan.credit_unit_price, p_at, v_expires, p_at, p_created_by)
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;
