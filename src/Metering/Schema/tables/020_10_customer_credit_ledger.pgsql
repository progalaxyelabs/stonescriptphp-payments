-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: tables :: customer_credit_ledger — split from 020_credit_ledger_tables_and_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

CREATE TABLE customer_credit_ledger (
    id              BIGSERIAL PRIMARY KEY,
    -- Identity: same shape as progalaxyelabs-auth's tenant_memberships
    -- (tenant_id UUID + platform_code VARCHAR(50)) — opaque, resolved from
    -- the JWT/auth service, no cross-DB FK, no local "customers" fixture.
    tenant_id       UUID NOT NULL,
    platform_code   VARCHAR(50) NOT NULL,
    entry_type      TEXT NOT NULL,   -- 'proration_credit' | 'refund' | 'adjustment' | 'applied'
    amount          BIGINT NOT NULL, -- signed integer paisa (+ = credit to customer, - = applied)
    reason          TEXT,
    reference       TEXT,            -- free-form link (e.g. 'cpp:12', 'invoice:INV-...')
    entry_at        TIMESTAMPTZ NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL,
    created_by      TEXT NOT NULL,
    CONSTRAINT credit_ledger_amount_nonzero CHECK (amount <> 0),
    CONSTRAINT credit_ledger_type CHECK (entry_type IN ('proration_credit','refund','adjustment','applied'))
);
