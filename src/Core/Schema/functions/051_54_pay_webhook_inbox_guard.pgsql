-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: functions :: pay_webhook_inbox_guard
--
-- Inbox rows are retained records: never deleted, never truncated, and the evidence columns never change, with
-- ONE controlled exception: _pay_webhook_redact_expired() may replace raw_body with a minimal non-personal record
-- once, after the retention period. The guard accepts exactly that (redacted_at NULL -> set, body_sha256 unchanged,
-- the new body is a {"redacted":true,...} document, headers/event/ids untouched) AND only on the audited path: the
-- transaction must carry the pay.redacting flag that only _pay_webhook_redact_expired sets, and that function must already
-- have written the pay_webhook_redactions audit row for this very row and hash. A redaction without both is refused. Only the
-- processing state (status, attempts, last_error, lease, alert stamps, applied_at, platform_code, updated_at) moves otherwise.
CREATE OR REPLACE FUNCTION pay_webhook_inbox_guard() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'webhook inbox row % cannot be deleted: it is a retained record.', OLD.id USING ERRCODE = 'PY022';
    END IF;
    IF NEW.gateway_code IS DISTINCT FROM OLD.gateway_code OR NEW.event_id IS DISTINCT FROM OLD.event_id
       OR NEW.body_sha256 IS DISTINCT FROM OLD.body_sha256
       OR NEW.headers IS DISTINCT FROM OLD.headers
       OR NEW.event IS DISTINCT FROM OLD.event OR NEW.received_at IS DISTINCT FROM OLD.received_at
       OR NEW.signature_verified IS DISTINCT FROM OLD.signature_verified THEN
        RAISE EXCEPTION 'webhook inbox row %: the received evidence is immutable.', OLD.id USING ERRCODE = 'PY022';
    END IF;
    IF NEW.raw_body IS DISTINCT FROM OLD.raw_body OR NEW.redacted_at IS DISTINCT FROM OLD.redacted_at THEN
        IF NOT (OLD.redacted_at IS NULL AND NEW.redacted_at IS NOT NULL
                AND coalesce((NEW.raw_body::jsonb ->> 'redacted'), '') = 'true'
                AND (NEW.raw_body::jsonb ->> 'body_sha256') = OLD.body_sha256
                AND coalesce(current_setting('pay.redacting', true), '') = 'on'
                AND EXISTS (SELECT 1 FROM pay_webhook_redactions r WHERE r.inbox_id = OLD.id AND r.body_sha256 = OLD.body_sha256)) THEN
            RAISE EXCEPTION 'webhook inbox row %: the raw body can only be replaced once, by the audited redaction function.', OLD.id
                USING ERRCODE = 'PY022';
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
