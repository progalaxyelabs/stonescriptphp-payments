-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: _inv_assert_schema_current
--
-- The numbering functions and row guards need the columns that _pay_apply_schema_upgrades() adds to a
-- database that already held invoices (the gateway never alters an existing table). Without this
-- check a database that was deployed but not yet upgraded fails with a raw "column does not exist" /
-- "record has no field" error. This raises a clear PY040 that names the missing migration instead.
CREATE OR REPLACE FUNCTION _inv_assert_schema_current() RETURNS VOID AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_attribute a
                    WHERE a.attrelid = to_regclass('inv_invoices') AND a.attname = 'buyer_state_code' AND NOT a.attisdropped) THEN
        RAISE EXCEPTION 'the payments schema upgrade has not been applied to this database: add a platform migration that runs SELECT * FROM _pay_apply_schema_upgrades(); (and _pay_ensure_reference_data();) and re-run the gateway migrate.'
            USING ERRCODE = 'PY040';
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;
