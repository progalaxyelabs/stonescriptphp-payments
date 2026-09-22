-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: tables :: wallet_topup_plans — split from 017_wallet_tables_and_functions.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: PREPAID CREDIT WALLET drained by a metered RATE
-- =====================================================================
-- Example of a metered credit-wallet model: ONE shared credit wallet with a
-- fixed per-credit price and an optional minimum top-up; usage SKUs DRAIN the
-- wallet by metered usage at a per-SKU RATE expressed in CREDITS, not paisa.
-- A recurring add-on plan may grant credits per period.
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

-- The economics of BUYING credits (the top-up product). Variable amount:
-- the customer pays an arbitrary (multiple-of-unit) rupee amount and receives
-- amount/credit_unit_price credits. GST is pinned AT top-up via
-- is_amount_tax_exclusive (example: GST-inclusive -> false). SAC/tax
-- computation itself lives in the separate invoice module, not here.
CREATE TABLE wallet_topup_plans (
    id                          BIGSERIAL PRIMARY KEY,
    pricing_plan_id             BIGINT NOT NULL REFERENCES pricing_plans(id),
    credit_unit_price           BIGINT NOT NULL,          -- integer paisa for 1 credit (example: 4900)
    min_topup_amount            BIGINT NOT NULL,          -- integer paisa floor (example: 4900 = ₹49)
    credit_validity_duration    INTEGER,                  -- NULL = topped-up credits never expire
    credit_validity_uom         TEXT,
    is_amount_tax_exclusive     BOOLEAN NOT NULL,
    is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
    superseded_by_wallet_topup_plan_id BIGINT REFERENCES wallet_topup_plans(id),
    created_at                  TIMESTAMPTZ NOT NULL,
    created_by                  TEXT NOT NULL,
    CONSTRAINT wallet_topup_unit_price_positive CHECK (credit_unit_price > 0),
    CONSTRAINT wallet_topup_min_nonneg CHECK (min_topup_amount >= 0),
    -- validity duration and uom are set together or not at all
    CONSTRAINT wallet_topup_validity_pair CHECK ((credit_validity_duration IS NULL) = (credit_validity_uom IS NULL))
);
