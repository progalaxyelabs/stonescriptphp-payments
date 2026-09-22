-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: functions :: record_credit_ledger_entry — split from 020_credit_ledger_tables_and_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

-- Bank a positive credit (a prorated switch credit, a refund, a goodwill
-- adjustment). Drawdowns go through apply_credit_to_charge, not here, so this
-- only ever accepts a positive amount (ER020 otherwise).

CREATE OR REPLACE FUNCTION record_credit_ledger_entry(
    p_tenant_id UUID,
    p_platform_code VARCHAR(50),
    p_amount BIGINT,
    p_entry_type TEXT,
    p_reason TEXT,
    p_reference TEXT,
    p_entry_at TIMESTAMPTZ,
    p_created_by TEXT
)
RETURNS customer_credit_ledger AS $$
DECLARE
    v_row customer_credit_ledger;
BEGIN
    IF p_tenant_id IS NULL OR p_platform_code IS NULL OR p_platform_code = '' THEN
        RAISE EXCEPTION 'tenant_id and platform_code are required' USING ERRCODE = 'ER001';
    END IF;

    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'credit-ledger entry must be a positive amount (got %); use apply_credit_to_charge to draw down', p_amount USING ERRCODE = 'ER020';
    END IF;

    IF p_entry_type = 'applied' THEN
        RAISE EXCEPTION 'entry_type ''applied'' is reserved for apply_credit_to_charge' USING ERRCODE = 'ER020';
    END IF;

    INSERT INTO customer_credit_ledger
        (tenant_id, platform_code, entry_type, amount, reason, reference, entry_at, created_at, created_by)
    VALUES
        (p_tenant_id, p_platform_code, p_entry_type, p_amount, p_reason, p_reference, p_entry_at, p_entry_at, p_created_by)
    RETURNING * INTO v_row;

    RETURN v_row;
END;
$$ LANGUAGE plpgsql;
