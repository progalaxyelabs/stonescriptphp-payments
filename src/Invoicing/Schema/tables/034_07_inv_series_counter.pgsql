-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: tables :: inv_series_counter
--
-- The gapless allocator's state: one row per (series, financial-year label), the
-- last serial handed out. fy_label is '' for a series without fy_reset.
--
-- Allocation (_inv_series_allocate) increments this row under its own row lock, in
-- the SAME transaction as the invoice insert, so a rollback releases the number.
-- A Postgres SEQUENCE is deliberately never used for a statutory serial: a
-- sequence value is consumed even when the transaction rolls back.
--
-- The value only ever moves forward (trigger). It is moved forward by hand only
-- through _inv_series_adopt(), which records who, why and the evidence.
CREATE TABLE inv_series_counter (
    series_id   BIGINT NOT NULL REFERENCES inv_series(id),
    fy_label    TEXT NOT NULL,
    last_number BIGINT NOT NULL CHECK (last_number >= 0),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (series_id, fy_label)
);
