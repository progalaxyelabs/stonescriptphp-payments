-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _pay_config_int
--
-- Reads an integer setting from pay_config. A missing or non-numeric row is an error (PY050), never a
-- silent default: a retention period or retry ceiling must be a decision, not an accident.
CREATE OR REPLACE FUNCTION _pay_config_int(p_key TEXT) RETURNS BIGINT AS $$
DECLARE
    v TEXT;
BEGIN
    SELECT config_value INTO v FROM pay_config WHERE config_key = p_key;
    IF v IS NULL OR v !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'pay_config "%" is missing or not a whole number (run _pay_ensure_reference_data()).', p_key USING ERRCODE = 'PY050';
    END IF;
    RETURN v::BIGINT;
END;
$$ LANGUAGE plpgsql STABLE;
