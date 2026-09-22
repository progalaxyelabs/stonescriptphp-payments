-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Metering :: tables :: passthrough_pricing_plans — split from 019_passthrough_cost_plus.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

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

CREATE TABLE passthrough_pricing_plans (
    id                          BIGSERIAL PRIMARY KEY,
    pricing_plan_id             BIGINT NOT NULL REFERENCES pricing_plans(id),
    margin_mode                 TEXT NOT NULL DEFAULT 'on_cost',      -- 'on_cost' (markup) | 'on_price' (gross margin)
    margin_pct                  NUMERIC(9,4) NOT NULL DEFAULT 10.0000, -- editable config; default = COGS × 1.10 markup
    is_amount_tax_exclusive     BOOLEAN NOT NULL,   -- true: measured cost / derived charge is ex-GST
    is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
    superseded_by_passthrough_pricing_plan_id BIGINT REFERENCES passthrough_pricing_plans(id),
    created_at                  TIMESTAMPTZ NOT NULL,
    created_by                  TEXT NOT NULL,
    CONSTRAINT passthrough_margin_mode CHECK (margin_mode IN ('on_cost','on_price')),
    -- pct non-negative; a gross-margin (on_price) pct must be < 100 or the derivation diverges
    CONSTRAINT passthrough_margin_pct_valid CHECK (margin_pct >= 0 AND NOT (margin_mode = 'on_price' AND margin_pct >= 100))
);
CREATE UNIQUE INDEX passthrough_one_active_per_plan
    ON passthrough_pricing_plans (pricing_plan_id) WHERE is_active;
