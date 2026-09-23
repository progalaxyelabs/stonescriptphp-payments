-- package: progalaxyelabs/stonescriptphp-invoice v0.5.1
-- stonescriptphp-invoice :: Invoicing :: tables :: inv_invoices — split from 034_invoice_persistence_tables.pgsql (SCOPE->BUCKET layout migration, 2026-09-14)

-- package: progalaxyelabs/stonescriptphp-invoice v0.4.1
-- stonescriptphp-invoice :: PERSISTED invoices + payments + gateway routing (DATA) +
--   status lifecycle set (DATA) + the CRM chase minimal-subset view.
--
-- This is the persistence layer that sits ON TOP of the pure GST tax-computation
-- engine (024-033). inv_compute_invoice() stays a pure calculator (STABLE, no
-- rows); inv_issue_invoice() (035) calls it and FREEZES the result into the
-- tables below. The charge side (subscription 022, wallet/overage 017/023,
-- passthrough 019, consumption 015/016) produces the amount; the GST engine adds
-- tax; this layer records the issued document, its payments, and how it settles.
--
-- ECOSYSTEM LAW honoured: every business VALUE is a DATA row, never a literal in
-- a function body — the gateways, the country->gateway routing rules, each
-- gateway's checkout endpoint, the legal status set, and the legal status
-- transitions are ALL rows here (035's functions carry only the FORMULA). Money
-- is INTEGER PAISA everywhere (024 law) — we deliberately DIVERGE from a reference
-- numeric(14,2) invoices.pgsql shape on TYPE while ALIGNING on shape/columns, because
-- the whole prototype is paisa-exact and never touches a float.
--
-- NO now()/CURRENT_DATE anywhere: every timestamp is an explicit caller param.
-- The "as-of-now" candidates for a later step-2 now() substitution are TAGGED
-- inline with the marker  [NOW-CANDIDATE]  (created_at columns and the state-
-- transition timestamps). Genuine business dates (issue_date, due_date, billing
-- period, a gateway's own captured_at) are NOT now-candidates and are so tagged.
--
-- New custom SQLSTATEs, continuing the ERxxx scheme (max in use before this file
-- was ER051; the spec's "after ER021" predates the 024-051 GST port):
--   ER052  no gateway route resolvable for the invoice's billing country   -> 400
--   ER053  invoice not found                                               -> 404
--   ER054  illegal invoice status transition                               -> 409
--   ER055  payment recorded against an already-paid invoice (dup guard)    -> 409
--   ER056  invoice is not payable from its current status                  -> 409
--   ER057  payment amount/currency does not match the invoice              -> 400
--   ER058  unknown or inactive gateway (override target or payment rail)   -> 400
--   ER059  invalid invoice status value (not a modelled status)            -> 400
--   ER060  billing_country_code is required and must be a 2-letter code    -> 400
--   ER061  invalid payment status value (expected 'success' | 'failed')    -> 400

-- =====================================================================
-- 5. INVOICES  (the FULL persisted shape)
-- =====================================================================
-- Aligned with a reference invoices.pgsql shape (identity_id, invoice_number, period,
-- taxable_value, cgst/sgst/igst, hsn_sac, status, issued_at/paid_at) — but
-- money is integer paisa, and the per-line detail is normalised into
-- inv_invoice_lines (section 6) rather than a single header SAC.
--
-- === MINIMAL vs FULL (spec req 6) ===
-- The columns tagged  [MINIMAL]  below are the ONLY subset that a CENTRAL
-- merchant-of-record system keeps, and that a central CRM reads to drive the
-- sales chase/nudge view. The full GST/line detail (everything NOT tagged
-- [MINIMAL]) stays in the issuing app's own DB. The two-DB sync of the minimal
-- subset is integration/step-2 and is NOT built here — the subset is made
-- explicit by these tags AND by the inv_crm_chase_view / inv_crm_chase_list
-- projections (section 7).

CREATE TABLE inv_invoices (
    id                      BIGSERIAL PRIMARY KEY,
    invoice_number          TEXT NOT NULL UNIQUE,   -- [MINIMAL] length/charset-valid (validated by 027 at issue)

    -- --- tenant identity ---
    -- Mirrors the auth service's own tenant_memberships shape 1:1
    -- (tenant_id UUID + platform_code VARCHAR(50) — same names, same
    -- types). Opaque values resolved from the caller's JWT/auth service —
    -- NEVER a cross-DB FK (auth lives in a separate database/schema; see
    -- the no-cross-DB-calls ecosystem law). No local surrogate id, no
    -- "customers" fixture table. `platform_code` doubles as the "which
    -- product is billing" field the merchant-of-record & CRM both need
    -- (previously a separate `platform` column — now the SAME column as
    -- auth's own tenant_memberships.platform_code, not a duplicate).
    tenant_id               UUID NOT NULL,          -- [MINIMAL]
    platform_code           VARCHAR(50) NOT NULL,   -- [MINIMAL]

    -- --- link to the charge side (what PRODUCED the amount) ---
    -- Polymorphic-by-design: the amount can come from any pricing engine, so we
    -- record WHICH engine (charge_source) + an opaque back-ref (charge_ref)
    -- rather than a hard FK per engine. Mapping:
    --   'subscription' -> customer_pricing_plans / get_postpaid_charges_due (022)
    --   'overage'      -> get_subscription_with_overage_charge (023)
    --   'consumption'  -> consumption_usage_events window (015/016)
    --   'wallet'       -> wallet debit (017)
    --   'passthrough'  -> cost-plus passthrough (019)
    charge_source           TEXT NOT NULL,
    charge_ref              TEXT,                   -- opaque ref back into the charge side (e.g. customer_pricing_plan id, usage window key)

    -- --- billing period (NULL for one-time / wallet top-ups that have no period) ---
    period_start            TIMESTAMPTZ,            -- BUSINESS INPUT (not a now-candidate)
    period_end              TIMESTAMPTZ,            -- BUSINESS INPUT (not a now-candidate)

    -- --- GST computation linkage (frozen from inv_compute_invoice, 030) ---
    document_type           TEXT NOT NULL,          -- 'tax_invoice' | 'bill_of_supply'
    tax_treatment           TEXT NOT NULL,          -- intrastate|interstate|export_lut|export_with_igst|no_tax
    place_of_supply_code    TEXT,                   -- 2-digit CBIC code, or NULL when unresolved (export)
    hsn_sac                 TEXT,                   -- header convenience (= single line's SAC); authoritative SAC is per-line
    taxable_value_minor     BIGINT NOT NULL,        -- paisa
    cgst_minor              BIGINT,                 -- paisa; NULL on a no-tax bill_of_supply
    sgst_minor              BIGINT,
    igst_minor              BIGINT,
    round_off_minor         BIGINT,                 -- optional nearest-rupee round-off
    gross_total_minor       BIGINT NOT NULL,        -- [MINIMAL] paisa the customer owes, in `currency`

    -- --- currency / fx / export statutory value ---
    currency                TEXT NOT NULL,          -- [MINIMAL] 'INR' | 'USD' ... the currency of gross_total_minor
    fx_rate                 TEXT,                   -- informational reference rate string; non-INR only
    amount_inr_minor        BIGINT,                 -- statutory INR value of a foreign invoice (from 032); NULL for INR

    -- --- billing address (the gateway routing key + GST place-of-supply axis) ---
    billing_country_code    TEXT NOT NULL,          -- ISO 3166-1 alpha-2 ('IN','US',...); routes the gateway
    billing_state_snapshot  TEXT,                   -- frozen at issue (a later address edit must not rewrite an issued doc)

    -- --- gateway ---
    gateway_override_code   TEXT REFERENCES inv_gateways(code),  -- [MINIMAL-adjacent] per-invoice override; NULL => resolve by rule

    -- --- lifecycle ---
    status                  TEXT NOT NULL REFERENCES inv_invoice_statuses(status),  -- [MINIMAL]
    due_date                TIMESTAMPTZ,            -- [MINIMAL] BUSINESS INPUT (postpaid: period_end + 30d, set by the billing layer)
    issued_at               TIMESTAMPTZ,            -- system stamp of the draft->issued edge; NULL while draft  [NOW-CANDIDATE]
    paid_at                 TIMESTAMPTZ,            -- set exactly once on due->paid; = the payment's gateway captured_at (a business input from the gateway, NOT our now)
    voided_at               TIMESTAMPTZ,            -- [NOW-CANDIDATE] set on ->void
    cancelled_at            TIMESTAMPTZ,            -- [NOW-CANDIDATE] set on ->cancelled
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),   -- [NOW-CANDIDATE]
    created_by              TEXT NOT NULL
);
CREATE INDEX inv_invoices_customer   ON inv_invoices (tenant_id, platform_code);
CREATE INDEX inv_invoices_status     ON inv_invoices (status);
CREATE INDEX inv_invoices_platform   ON inv_invoices (platform_code);
