-- package: progalaxyelabs/stonescriptphp-payments
-- stonescriptphp-payments :: Core :: seeders :: pay_config
--
-- LEGAL BASES (CA / legal to confirm every period below before production use):
--   * raw_payload_retention_months = 13. Raw gateway payloads (webhook bodies) can carry personal data of the
--     payer. The DPDP Rules 2025 impose a MINIMUM one-year retention for personal data, traffic data and
--     processing logs; 13 months is that floor plus a buffer and also covers card-dispute windows. After it,
--     _pay_webhook_redact_expired() redacts the raw body (keeping its SHA-256 and the non-personal normalised
--     fields). The period is an OWNER decision; this is the default.
--   * accounting_record_retention_years = 8. Invoices, payments and accounting records (including the buyer
--     snapshot on an invoice) are NEVER redacted by that job: they are statutory (Companies Act s.128, eight
--     financial years; CGST s.36 for the GST side). Recorded here so the figure lives in one documented place;
--     no function deletes or redacts these records at all.
--   * webhook_max_attempts / webhook_dead_after_days: a row that keeps failing or staying unattributed is
--     retried with exponential backoff, then declared 'dead' (terminal, alerted once) after this many attempts
--     or days, so it can never starve the replay queue.
INSERT INTO pay_config (config_key, config_value, note) VALUES
    ('raw_payload_retention_months', '13',
        'Raw webhook bodies are redacted after this many months (DPDP Rules 2025 one-year floor + buffer). CA/legal to confirm.'),
    ('accounting_record_retention_years', '8',
        'Invoices, payments and buyer snapshots are never redacted by the payload job (Companies Act s.128). CA/legal to confirm.'),
    ('webhook_max_attempts', '8',
        'Attempts after which a still-failing inbox row is declared dead.'),
    ('webhook_dead_after_days', '14',
        'Age in days after which a still-open inbox row is declared dead on its next failure.'),
    ('webhook_backoff_base_seconds', '60',
        'First retry delay; doubles with every attempt.'),
    ('webhook_backoff_cap_seconds', '21600',
        'Upper bound of the retry delay (6 hours).'),
    ('refund_queue_alert_after_days', '3',
        'An open pay_refund_queue entry older than this many days raises an ageing alert: real money must not sit unrefunded unnoticed.'),
    ('refund_queue_alert_repeat_hours', '24',
        'An open entry that stays open is re-alerted at most this often.'),
    ('ent_past_due_after_days', '0',
        'A postpaid entitlement is past_due (writes still allowed, a warning) once an invoice is unpaid this many days after its due date.'),
    ('ent_read_only_after_days', '30',
        'A postpaid entitlement goes read-only once an invoice is unpaid this many days after its due date (billing model: 30 days). Paying restores it at once.'),
    ('ent_missing_mode', 'read_only',
        'What a tenant with NO entitlement row gets: read_only (the framework default) or allow.'),
    ('pay_clock_skew_seconds', '300',
        'A caller-supplied moment (a comp, a trial start, a drain, a sweep) may differ from the database clock by at most this many seconds; beyond it the call is refused (entitlement) or clamped (wallet). Tests widen it.'),
    ('billing_timezone', 'Asia/Kolkata',
        'The zone in which billing periods are computed (anchor + n x interval), independent of the session TimeZone. India, the billing jurisdiction.'),
    ('ent_late_apply_grace_hours', '24',
        'A paid period is anchored at the capture time when applied within this many hours; applied later (a backlog, a replay) it is anchored at the apply time, so lateness never costs the customer paid time.'),
    ('ent_billing_backoff_base_seconds', '300',
        'First retry delay for a postpaid entitlement whose invoicing failed; doubles with each failure.'),
    ('ent_billing_backoff_cap_seconds', '86400',
        'Upper bound of that retry delay (one day).'),
    ('ent_billing_catchup_max_periods', '12',
        'The most periods one billing run invoices for one entitlement that is behind.'),
    ('wallet_milli_per_credit', '1000',
        'Wallet v2 stores credit as milli-credits; this is the display unit, defined once: 1 credit = this many milli-credits.'),
    ('wallet_expiry_enforced', '0',
        'POLICY SWITCH (customer terms pending; CA/legal to confirm): 0 = purchased credit never expires; 1 = a top-up expires after its plan validity. Free grants with an explicit expiry always expire.');
