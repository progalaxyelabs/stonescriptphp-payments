-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _pay_config_text (INTERNAL)
-- Reads a text setting from pay_config. A missing row is an error (PY050), never a silent default.
CREATE OR REPLACE FUNCTION _pay_config_text(p_key TEXT) RETURNS TEXT AS $$
DECLARE
    v TEXT;
BEGIN
    SELECT config_value INTO v FROM pay_config WHERE config_key = p_key;
    IF v IS NULL THEN
        RAISE EXCEPTION 'pay_config "%" is missing (run _pay_ensure_reference_data()).', p_key USING ERRCODE = 'PY050';
    END IF;
    RETURN v;
END;
$$ LANGUAGE plpgsql STABLE;
