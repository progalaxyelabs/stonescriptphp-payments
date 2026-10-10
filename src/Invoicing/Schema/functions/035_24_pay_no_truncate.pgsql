-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: pay_no_truncate
--
-- Statutory records are never truncated. Row triggers do not fire for TRUNCATE, so each retained table
-- also carries a statement-level BEFORE TRUNCATE trigger that refuses it (PY019).
CREATE OR REPLACE FUNCTION pay_no_truncate() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION '% is a retained record and cannot be truncated.', TG_TABLE_NAME USING ERRCODE = 'PY019';
END;
$$ LANGUAGE plpgsql;
