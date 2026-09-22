-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: functions :: get_wallet_balance — split from 017_wallet_tables_and_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

-- Balance as of any date, computed fresh from raw grants and drains every
-- time. FIFO: grants deplete soonest-expiring first (a NULL-expiry grant is
-- effectively 'infinity' and sorts LAST, so expiring credits are spent before
-- perpetual ones — the customer-favouring order). A grant that reaches its
-- own expiry with credits left forfeits them (excluded from balance the moment
-- p_as_of passes its expiry), and cannot be drawn from by a drain recorded
-- after it expired. Mirrors get_customer_credit_balance exactly.

CREATE OR REPLACE FUNCTION get_wallet_balance(p_tenant_id UUID, p_platform_code VARCHAR(50), p_as_of TIMESTAMPTZ)
RETURNS BIGINT AS $$
DECLARE
    v_grant RECORD;
    v_event RECORD;
    v_remaining BIGINT[] := '{}';
    v_granted   TIMESTAMPTZ[] := '{}';
    v_expires   TIMESTAMPTZ[] := '{}';
    v_need BIGINT;
    v_take BIGINT;
    i INT;
    v_balance BIGINT := 0;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    FOR v_grant IN
        SELECT granted_credits, granted_at,
               COALESCE(expires_at, 'infinity'::timestamptz) AS expires_at
        FROM wallet_credit_grants
        WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code
          AND granted_at <= p_as_of
        ORDER BY COALESCE(expires_at, 'infinity'::timestamptz) ASC, granted_at ASC
    LOOP
        v_remaining := array_append(v_remaining, v_grant.granted_credits);
        v_granted   := array_append(v_granted, v_grant.granted_at);
        v_expires   := array_append(v_expires, v_grant.expires_at);
    END LOOP;

    FOR v_event IN
        SELECT usage_at, credits_debited
        FROM wallet_drain_events
        WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND usage_at <= p_as_of
        ORDER BY usage_at ASC
    LOOP
        v_need := v_event.credits_debited;
        i := 1;
        WHILE v_need > 0 AND i <= COALESCE(array_length(v_remaining, 1), 0) LOOP
            -- a grant is drawable by this drain only while it is LIVE at the
            -- drain time: granted at/before it AND not yet expired.
            IF v_remaining[i] > 0
               AND v_granted[i] <= v_event.usage_at
               AND v_expires[i] > v_event.usage_at THEN
                v_take := LEAST(v_need, v_remaining[i]);
                v_remaining[i] := v_remaining[i] - v_take;
                v_need := v_need - v_take;
            END IF;
            i := i + 1;
        END LOOP;
    END LOOP;

    FOR i IN 1..COALESCE(array_length(v_remaining, 1), 0) LOOP
        IF v_expires[i] > p_as_of THEN
            v_balance := v_balance + v_remaining[i];
        END IF;
    END LOOP;

    RETURN v_balance;
END;
$$ LANGUAGE plpgsql;
