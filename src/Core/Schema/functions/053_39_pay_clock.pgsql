-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _pay_bound_clock, _pay_clamp_future, _pay_billing_tz (INTERNAL)
--
-- A caller-supplied moment is a business input only up to a point: the database clock is the authority for "now".
--   _pay_bound_clock(ts)   NULL -> now(); a moment further than pay_config 'pay_clock_skew_seconds' (300) from now() is REFUSED (PY064). Used where a
--                          wrong time would grant or shift entitlement (comp, status change, trial start, enrolment in the future).
--   _pay_clamp_future(ts)  a moment beyond now() + skew is clamped to it (a future usage or sweep date means nothing). Used by the wallet.
--   _pay_billing_tz()      the zone billing periods are computed in (pay_config 'billing_timezone', Asia/Kolkata), independent of the session TimeZone.
CREATE OR REPLACE FUNCTION _pay_bound_clock(p_ts TIMESTAMPTZ, p_what TEXT) RETURNS TIMESTAMPTZ AS $$
DECLARE
    v_skew BIGINT := _pay_config_int('pay_clock_skew_seconds');
BEGIN
    IF p_ts IS NULL THEN
        RETURN now();
    END IF;
    IF abs(extract(epoch FROM (p_ts - now()))) > v_skew THEN
        RAISE EXCEPTION '% (%) is more than % seconds from the database clock (%).', p_what, p_ts, v_skew, now() USING ERRCODE = 'PY064';
    END IF;
    RETURN p_ts;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE FUNCTION _pay_clamp_future(p_ts TIMESTAMPTZ) RETURNS TIMESTAMPTZ AS $$
    SELECT least(coalesce(p_ts, now()), now() + make_interval(secs => _pay_config_int('pay_clock_skew_seconds')));
$$ LANGUAGE sql STABLE;

CREATE OR REPLACE FUNCTION _pay_billing_tz() RETURNS TEXT AS $$
BEGIN
    RETURN _pay_config_text('billing_timezone');
END;
$$ LANGUAGE plpgsql STABLE;

-- _pay_db_now: the database clock, for the CLI tools (they take the moment from the database, not from the application server's clock).
CREATE OR REPLACE FUNCTION _pay_db_now() RETURNS TIMESTAMPTZ AS $$
    SELECT now();
$$ LANGUAGE sql STABLE;
