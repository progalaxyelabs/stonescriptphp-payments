-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: wlt_wallets (wallet v2)
--
-- One wallet per (tenant, platform, code). The row is the LOCK: every credit, debit and expiry sweep of a wallet takes it FOR UPDATE, so
-- operations on one wallet are serialised and a balance can never be overdrawn by a race. Credits are stored as BIGINT MILLI-credits
-- (1 credit = pay_config 'wallet_milli_per_credit' = 1000 milli-credits), so a per-minute debit of a fraction of a credit is exact.
-- Wallet v2 replaces the v1 wallet_* functions as the source for pay_apply_capture; v1 remains for existing callers, deprecated.
CREATE TABLE wlt_wallets (
    id            BIGSERIAL PRIMARY KEY,
    tenant_id     UUID NOT NULL,
    platform_code VARCHAR(50) NOT NULL,
    code          TEXT NOT NULL DEFAULT 'default' CHECK (code ~ '^[a-z0-9][a-z0-9_.-]{0,49}$'),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, platform_code, code)
);
