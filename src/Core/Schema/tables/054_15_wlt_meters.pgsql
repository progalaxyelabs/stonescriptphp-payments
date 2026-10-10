-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: wlt_meters, wlt_meter_ticks (wallet v2 metering)
--
-- Cumulative metering without drift. A metered resource (compute minutes, scans) reports its CUMULATIVE usage on every tick; the wallet debits
-- floor(cumulative x rate) minus what that meter has already been debited, so the total debited is always exactly floor(total usage x rate): never the
-- sum of per-tick roundings. A meter has ONE rate for life; a meter reset or a rate change starts a NEW meter_key, and the old one is retired with
-- _wlt_meter_close (closed_at). wlt_meters holds the running totals per (wallet, meter); wlt_meter_ticks makes every tick idempotent.
CREATE TABLE wlt_meters (
    id            BIGSERIAL PRIMARY KEY,
    wallet_id     BIGINT NOT NULL REFERENCES wlt_wallets(id),
    meter_key     TEXT NOT NULL CHECK (btrim(meter_key) <> ''),
    debited_milli BIGINT NOT NULL DEFAULT 0 CHECK (debited_milli >= 0),
    cumulative    NUMERIC NOT NULL DEFAULT 0 CHECK (cumulative >= 0),
    rate_num      BIGINT,
    rate_den      BIGINT,
    closed_at     TIMESTAMPTZ,
    UNIQUE (wallet_id, meter_key)
);
