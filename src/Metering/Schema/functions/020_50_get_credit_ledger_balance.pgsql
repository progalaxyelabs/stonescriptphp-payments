-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: functions :: get_credit_ledger_balance — split from 020_credit_ledger_tables_and_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

-- Balance as of a date: sum of every entry at or before p_as_of.

CREATE OR REPLACE FUNCTION get_credit_ledger_balance(p_tenant_id UUID, p_platform_code VARCHAR(50), p_as_of TIMESTAMPTZ)
RETURNS BIGINT AS $$
DECLARE
    v_balance BIGINT;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_balance
    FROM customer_credit_ledger
    WHERE tenant_id = p_tenant_id AND platform_code = p_platform_code AND entry_at <= p_as_of;

    RETURN v_balance;
END;
$$ LANGUAGE plpgsql;
