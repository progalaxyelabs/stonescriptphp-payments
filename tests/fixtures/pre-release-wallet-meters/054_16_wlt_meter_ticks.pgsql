-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: wlt_meter_ticks (wallet v2 metering)
-- One row per accepted tick of a meter (see wlt_meters): makes every tick idempotent and records the delta it debited. Its own file because it
-- references wlt_drains: the gateway creates a file's tables together, in dependency order of the file.
CREATE TABLE wlt_meter_ticks (
    id          BIGSERIAL PRIMARY KEY,
    meter_id    BIGINT NOT NULL REFERENCES wlt_meters(id),
    tick_key    TEXT NOT NULL CHECK (btrim(tick_key) <> ''),
    cumulative  NUMERIC NOT NULL,
    delta_milli BIGINT NOT NULL CHECK (delta_milli >= 0),
    drain_id    BIGINT REFERENCES wlt_drains(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (meter_id, tick_key)
);
