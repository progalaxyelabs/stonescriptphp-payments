-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: tables :: consumption_usage_events — split from 002_customer_and_usage_tables.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: customers + customer_pricing_plans
-- Run inside psql already connected to invoice:
--
-- NO now()/CURRENT_DATE/CURRENT_TIME defaults (same rule as 001).

-- Raw postpaid usage/metering events. Each row pins the SPECIFIC
-- consumption_pricing_plan (rate) that was active at usage_at, resolved and
-- fixed by record_usage() at the moment it's recorded — a later rate change
-- never retroactively alters an already-recorded event's price. This is what
-- get_customer_usage_charge sums over a billing period.
CREATE TABLE consumption_usage_events (
    id                          BIGSERIAL PRIMARY KEY,
    -- Identity: same shape as progalaxyelabs-auth's tenant_memberships
    -- (tenant_id UUID + platform_code VARCHAR(50)) — opaque, resolved from
    -- the JWT/auth service, no cross-DB FK, no local "customers" fixture.
    tenant_id                   UUID NOT NULL,
    platform_code               VARCHAR(50) NOT NULL,
    consumption_pricing_plan_id BIGINT NOT NULL REFERENCES consumption_pricing_plans(id),
    usage_at                    TIMESTAMPTZ NOT NULL,
    quantity_consumed           BIGINT NOT NULL CHECK (quantity_consumed > 0),
    created_at                  TIMESTAMPTZ NOT NULL,
    created_by                  TEXT NOT NULL
);
