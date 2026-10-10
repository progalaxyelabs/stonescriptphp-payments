<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/**
 * Persistence port of the durable webhook inbox. The only implementation shipped is
 * SqlWebhookInboxStore (the pay_webhook_* SQL functions); the interface exists so the
 * ingress logic is testable without a database and so a platform can wrap it.
 *
 * Every method THROWS on any persistence failure. Callers must never treat "could not
 * store" as success: the ingress turns a record() failure into a non-2xx response so the
 * gateway redelivers.
 */
interface WebhookInboxStore
{
    /**
     * Store a signature-verified event once. A redelivered (gateway, eventId) stores nothing and
     * reports isNew = false with the row's current status.
     *
     * @param array<string,string> $headers  Already reduced to a safe set by the caller.
     * @param ?array<string,mixed> $event    WebhookEvent::toArray(), or null for an unreadable body.
     * @param string $initialStatus          'received', or 'failed' for a signed-but-unreadable body.
     */
    public function record(
        string $gatewayCode,
        string $eventId,
        ?string $eventType,
        ?string $platformCode,
        string $rawBody,
        array $headers,
        ?array $event,
        string $initialStatus = 'received',
        ?string $error = null,
    ): RecordResult;

    /** Take a processing lease on a row; null when it is final or leased by another worker. */
    public function claim(int $id): ?InboxEntry;

    /** Record the outcome and release the lease. */
    public function mark(int $id, string $status, ?string $error = null, ?string $platformCode = null): MarkResult;

    /**
     * Stamp an alert as delivered. Called ONLY after the alert sink succeeded, so an alert whose sink failed stays due
     * and is raised again on the next transition.
     */
    public function alertSent(int $id, string $kind): void;

    /**
     * Ids a replay should re-drive (failed, unattributed, and stale 'received'), fewest attempts first then oldest; 'dead' rows are never listed.
     *
     * @return list<int>
     */
    public function replayCandidates(int $limit, int $staleAfterSeconds): array;
}
