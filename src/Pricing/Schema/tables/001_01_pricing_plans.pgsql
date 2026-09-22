-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Pricing :: tables :: pricing_plans — split from 001_pricing_plan_tables.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

CREATE TABLE pricing_plans (
    id                          BIGSERIAL PRIMARY KEY,
    name                        TEXT NOT NULL,
    is_subscription             BOOLEAN NOT NULL,
    is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
    is_trial                    BOOLEAN NOT NULL DEFAULT FALSE, -- added: the only reliable way
                                                                 -- to identify the trial plan
                                                                 -- (never infer from amount=0 or name)
    superseded_by_pricing_plan_id BIGINT REFERENCES pricing_plans(id),
    created_at                  TIMESTAMPTZ NOT NULL,
    created_by                  TEXT NOT NULL
);

-- At most one plan may ever be marked as the trial — start_free_trial()'s
-- lookup depends on this being unambiguous.
CREATE UNIQUE INDEX pricing_plans_one_trial_only ON pricing_plans ((true)) WHERE is_trial;
