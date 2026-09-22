-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: tables :: passthrough_cost_measurements — split from 019_passthrough_cost_plus.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: COST-PLUS PASSTHROUGH billing (Case 6)
-- =====================================================================
-- A cost-plus / managed-service example: the customer is billed a MEASURED
-- monthly cost (an upstream provider's landed bill, ex-tax) marked up. consumption_pricing_plans'
-- rate_per_unit cannot express this: the basis is not a fixed rate on a
-- countable unit, it is a VARIABLE measured cost that differs every period and
-- is only known after the fact. So the plan carries the MARGIN CONFIG and each
-- period a MEASUREMENT supplies the cost basis; the charge is DERIVED.
--
-- MARGIN AS CONFIG, NOT A CONSTANT: the plan stores a margin MODE +
-- PERCENTAGE as columns with sensible defaults, and the charge is derived —
-- there is NO hardcoded multiplier (× 1.10, × 1.5 …) buried in function
-- logic. The two legitimate conventions:
--   'on_cost'  (markup):       charge = COGS × (1 + pct/100)      [example: 10%]
--   'on_price' (gross margin): charge = COGS / (1 − pct/100)
-- Whichever percentage the operator wants is a one-row UPDATE to margin_pct,
-- not a code change and not a design blocker.
--
-- Integer paisa in and out; margin_pct is a NUMERIC config value (fractions
-- allowed, e.g. 3.68) — a percentage is not money. GST is added by the invoice
-- module; is_amount_tax_exclusive says the measured cost / derived charge is
-- ex-GST.
--
-- New SQLSTATE:  ER019  no active passthrough plan for this pricing_plan  -> 400

-- The variable cost basis, one row per billed period. Pins the margin config
-- active at record time (no grandfathering: re-pricing the margin never
-- rewrites an already-measured period).

CREATE TABLE passthrough_cost_measurements (
    id                          BIGSERIAL PRIMARY KEY,
    -- Identity: same shape as progalaxyelabs-auth's tenant_memberships
    -- (tenant_id UUID + platform_code VARCHAR(50)) — opaque, resolved from
    -- the JWT/auth service, no cross-DB FK, no local "customers" fixture.
    tenant_id                   UUID NOT NULL,
    platform_code               VARCHAR(50) NOT NULL,
    passthrough_pricing_plan_id BIGINT NOT NULL REFERENCES passthrough_pricing_plans(id),
    period_start                TIMESTAMPTZ NOT NULL,
    period_end                  TIMESTAMPTZ NOT NULL,
    measured_cost               BIGINT NOT NULL CHECK (measured_cost >= 0), -- integer paisa, the landed COGS
    created_at                  TIMESTAMPTZ NOT NULL,
    created_by                  TEXT NOT NULL,
    CONSTRAINT passthrough_period_order CHECK (period_end > period_start)
);
