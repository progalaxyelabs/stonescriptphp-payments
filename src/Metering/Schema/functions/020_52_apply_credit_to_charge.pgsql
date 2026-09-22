-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: functions :: apply_credit_to_charge — split from 020_credit_ledger_tables_and_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: MONETARY credit / refund LEDGER (Case 7)
-- =====================================================================
-- renew_subscription_pricing_plan (003) COMPUTES a prorated switch credit and
-- RETURNS it, but there is nowhere to BANK it — its own comment says so
-- ("The credit is COMPUTED and RETURNED only — there is no ledger/wallet table
-- yet"). This is that ledger: a running, computed-on-read monetary balance in
-- integer paisa that banks prorated switch credits, refunds, and goodwill
-- adjustments, and is drawn down against future charges.
--
-- IMPORTANT — this is a MONEY ledger (paisa), NOT the credit WALLET (017).
-- The wallet holds prepaid product credits drained by metered usage; this
-- ledger holds rupee credit the business owes the customer (from a mid-cycle
-- downgrade, a refund, goodwill) to net against a future invoice. Different
-- unit, different purpose — deliberately separate tables.
--
-- Signed amount convention: positive = credit granted TO the customer,
-- negative = credit drawn down (applied to a charge). Balance = SUM(amount).
-- Computed on read from raw entries, never a stored running total (same
-- philosophy as the credit balances).
--
-- DESIGN NOTE — why renew_subscription_pricing_plan is NOT edited to write here
-- directly: 003 is proven and its contract (return the credit) is unchanged.
-- Banking is an explicit second step the caller threads (the test uses psql
-- \gset to feed the returned value straight in), exactly as an app layer would
-- take the returned prorated_credit_paisa and post it. In a real build renew
-- would call record_credit_ledger_entry itself inside the same transaction;
-- kept separate here to avoid touching working code mid-model.
--
-- New SQLSTATE:  ER020  credit-ledger amount must be positive  -> 400

-- Draw the ledger balance down against a charge. Applies MIN(balance, charge)
-- as a negative 'applied' entry and reports what was applied, what charge
-- remains payable, and the balance left. Never overdraws (balance floors at 0)
-- and never fails on an empty balance — it simply applies 0 and leaves the
-- whole charge payable. Charge must be positive.

CREATE OR REPLACE FUNCTION apply_credit_to_charge(
    p_tenant_id UUID,
    p_platform_code VARCHAR(50),
    p_charge_amount BIGINT,
    p_at TIMESTAMPTZ,
    p_created_by TEXT,
    p_reference TEXT DEFAULT NULL
)
RETURNS TABLE (
    applied_paisa           BIGINT,
    remaining_charge_paisa  BIGINT,
    ledger_balance_after    BIGINT
) AS $$
DECLARE
    v_balance BIGINT;
    v_applied BIGINT;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    IF p_charge_amount <= 0 THEN
        RAISE EXCEPTION 'charge amount must be positive (got %)', p_charge_amount USING ERRCODE = 'ER020';
    END IF;

    v_balance := get_credit_ledger_balance(p_tenant_id, p_platform_code, p_at);
    v_applied := LEAST(v_balance, p_charge_amount);
    IF v_applied < 0 THEN
        v_applied := 0;  -- a negative (over-applied) balance never adds to a charge
    END IF;

    IF v_applied > 0 THEN
        INSERT INTO customer_credit_ledger
            (tenant_id, platform_code, entry_type, amount, reason, reference, entry_at, created_at, created_by)
        VALUES
            (p_tenant_id, p_platform_code, 'applied', -v_applied, 'applied to charge', p_reference, p_at, p_at, p_created_by);
    END IF;

    RETURN QUERY SELECT v_applied, p_charge_amount - v_applied, v_balance - v_applied;
END;
$$ LANGUAGE plpgsql;
