-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: wlt_grants (wallet v2)
--
-- Credit added to a wallet. remaining_milli only ever decreases (drains, forfeiture); granted_milli never changes.
--   source        topup (bought: bound to a captured payment) | free_grant (promotional) | migration (opening balance)
--   grant_key     idempotency key, unique per wallet: 'cap:<gateway>:<txn>' for a top-up, so replaying a capture credits once
--   expires_at    NULL = never. Expired credit is no longer spendable AT that instant and is reported as forfeited (wlt_forfeits), never deleted.
--   invariant     granted_milli = remaining_milli + forfeited_milli + (what drains took from it)  - proved by _ledger_verify()
CREATE TABLE wlt_grants (
    id               BIGSERIAL PRIMARY KEY,
    wallet_id        BIGINT NOT NULL REFERENCES wlt_wallets(id),
    source           TEXT NOT NULL CHECK (source IN ('topup', 'free_grant', 'migration')),
    granted_milli    BIGINT NOT NULL CHECK (granted_milli > 0),
    remaining_milli  BIGINT NOT NULL CHECK (remaining_milli >= 0),
    forfeited_milli  BIGINT NOT NULL DEFAULT 0 CHECK (forfeited_milli >= 0),
    amount_paid      BIGINT NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
    unit_price_pinned BIGINT,
    grant_key        TEXT NOT NULL CHECK (btrim(grant_key) <> ''),
    gateway_code     TEXT,
    gateway_txn_ref  TEXT,
    granted_at       TIMESTAMPTZ NOT NULL,
    expires_at       TIMESTAMPTZ,
    created_by       TEXT NOT NULL,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    request_hash     TEXT NOT NULL,
    UNIQUE (wallet_id, grant_key),
    CONSTRAINT wlt_grants_parts CHECK (remaining_milli + forfeited_milli <= granted_milli),
    CONSTRAINT wlt_grants_expiry_after_grant CHECK (expires_at IS NULL OR expires_at > granted_at)
);
CREATE UNIQUE INDEX wlt_grants_capture ON wlt_grants (gateway_code, gateway_txn_ref) WHERE gateway_txn_ref IS NOT NULL;
CREATE INDEX wlt_grants_spendable ON wlt_grants (wallet_id, expires_at NULLS LAST, granted_at, id) WHERE remaining_milli > 0;
