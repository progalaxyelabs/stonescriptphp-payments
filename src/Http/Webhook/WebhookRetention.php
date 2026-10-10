<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/**
 * The privacy retention job for stored webhook payloads: calls _pay_webhook_redact_expired(), which replaces the raw body of
 * FINAL rows older than the configured retention (pay_config 'raw_payload_retention_months', default 13 months) with a
 * minimal non-personal record, writing an audit row per redaction. Invoices, payments and buyer snapshots are accounting
 * records (statutory, 8 financial years) and are never touched by this.
 *
 * It wraps the INTERNAL function _pay_webhook_redact_expired, so it needs a SqlFunctionCaller over a DIRECT database connection (the
 * platform's own credentials on the server), never the gateway's /call, which refuses internal functions. Run it through
 * bin/pay-purge-webhooks.
 */
final class WebhookRetention
{
    public function __construct(private readonly SqlFunctionCaller $db) {}

    /** @return int rows redacted in this run (call again while it equals $limit) */
    public function redactExpired(string $actor, int $limit = 500): int
    {
        $rows = $this->db->call('_pay_webhook_redact_expired', [$actor, $limit]);

        return (int) (array_values($rows[0] ?? ['n' => 0])[0] ?? 0);
    }
}
