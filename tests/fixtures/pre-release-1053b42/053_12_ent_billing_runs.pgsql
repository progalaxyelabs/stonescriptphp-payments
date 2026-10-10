-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: ent_billing_runs
--
-- One row per postpaid billing period that was invoiced: (entitlement, period start) is unique, so a concurrent or repeated run can never
-- bill a period twice. Links the entitlement to the invoice it owes (the invoice's payment restores access). Append-only.
CREATE TABLE ent_billing_runs (
    id             BIGSERIAL PRIMARY KEY,
    entitlement_id BIGINT NOT NULL REFERENCES ent_entitlements(id),
    period_start   TIMESTAMPTZ NOT NULL,
    period_end     TIMESTAMPTZ NOT NULL,
    invoice_id     BIGINT NOT NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (entitlement_id, period_start),
    UNIQUE (invoice_id)
);
