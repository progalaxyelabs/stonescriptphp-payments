-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: tables :: pay_webhook_redactions
-- Every redaction is audited here (append-only).
CREATE TABLE pay_webhook_redactions (
    id               BIGSERIAL PRIMARY KEY,
    inbox_id         BIGINT NOT NULL REFERENCES pay_webhook_inbox(id),
    body_sha256      TEXT NOT NULL,
    retention_months INTEGER NOT NULL,
    redacted_by      TEXT NOT NULL,
    redacted_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
