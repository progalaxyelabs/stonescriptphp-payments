-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: ent_activations
--
-- Append-only audit of every change to an entitlement: who, why, which request, and what it linked to.
--   kind              comp | payment | trial | enroll | migration | status
--   idempotency_key   unique per (tenant, platform): a comp's per-activation key, 'pay:<order_ref>' for a payment,
--                     'legacy:<platform>:<tenant>' for an import. Replaying a key with the SAME request returns the original;
--                     the same key with a DIFFERENT request is refused (PY062). request_hash is the request's fingerprint.
--   invoice_id / payment_id   set for kind = payment; NULL for a comp (a comp never creates an invoice or a payment)
CREATE TABLE ent_activations (
    id               BIGSERIAL PRIMARY KEY,
    entitlement_id   BIGINT NOT NULL REFERENCES ent_entitlements(id),
    tenant_id        UUID NOT NULL,
    platform_code    VARCHAR(50) NOT NULL,
    product          TEXT NOT NULL,
    kind             TEXT NOT NULL CHECK (kind IN ('comp', 'payment', 'trial', 'enroll', 'migration', 'status')),
    plan_ref         TEXT,
    idempotency_key  TEXT NOT NULL CHECK (btrim(idempotency_key) <> ''),
    request_hash     TEXT NOT NULL,
    actor            TEXT NOT NULL CHECK (btrim(actor) <> ''),
    reason           TEXT,
    period_from      TIMESTAMPTZ,
    period_to        TIMESTAMPTZ,
    invoice_id       BIGINT,
    payment_id       BIGINT,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, platform_code, idempotency_key)
);
CREATE INDEX ent_activations_entitlement ON ent_activations (entitlement_id, id);
