-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: wlt_drains, wlt_drain_allocations, wlt_forfeits (wallet v2)
--
-- wlt_drains: one row per accepted debit; drain_key (the caller's tick id) is unique per wallet, so a repeated tick debits once.
-- wlt_drain_allocations: which grants a drain consumed, earliest-expiring first (FIFO by expiry, then by grant time).
-- wlt_forfeits: credit that expired unspent, reported (when it expired, how much), never deleted.
CREATE TABLE wlt_drains (
    id              BIGSERIAL PRIMARY KEY,
    wallet_id       BIGINT NOT NULL REFERENCES wlt_wallets(id),
    drain_key       TEXT NOT NULL CHECK (btrim(drain_key) <> ''),
    reason          TEXT,
    debited_milli   BIGINT NOT NULL CHECK (debited_milli > 0),
    usage_at        TIMESTAMPTZ NOT NULL,
    created_by      TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (wallet_id, drain_key)
);
CREATE TABLE wlt_drain_allocations (
    id        BIGSERIAL PRIMARY KEY,
    drain_id  BIGINT NOT NULL REFERENCES wlt_drains(id),
    grant_id  BIGINT NOT NULL REFERENCES wlt_grants(id),
    milli     BIGINT NOT NULL CHECK (milli > 0)
);
CREATE INDEX wlt_drain_allocations_drain ON wlt_drain_allocations (drain_id);
CREATE INDEX wlt_drain_allocations_grant ON wlt_drain_allocations (grant_id);
CREATE TABLE wlt_forfeits (
    id           BIGSERIAL PRIMARY KEY,
    wallet_id    BIGINT NOT NULL REFERENCES wlt_wallets(id),
    grant_id     BIGINT NOT NULL REFERENCES wlt_grants(id) UNIQUE,
    milli        BIGINT NOT NULL CHECK (milli > 0),
    expired_at   TIMESTAMPTZ NOT NULL,
    swept_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
