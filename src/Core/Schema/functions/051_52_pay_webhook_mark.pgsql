-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_webhook_mark
--
-- Records the outcome of processing one inbox row and releases the lease.
--   applied | ignored | foreign        final: never processed again
--   unattributed | failed             open: replay may try again, after an exponential backoff
--                                     (webhook_backoff_base_seconds * 2^(attempts-1), capped), enforced through locked_until
--   -> dead                           an open outcome on a row at webhook_max_attempts attempts, or older than
--                                     webhook_dead_after_days, becomes 'dead': TERMINAL, never claimed or replayed again
--                                     (_pay_webhook_requeue puts it back by hand), so it cannot starve the replay queue
--
-- o_alert_kind says which alert, if any, is now due: 'webhook.failed' / 'webhook.unattributed' the first time a row
-- becomes open, 'webhook.dead' on the transition into dead; NULL otherwise ('foreign' never alerts). This function
-- does NOT stamp the alert as sent: the caller raises it and then calls pay_webhook_alert_sent(), so an alert whose
-- sink failed is retried on the next transition instead of being lost. A final row cannot change status (PY021).
CREATE OR REPLACE FUNCTION pay_webhook_mark(
    p_id            BIGINT,
    p_status        TEXT,
    p_error         TEXT DEFAULT NULL,
    p_platform_code VARCHAR(50) DEFAULT NULL
) RETURNS TABLE (o_status TEXT, o_should_alert BOOLEAN, o_alert_kind TEXT) AS $$
DECLARE
    v_row    pay_webhook_inbox;
    v_status TEXT := p_status;
    v_kind   TEXT := NULL;
    v_delay  BIGINT;
BEGIN
    IF p_status NOT IN ('applied', 'ignored', 'foreign', 'unattributed', 'failed') THEN
        RAISE EXCEPTION 'pay_webhook_mark: invalid status "%".', p_status USING ERRCODE = 'PY020';
    END IF;

    SELECT * INTO v_row FROM pay_webhook_inbox WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'webhook inbox row % does not exist.', p_id USING ERRCODE = 'PY020';
    END IF;
    IF v_row.status IN ('applied', 'ignored', 'foreign', 'dead') AND v_row.status <> p_status THEN
        RAISE EXCEPTION 'webhook inbox row % is already % and is final.', p_id, v_row.status USING ERRCODE = 'PY021';
    END IF;

    IF v_status IN ('failed', 'unattributed') THEN
        IF v_row.attempts >= _pay_config_int('webhook_max_attempts')
           OR v_row.received_at < now() - make_interval(days => _pay_config_int('webhook_dead_after_days')::int) THEN
            v_status := 'dead';
            IF v_row.dead_alert_raised_at IS NULL THEN v_kind := 'webhook.dead'; END IF;
        ELSIF v_row.alert_raised_at IS NULL THEN
            v_kind := CASE WHEN v_status = 'unattributed' THEN 'webhook.unattributed' ELSE 'webhook.failed' END;
        END IF;
        v_delay := least(_pay_config_int('webhook_backoff_base_seconds') * power(2, greatest(v_row.attempts - 1, 0))::bigint,
                         _pay_config_int('webhook_backoff_cap_seconds'));
    END IF;

    UPDATE pay_webhook_inbox SET
        status = v_status,
        last_error = CASE WHEN v_status IN ('failed', 'unattributed', 'dead') THEN p_error ELSE NULL END,
        locked_until = CASE WHEN v_status IN ('failed', 'unattributed') THEN now() + make_interval(secs => v_delay) ELSE NULL END,
        applied_at = CASE WHEN v_status = 'applied' THEN coalesce(applied_at, now()) ELSE applied_at END,
        platform_code = coalesce(p_platform_code, platform_code),
        updated_at = now()
     WHERE id = p_id;

    o_status := v_status;
    o_should_alert := v_kind IS NOT NULL;
    o_alert_kind := v_kind;
    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;
