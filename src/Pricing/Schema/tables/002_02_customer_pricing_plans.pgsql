-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: tables :: customer_pricing_plans — split from 002_customer_and_usage_tables.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: customers + customer_pricing_plans
-- Run inside psql already connected to invoice:
--
-- NO now()/CURRENT_DATE/CURRENT_TIME defaults (same rule as 001).

CREATE TABLE customer_pricing_plans (
    id                            BIGSERIAL PRIMARY KEY,
    -- Identity: mirrors the auth service's own tenant_memberships shape
    -- 1:1 (identity_id/tenant_id/platform_code — same names, same UUID
    -- types). Opaque values resolved from the caller's JWT/auth service —
    -- NEVER a cross-DB FK (auth lives in a separate database/schema; see
    -- the no-cross-DB-calls ecosystem law). No local surrogate id, no
    -- "customers" fixture table.
    tenant_id                     UUID NOT NULL,
    platform_code                 VARCHAR(50) NOT NULL,
    pricing_plan_id                BIGINT NOT NULL REFERENCES pricing_plans(id),
    subscription_pricing_plan_id   BIGINT REFERENCES subscription_pricing_plans(id),
    one_time_pricing_plan_id       BIGINT REFERENCES one_time_pricing_plans(id),
    consumption_pricing_plan_id    BIGINT REFERENCES consumption_pricing_plans(id), -- added: postpaid
                                    -- consumption enrollment. NOTE: unlike the other two child refs,
                                    -- this one is NOT the source of truth for pricing — it only
                                    -- records which rate was active at enrollment (informational).
                                    -- Each usage event independently resolves+pins to whatever rate
                                    -- is active AT THE TIME OF USE (no grandfathering) — see
                                    -- record_usage(). For this plan type there is only ever ONE
                                    -- customer_pricing_plans row per customer, never re-created.
    started_at                    TIMESTAMPTZ NOT NULL,
    cancelled_at                  TIMESTAMPTZ,              -- NULL = active
    cancel_reason                 TEXT,                     -- set together with cancelled_at; NULL while active
    created_at                    TIMESTAMPTZ NOT NULL,
    created_by                    TEXT NOT NULL,

    -- exactly one of the three child references must be set
    CONSTRAINT customer_pricing_plans_exactly_one_child CHECK (
        (subscription_pricing_plan_id IS NOT NULL)::int
      + (one_time_pricing_plan_id IS NOT NULL)::int
      + (consumption_pricing_plan_id IS NOT NULL)::int = 1
    )
);
