-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: tables :: inv_issuers
--
-- One row per SELLER OF RECORD: the legal entity whose name, registration and
-- GSTIN appear on the invoices it issues, and whose number series it owns.
--   * tenant_id NULL      -> a platform-level issuer (the platform operator is the seller).
--   * tenant_id NOT NULL  -> a tenant is the seller (tenant-issued invoicing).
--
-- An issued invoice SNAPSHOTS the issuer (seller_* columns on inv_invoices), so a
-- later edit of this row can never rewrite an issued document.
--
-- is_placeholder: a row created before the real legal identity is known (or in a
-- sandbox). A placeholder issuer can own TEST series only; a LIVE series refuses
-- to issue while its issuer is a placeholder (_inv_series_allocate).
--
-- Written only through _inv_issuer_upsert().
--
-- SQLSTATEs for the issuer / series / numbering objects (class PY, all 400 unless noted):
--   PY010  issuer or series not found                                    -> 404
--   PY011  series is inactive or not an invoice series                   -> 409
--   PY012  mode (live/test) missing, or different from the series' mode  -> 400
--   PY013  live series refused: issuer is a placeholder / incomplete     -> 409
--   PY014  invalid issuer or series definition                           -> 400
--   PY015  caller-supplied seller conflicts with the series' issuer      -> 400
--   PY016  invoice number supplied with a series / missing without one   -> 400
--   PY017  series exhausted or counter behind existing numbers           -> 409
--   PY018  counter moved backwards / adoption below existing numbers     -> 409
--   PY019  immutability violation on an issued invoice or a numbering row -> 409
CREATE TABLE inv_issuers (
    id                  BIGSERIAL PRIMARY KEY,
    issuer_code         TEXT NOT NULL UNIQUE CHECK (issuer_code ~ '^[a-z0-9][a-z0-9_-]{0,48}$'),
    platform_code       VARCHAR(50) NOT NULL,
    tenant_id           UUID,                       -- NULL = platform-level issuer
    legal_name          TEXT NOT NULL CHECK (btrim(legal_name) <> ''),
    registration_status TEXT NOT NULL CHECK (registration_status IN ('regular', 'composition', 'unregistered')),
    gstin               TEXT,                       -- NULL for an unregistered seller
    state_code          TEXT CHECK (state_code IS NULL OR state_code ~ '^[0-9]{2}$'),
    address             TEXT,
    is_placeholder      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by          TEXT NOT NULL,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by          TEXT NOT NULL,
    -- a real (non-placeholder) registered or composition seller must carry a GSTIN
    CONSTRAINT inv_issuers_gstin_when_real CHECK (
        is_placeholder OR registration_status = 'unregistered' OR gstin IS NOT NULL)
);
CREATE INDEX inv_issuers_owner ON inv_issuers (platform_code, tenant_id);
