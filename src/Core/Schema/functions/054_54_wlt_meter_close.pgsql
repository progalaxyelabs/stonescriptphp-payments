-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _wlt_meter_close (INTERNAL; bin/pay-wallet close-meter, or the platform's server code over a direct connection)
--
-- Retires a meter. A meter has one rate for life and cumulative usage that only grows; when the metered resource RESETS (a VM is recreated, a counter
-- restarts from zero) or its rate CHANGES, the platform closes the old meter and uses a NEW meter_key. A closed meter refuses new ticks (PY071); ticks it
-- already recorded stay idempotent. Returns true if it was open, false if it was already closed or does not exist.
CREATE OR REPLACE FUNCTION _wlt_meter_close(p_tenant_id UUID, p_platform_code VARCHAR(50), p_meter_key TEXT, p_actor TEXT) RETURNS BOOLEAN AS $$
DECLARE
    v_wallet BIGINT;
    v_n      INTEGER;
BEGIN
    IF p_meter_key IS NULL OR btrim(p_meter_key) = '' OR p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION '_wlt_meter_close: meter key and actor are required.' USING ERRCODE = 'PY070';
    END IF;
    v_wallet := _wlt_wallet_lock(p_tenant_id, p_platform_code);
    UPDATE wlt_meters SET closed_at = now() WHERE wallet_id = v_wallet AND meter_key = p_meter_key AND closed_at IS NULL;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n > 0;
END;
$$ LANGUAGE plpgsql;
