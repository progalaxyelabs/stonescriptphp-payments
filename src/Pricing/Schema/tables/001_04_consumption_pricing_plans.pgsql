-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: tables :: consumption_pricing_plans — split from 001_pricing_plan_tables.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: table definitions
-- Run against a local Postgres 14 instance, db "invoice", via:
--   psql -h localhost -U postgres -d invoice -f 001-tables.psql
-- or, inside an interactive psql shell already connected to invoice:
--   \i 001-tables.psql
--
-- Exactly the 3 tables, plus the one column that was missing
-- (one_time_pricing_plans.is_active). No other columns added/removed/renamed here —
-- this file is the base table definitions. Follow-up integrity refinements
-- (composite FK discriminator, immutability split, money+currency,
-- credit quantity, is_life_time/duration consistency) land in later numbered scripts.
--
-- NO now()/CURRENT_DATE/CURRENT_TIME defaults anywhere: every
-- created_at is an explicit value the caller supplies. Auto-populated defaults
-- are introduced later once the schema is proved end to end.

-- Postpaid, usage/consumption-metered pricing (e.g. a metered SaaS unit). No
-- amount to sell — a RATE per unit of measure. There is no "prepaid
-- consumption" variant here; that's the separate credit-pack system already
-- built (one_time_pricing_plans + is_credit_system). No is_post_paid column:
-- this plan type has no other mode.
CREATE TABLE consumption_pricing_plans (
    id                                  BIGSERIAL PRIMARY KEY,
    pricing_plan_id                     BIGINT NOT NULL REFERENCES pricing_plans(id),
    unit_of_measure                     TEXT NOT NULL,   -- e.g. 'compute-unit'
    rate_per_unit                       BIGINT NOT NULL, -- integer paisa per 1 unit_of_measure
    is_amount_tax_exclusive             BOOLEAN NOT NULL,
    is_active                           BOOLEAN NOT NULL DEFAULT TRUE,
    superseded_by_consumption_pricing_plan_id BIGINT REFERENCES consumption_pricing_plans(id),
    created_at                          TIMESTAMPTZ NOT NULL,
    created_by                          TEXT NOT NULL
);
