-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_webhook_alert_sent
--
-- Stamps an inbox alert as delivered. The caller invokes it ONLY after the alert sink succeeded, so an alert whose
-- sink failed stays due and is raised again on the next transition: never lost, never raised twice for one transition.
--   'webhook.failed' | 'webhook.unattributed' | 'webhook.malformed'   -> alert_raised_at
--   'webhook.dead'                                                      -> dead_alert_raised_at
CREATE OR REPLACE FUNCTION pay_webhook_alert_sent(p_id BIGINT, p_kind TEXT) RETURNS VOID AS $$
BEGIN
    IF p_kind = 'webhook.dead' THEN
        UPDATE pay_webhook_inbox SET dead_alert_raised_at = coalesce(dead_alert_raised_at, now()), updated_at = now() WHERE id = p_id;
    ELSIF p_kind IN ('webhook.failed', 'webhook.unattributed', 'webhook.malformed') THEN
        UPDATE pay_webhook_inbox SET alert_raised_at = coalesce(alert_raised_at, now()), updated_at = now() WHERE id = p_id;
    ELSE
        RAISE EXCEPTION 'pay_webhook_alert_sent: unknown alert kind "%".', p_kind USING ERRCODE = 'PY020';
    END IF;
END;
$$ LANGUAGE plpgsql;
