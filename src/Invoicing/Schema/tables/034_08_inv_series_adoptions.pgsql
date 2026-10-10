-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: tables :: inv_series_adoptions
--
-- Append-only audit of every manual move of a series counter (_inv_series_adopt):
-- used once per series at cutover to CONTINUE an existing numbering series, so
-- the first library-issued number is exactly last-used + 1. evidence_ref points at
-- the proof (a ledger export, a CA confirmation); it is mandatory.
CREATE TABLE inv_series_adoptions (
    id            BIGSERIAL PRIMARY KEY,
    series_id     BIGINT NOT NULL REFERENCES inv_series(id),
    fy_label      TEXT NOT NULL,
    previous_last BIGINT NOT NULL,
    adopted_last  BIGINT NOT NULL,
    evidence_ref  TEXT NOT NULL CHECK (btrim(evidence_ref) <> ''),
    adopted_by    TEXT NOT NULL CHECK (btrim(adopted_by) <> ''),
    adopted_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX inv_series_adoptions_series ON inv_series_adoptions (series_id, fy_label);
