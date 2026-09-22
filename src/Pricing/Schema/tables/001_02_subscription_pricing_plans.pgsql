-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: tables :: subscription_pricing_plans — split from 001_pricing_plan_tables.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

CREATE TABLE subscription_pricing_plans (
    id                              BIGSERIAL PRIMARY KEY,
    pricing_plan_id                 BIGINT NOT NULL REFERENCES pricing_plans(id),
    duration                        INTEGER NOT NULL,
    duration_uom                    TEXT NOT NULL,
    amount                          BIGINT NOT NULL,
    is_amount_tax_exclusive         BOOLEAN NOT NULL,
    is_post_paid                    BOOLEAN NOT NULL,
    is_active                       BOOLEAN NOT NULL DEFAULT TRUE,
    superseded_by_subscription_pricing_plan_id BIGINT REFERENCES subscription_pricing_plans(id),
    created_at                      TIMESTAMPTZ NOT NULL,
    created_by                      TEXT NOT NULL,
    -- The following two columns + CHECK constraint originated as two
    -- ALTER TABLE statements in 023_subscription_plus_overage.pgsql
    -- (Metering feature), extending this table. Folded in here — verbatim
    -- in effect — because the bucket layout's tables/ directory is
    -- declarative final-state (CREATE TABLE IF NOT EXISTS only; no ALTER
    -- TABLE files exist in bucket layout).
    included_quantity        BIGINT,   -- NULL = no bundled allowance (pure flat sub)
    included_unit_of_measure TEXT,
    CONSTRAINT subscription_included_pair CHECK ((included_quantity IS NULL) = (included_unit_of_measure IS NULL))
);
