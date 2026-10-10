-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_webhook_record
--
-- THE DURABILITY POINT. Stores a signature-verified gateway event, once. The caller acknowledges the HTTP
-- request only after this returns.
--
--   * event_id is the caller's DEDUPE KEY. The PHP ingress derives it from the SHA-256 of the raw body, which
--     the gateway's signature covers, never from an unsigned header: a header can be forged to pre-empt or
--     bypass dedupe, the signed bytes cannot. A redelivered (gateway_code, event_id) inserts nothing and
--     reports o_is_new = false with the row's CURRENT status.
--   * p_initial_status is 'received' normally. A signed body that could not be parsed is stored raw as 'failed'
--     with its error (it can never be silently dropped); o_should_alert is true on the call that created it. The
--     alert is stamped as sent by pay_webhook_alert_sent() only after the sink succeeds.
--   * Headers are redacted here as well as by the caller: any name that looks like a credential or a signature
--     is dropped before storage. The SHA-256 of the raw body is stored for the retention/redaction process.
-- p_headers and p_event are JSON TEXT (cast to jsonb here), so the caller never depends on how a transport types a
-- jsonb parameter. Either may be NULL. p_event must hold NORMALISED fields only (no personal data): it outlives
-- the raw body.
CREATE OR REPLACE FUNCTION pay_webhook_record(
    p_gateway_code   TEXT,
    p_event_id       TEXT,
    p_event_type     TEXT,
    p_platform_code  VARCHAR(50),
    p_raw_body       TEXT,
    p_headers        TEXT,
    p_event          TEXT,
    p_initial_status TEXT DEFAULT 'received',
    p_error          TEXT DEFAULT NULL
) RETURNS TABLE (o_id BIGINT, o_is_new BOOLEAN, o_status TEXT, o_attempts INTEGER, o_should_alert BOOLEAN) AS $$
DECLARE
    v_headers JSONB;
    v_row     pay_webhook_inbox;
BEGIN
    IF p_gateway_code IS NULL OR btrim(p_gateway_code) = '' OR p_event_id IS NULL OR btrim(p_event_id) = '' THEN
        RAISE EXCEPTION 'pay_webhook_record: gateway_code and event_id are required.' USING ERRCODE = 'PY020';
    END IF;
    IF p_raw_body IS NULL THEN
        RAISE EXCEPTION 'pay_webhook_record: the raw body is required.' USING ERRCODE = 'PY020';
    END IF;
    IF p_initial_status NOT IN ('received', 'failed') THEN
        RAISE EXCEPTION 'pay_webhook_record: a new event is stored as ''received'' or ''failed'' (got "%").', p_initial_status
            USING ERRCODE = 'PY020';
    END IF;

    v_headers := coalesce((
        SELECT jsonb_object_agg(lower(e.key), e.value)
          FROM jsonb_each(coalesce(p_headers::jsonb, '{}'::jsonb)) e
         WHERE lower(e.key) !~ '(authorization|cookie|sig|secret|token|key|password)'
    ), '{}'::jsonb);

    INSERT INTO pay_webhook_inbox (gateway_code, event_id, event_type, platform_code, raw_body, body_sha256, headers, event,
                                   status, last_error)
    VALUES (p_gateway_code, p_event_id, p_event_type, p_platform_code, p_raw_body,
            encode(sha256(convert_to(p_raw_body, 'UTF8')), 'hex'), v_headers, p_event::jsonb,
            p_initial_status, p_error)
    ON CONFLICT (gateway_code, event_id) DO NOTHING
    RETURNING * INTO v_row;

    IF FOUND THEN
        o_id := v_row.id; o_is_new := TRUE; o_status := v_row.status; o_attempts := v_row.attempts;
        o_should_alert := (p_initial_status = 'failed');
        RETURN NEXT;
        RETURN;
    END IF;

    SELECT * INTO v_row FROM pay_webhook_inbox WHERE gateway_code = p_gateway_code AND event_id = p_event_id;
    o_id := v_row.id; o_is_new := FALSE; o_status := v_row.status; o_attempts := v_row.attempts;
    o_should_alert := FALSE;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
