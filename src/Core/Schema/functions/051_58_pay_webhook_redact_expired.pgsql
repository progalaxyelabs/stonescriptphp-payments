-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: _pay_webhook_redact_expired
--
-- The audited retention job for raw gateway payloads. Replaces raw_body of FINAL rows (applied / ignored / foreign /
-- dead) older than pay_config 'raw_payload_retention_months' (default 13: DPDP Rules 2025 one-year floor + buffer;
-- CA/legal to confirm) with a minimal record:
--     {"redacted": true, "redacted_at": ..., "body_sha256": <hash of the original>, "event": <normalised non-personal fields>}
-- so the evidence of WHAT arrived (its hash) and the non-personal facts (payment id, order, amount, currency, tenant,
-- platform, time) survive, while whatever personal data the gateway body carried does not. Open rows (received,
-- failed, unattributed) are left alone: they are still under investigation. So is any row whose transaction has an OPEN
-- refund-queue entry or a recorded capture whose order is not paid: the raw evidence of unresolved money is kept until it is resolved. Invoices, payments and buyer snapshots
-- are accounting records and are NEVER touched by this function.
-- Each redaction is written to pay_webhook_redactions (who, when, which period) BEFORE the body is replaced, inside a
-- transaction flagged pay.redacting: the inbox guard refuses any redaction without that flag and that audit row. This is a
-- PUBLIC entry point on purpose (the retention job runs from the application's own database access) and it is safe to expose:
-- it can only redact final rows already past the retention period and never deletes anything. Returns the number redacted.
-- Run it from cron / systemd through bin/pay-purge-webhooks.
CREATE OR REPLACE FUNCTION _pay_webhook_redact_expired(p_actor TEXT, p_limit INTEGER DEFAULT 500) RETURNS INTEGER AS $$
DECLARE
    v_months INTEGER := _pay_config_int('raw_payload_retention_months')::int;
    v_row    RECORD;
    v_n      INTEGER := 0;
    v_hold   TEXT := '';
BEGIN
    IF p_actor IS NULL OR btrim(p_actor) = '' THEN
        RAISE EXCEPTION '_pay_webhook_redact_expired: actor is required.' USING ERRCODE = 'PY020';
    END IF;
    -- Evidence of unresolved money is kept: an open refund-queue entry, or a recorded capture whose order is not paid. Those
    -- tables belong to the orders feature; the exclusion is added to the query only where they exist, so this function also
    -- works in a database that has the webhook inbox but not (yet) the orders.
    IF to_regclass('pay_refund_queue') IS NOT NULL AND to_regclass('pay_orders') IS NOT NULL AND to_regclass('pay_captured_payments') IS NOT NULL THEN
        v_hold := ' AND NOT (event ->> ''gateway_txn_ref'' IS NOT NULL AND ('
               || ' EXISTS (SELECT 1 FROM pay_refund_queue q WHERE q.gateway_code = pay_webhook_inbox.gateway_code'
               || '    AND q.gateway_txn_ref = pay_webhook_inbox.event ->> ''gateway_txn_ref'' AND q.status = ''open'')'
               || ' OR EXISTS (SELECT 1 FROM pay_captured_payments c JOIN pay_orders o ON o.order_ref = c.reference'
               || '    WHERE c.gateway_code = pay_webhook_inbox.gateway_code'
               || '    AND c.gateway_txn_ref = pay_webhook_inbox.event ->> ''gateway_txn_ref'' AND o.status <> ''paid'')))';
    END IF;
    FOR v_row IN EXECUTE
        'SELECT id, body_sha256, event FROM pay_webhook_inbox'
        || ' WHERE redacted_at IS NULL AND status IN (''applied'', ''ignored'', ''foreign'', ''dead'')'
        || ' AND received_at < now() - make_interval(months => $1)' || v_hold
        || ' ORDER BY received_at LIMIT $2 FOR UPDATE SKIP LOCKED'
        USING v_months, p_limit
    LOOP
        INSERT INTO pay_webhook_redactions (inbox_id, body_sha256, retention_months, redacted_by)
        VALUES (v_row.id, v_row.body_sha256, v_months, p_actor);
        PERFORM set_config('pay.redacting', 'on', true);
        UPDATE pay_webhook_inbox SET
            raw_body = jsonb_build_object('redacted', true, 'redacted_at', now(), 'body_sha256', v_row.body_sha256, 'event', v_row.event)::text,
            redacted_at = now(), updated_at = now()
         WHERE id = v_row.id;
        PERFORM set_config('pay.redacting', 'off', true);
        v_n := v_n + 1;
    END LOOP;
    RETURN v_n;
END;
$$ LANGUAGE plpgsql;
