-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: ent_entitlements
--
-- THE entitlement source of truth: one row per (tenant, platform, product) saying what the tenant is entitled to and until when.
-- The access middleware, an offline-licence reader, a scan-credit reader all read ent_get(), never a second table. The legacy
-- `subscriptions` table of the framework and `customer_pricing_plans` are NOT consulted for access: customer_pricing_plans remains
-- the pricing/plan HISTORY (written by the library in the same transaction), and the legacy table is replaced by the compatibility
-- view ent_legacy_subscriptions after _ent_import_legacy().
--
--   status      trial | active | past_due | read_only | ended | suspended
--               trial/active/ended/suspended are the facts an operator or a payment sets; past_due / read_only are SNAPSHOTS
--               written by ent_tick() and by payment restore: the effective status is always derived by _ent_effective() from the
--               facts (period end, unpaid invoices, today's date), so a missed tick never grants or denies access wrongly.
--   current_period_end  NULL = no end (a lifetime licence, or a postpaid entitlement whose access follows its invoices)
--   billing_mode        prepaid (a paid or comped period) | postpaid (monthly invoice in arrears; unpaid past the grace goes read-only)
--   billing_profile     postpaid only: series_code, mode, buyer, billing_country_code, billing_state, supply_type, hsn_sac, gst_rate,
--                       document_type, round_off, due_days. next_billing_at is when the next period is invoiced.
--   source              payment | comp | migration | trial (how it was last activated; the audit is ent_activations)
-- Rows are never deleted. SQLSTATEs: PY060 invalid entitlement request, PY061 not allowed for this entitlement, PY062 idempotency
-- key reused for a different request, PY063 immutable.
CREATE TABLE ent_entitlements (
    id                           BIGSERIAL PRIMARY KEY,
    tenant_id                    UUID NOT NULL,
    platform_code                VARCHAR(50) NOT NULL,
    product                      TEXT NOT NULL DEFAULT 'default' CHECK (product ~ '^[a-z0-9][a-z0-9_.-]{0,49}$'),
    status                       TEXT NOT NULL CHECK (status IN ('trial', 'active', 'past_due', 'read_only', 'ended', 'suspended')),
    plan_ref                     TEXT,
    subscription_pricing_plan_id BIGINT REFERENCES subscription_pricing_plans(id),
    started_at                   TIMESTAMPTZ NOT NULL,
    current_period_end           TIMESTAMPTZ,
    billing_mode                 TEXT NOT NULL DEFAULT 'prepaid' CHECK (billing_mode IN ('prepaid', 'postpaid')),
    billing_profile              JSONB,
    next_billing_at              TIMESTAMPTZ,
    source                       TEXT NOT NULL CHECK (source IN ('payment', 'comp', 'migration', 'trial')),
    created_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at                   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by                   TEXT NOT NULL,
    UNIQUE (tenant_id, platform_code, product),
    CONSTRAINT ent_postpaid_has_profile CHECK (billing_mode = 'prepaid' OR (billing_profile IS NOT NULL AND next_billing_at IS NOT NULL))
);
CREATE INDEX ent_entitlements_billing ON ent_entitlements (next_billing_at) WHERE billing_mode = 'postpaid';
CREATE INDEX ent_entitlements_period ON ent_entitlements (current_period_end) WHERE current_period_end IS NOT NULL;
