-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: pay_webhook_inbox
--
-- The durable webhook inbox. A gateway event is written here AFTER its signature has
-- been verified and BEFORE the HTTP request is acknowledged, so an accepted event can
-- never be lost: if this INSERT fails the receiver answers non-2xx and the gateway
-- redelivers.
--
--   unique (gateway_code, event_id)   a redelivered event is a no-op
--   status                            received -> applied | ignored | foreign | unattributed | failed
--     received      stored, not yet processed (or processing was interrupted)
--     applied       processed: the domain effect happened exactly once
--     ignored       a verified event this deployment has no handler for
--     foreign       an event addressed to another platform, or carrying no routing key and no order of ours at all
--                   (shared gateway account): recorded, never replayed, never alerted
--     unattributed  RESERVED for an event that carries an order reference of ours that does not resolve (or our platform
--                   code with no order); NEVER applied by guess; alerts once
--     failed        processing raised, or the signed body was unreadable; kept raw, alerts once; replayable with exponential backoff
--     dead          still failing after webhook_max_attempts / webhook_dead_after_days: TERMINAL, alerted once on that
--                   transition, never claimed or replayed again (an operator may requeue it); stops a poisoned row
--                   from starving the replay queue
--   raw_body                          exactly as received (malformed-but-signed JSON is stored raw)
--   event                             the normalised event (NULL when the body was unreadable); replay reads this,
--                                     so no re-verification or provider call is needed - the row only exists
--                                     because the signature was verified (signature_verified is always true)
--   headers                           redacted: names that look like credentials or signatures are dropped
--   locked_until                      a short lease taken by pay_webhook_claim so two deliveries (or a delivery
--                                     and a replay) never process one event at the same time
--   alert_raised_at                   stamped by pay_webhook_alert_sent() ONLY after the alert sink succeeded; the first
--                                     failed/unattributed alert is therefore retried until it really went out (once)
--   dead_alert_raised_at              the same, for the transition into 'dead'
--   body_sha256 / redacted_at         the SHA-256 of the raw body, and when _pay_webhook_redact_expired() replaced the raw
--                                     body with a minimal non-personal record after the retention period
--
-- Rows are statutory records: they are never deleted and their raw payload never changes (trigger).
-- Retention: see pay_config and _pay_webhook_redact_expired. SQLSTATEs: PY020 invalid inbox status, PY021 illegal inbox transition, PY022 inbox row is immutable.
CREATE TABLE pay_webhook_inbox (
    id                 BIGSERIAL PRIMARY KEY,
    gateway_code       TEXT NOT NULL,
    event_id           TEXT NOT NULL,
    event_type         TEXT,
    platform_code      VARCHAR(50),
    signature_verified BOOLEAN NOT NULL DEFAULT TRUE CHECK (signature_verified),
    raw_body           TEXT NOT NULL,
    body_sha256        TEXT NOT NULL,
    headers            JSONB NOT NULL DEFAULT '{}'::jsonb,
    event              JSONB,
    status             TEXT NOT NULL CHECK (status IN ('received', 'applied', 'ignored', 'foreign', 'unattributed', 'failed', 'dead')),
    attempts           INTEGER NOT NULL DEFAULT 0,
    last_error         TEXT,
    locked_until       TIMESTAMPTZ,
    alert_raised_at    TIMESTAMPTZ,
    dead_alert_raised_at TIMESTAMPTZ,
    redacted_at        TIMESTAMPTZ,
    received_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    applied_at         TIMESTAMPTZ,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (gateway_code, event_id)
);
CREATE INDEX pay_webhook_inbox_open ON pay_webhook_inbox (status, received_at)
    WHERE status IN ('received', 'failed', 'unattributed');
