-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Invoicing :: functions :: _inv_series_format_number
--
-- number = prefix || sep || [ fy_label || sep ] || lpad(seq, width, '0'). The one
-- place a series' number is formatted. Validates the result with the same lawful
-- check (length, charset) every other number goes through.
CREATE OR REPLACE FUNCTION _inv_series_format_number(
    p_prefix TEXT, p_sep TEXT, p_width INTEGER, p_fy_reset BOOLEAN, p_fy_label TEXT, p_seq BIGINT
) RETURNS TEXT AS $$
DECLARE
    v_number TEXT;
BEGIN
    IF p_seq IS NULL OR p_seq < 1 THEN
        RAISE EXCEPTION 'a serial must be a positive integer - the first lawful serial is 1.' USING ERRCODE = 'PY014';
    END IF;
    IF p_seq >= power(10, p_width)::BIGINT THEN
        RAISE EXCEPTION 'serial % does not fit the series width % (max %).', p_seq, p_width, power(10, p_width)::BIGINT - 1
            USING ERRCODE = 'PY017';
    END IF;
    v_number := p_prefix || p_sep
        || CASE WHEN p_fy_reset THEN p_fy_label || p_sep ELSE '' END
        || lpad(p_seq::TEXT, p_width, '0');
    PERFORM inv_number_assert_lawful(v_number);
    RETURN v_number;
END;
$$ LANGUAGE plpgsql STABLE;
