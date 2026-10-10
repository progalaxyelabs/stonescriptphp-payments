-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _pay_webhook_requeue
--
-- An operator puts a DEAD (or failed/unattributed) row back into the replay queue with a fresh attempt budget,
-- after fixing whatever made it fail. The actor and reason are written into last_error so the history is not lost.
-- Both alert stamps are cleared: the row gets a fresh attempt budget AND a fresh alert budget, so if it fails or dies again
-- somebody is told again. An applied / ignored / foreign row cannot be requeued (PY021).
-- Privileged operator action: expose it only behind the platform's admin guard.
CREATE OR REPLACE FUNCTION _pay_webhook_requeue(p_id BIGINT, p_actor TEXT, p_reason TEXT) RETURNS TEXT AS $$
DECLARE
    v_row pay_webhook_inbox;
BEGIN
    IF p_actor IS NULL OR btrim(p_actor) = '' OR p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION '_pay_webhook_requeue: actor and reason are required.' USING ERRCODE = 'PY020';
    END IF;
    SELECT * INTO v_row FROM pay_webhook_inbox WHERE id = p_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'webhook inbox row % does not exist.', p_id USING ERRCODE = 'PY020';
    END IF;
    IF v_row.status NOT IN ('dead', 'failed', 'unattributed') THEN
        RAISE EXCEPTION 'webhook inbox row % is % and cannot be requeued.', p_id, v_row.status USING ERRCODE = 'PY021';
    END IF;
    UPDATE pay_webhook_inbox SET status = 'failed', attempts = 0, locked_until = NULL, updated_at = now(),
        alert_raised_at = NULL, dead_alert_raised_at = NULL,        -- a requeued row alerts again if it fails or dies again
        last_error = 'requeued by ' || p_actor || ': ' || p_reason || ' (was: ' || coalesce(v_row.last_error, v_row.status) || ')'
     WHERE id = p_id;
    RETURN 'failed';
END;
$$ LANGUAGE plpgsql;
