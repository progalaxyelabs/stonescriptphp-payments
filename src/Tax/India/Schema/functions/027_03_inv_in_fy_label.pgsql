-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Tax/India :: functions :: _inv_in_fy_label
--
-- The Indian financial-year label ('26-27') of a document date. The Indian FY runs
-- 1 April - 31 March and the date is taken in IST, whatever the session time zone
-- (a UTC timestamp of 2027-03-31 20:00 is already 1 April in IST). These two facts
-- are statutory, not configuration, so they are the function's own constants.
--
-- Takes the date as an explicit argument: no now() inside.
CREATE OR REPLACE FUNCTION _inv_in_fy_label(p_at TIMESTAMPTZ)
RETURNS TEXT AS $$
DECLARE
    v_local DATE := (p_at AT TIME ZONE 'Asia/Kolkata')::DATE;
    v_start INTEGER;
BEGIN
    IF p_at IS NULL THEN
        RAISE EXCEPTION '_inv_in_fy_label: a document date is required.' USING ERRCODE = 'PY014';
    END IF;
    v_start := CASE WHEN EXTRACT(MONTH FROM v_local) >= 4
                    THEN EXTRACT(YEAR FROM v_local)::INTEGER
                    ELSE EXTRACT(YEAR FROM v_local)::INTEGER - 1 END;
    RETURN lpad((v_start % 100)::TEXT, 2, '0') || '-' || lpad(((v_start + 1) % 100)::TEXT, 2, '0');
END;
$$ LANGUAGE plpgsql STABLE;
