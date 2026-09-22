-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: tables :: credit_consumptions — split from 002_customer_and_usage_tables.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: customers + customer_pricing_plans
-- Run inside psql already connected to invoice:
--
-- NO now()/CURRENT_DATE/CURRENT_TIME defaults (same rule as 001).

-- Raw consumption events against a customer's credit-pack purchases (each
-- purchase is just a customer_pricing_plans row against a credit-system
-- one_time_pricing_plan — no separate "batch" table needed). No reference
-- to a specific purchase batch here: balance/allocation is always computed
-- on read (get_customer_credit_balance), FIFO by soonest-expiring batch —
-- this table only records WHAT was consumed and WHEN.
CREATE TABLE credit_consumptions (
    id                 BIGSERIAL PRIMARY KEY,
    -- Identity: same shape as progalaxyelabs-auth's tenant_memberships
    -- (tenant_id UUID + platform_code VARCHAR(50)) — opaque, resolved from
    -- the JWT/auth service, no cross-DB FK, no local "customers" fixture.
    tenant_id          UUID NOT NULL,
    platform_code      VARCHAR(50) NOT NULL,
    consumed_at        TIMESTAMPTZ NOT NULL,
    credits_consumed   BIGINT NOT NULL CHECK (credits_consumed > 0),
    created_at         TIMESTAMPTZ NOT NULL,
    created_by         TEXT NOT NULL
);
