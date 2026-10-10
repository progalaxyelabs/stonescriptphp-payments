<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/**
 * WebhookInboxStore over the pay_webhook_* SQL functions. Pure marshalling: every decision
 * (dedupe, lease, alert-once, finality) is made in SQL.
 *
 * JSON travels as TEXT and booleans are read tolerantly ('t'/'f' as well as real booleans),
 * so the store does not depend on how a transport types jsonb or boolean values.
 */
final class SqlWebhookInboxStore implements WebhookInboxStore
{
    public function __construct(private readonly SqlFunctionCaller $db) {}

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
    ): RecordResult {
        $rows = $this->db->call('pay_webhook_record', [
            $gatewayCode,
            $eventId,
            $eventType,
            $platformCode,
            $rawBody,
            json_encode($headers === [] ? new \stdClass() : $headers, JSON_THROW_ON_ERROR),
            $event === null ? null : json_encode($event, JSON_THROW_ON_ERROR | JSON_INVALID_UTF8_SUBSTITUTE),
            $initialStatus,
            $error,
        ]);
        $r = $rows[0] ?? throw new \RuntimeException('pay_webhook_record returned no row: the event was NOT stored.');

        return new RecordResult(
            id: (int) $r['o_id'],
            isNew: self::bool($r['o_is_new']),
            status: (string) $r['o_status'],
            attempts: (int) $r['o_attempts'],
            shouldAlert: self::bool($r['o_should_alert']),
        );
    }

    public function claim(int $id): ?InboxEntry
    {
        $rows = $this->db->call('pay_webhook_claim', [$id, 120]);
        if ($rows === []) {
            return null;
        }
        $r = $rows[0];
        $event = null;
        if (isset($r['o_event']) && $r['o_event'] !== '') {
            $decoded = is_array($r['o_event']) ? $r['o_event'] : json_decode((string) $r['o_event'], true);
            $event = is_array($decoded) ? $decoded : null;
        }

        return new InboxEntry(
            id: (int) $r['o_id'],
            gatewayCode: (string) $r['o_gateway_code'],
            eventId: (string) $r['o_event_id'],
            eventType: isset($r['o_event_type']) ? (string) $r['o_event_type'] : null,
            status: (string) $r['o_status'],
            attempts: (int) $r['o_attempts'],
            rawBody: (string) ($r['o_raw_body'] ?? ''),
            event: $event,
        );
    }

    public function mark(int $id, string $status, ?string $error = null, ?string $platformCode = null): MarkResult
    {
        $rows = $this->db->call('pay_webhook_mark', [$id, $status, $error, $platformCode]);
        $r = $rows[0] ?? throw new \RuntimeException('pay_webhook_mark returned no row.');

        return new MarkResult(
            (string) $r['o_status'],
            self::bool($r['o_should_alert']),
            isset($r['o_alert_kind']) && $r['o_alert_kind'] !== '' ? (string) $r['o_alert_kind'] : null,
        );
    }

    public function alertSent(int $id, string $kind): void
    {
        $this->db->call('pay_webhook_alert_sent', [$id, $kind]);
    }

    public function replayCandidates(int $limit, int $staleAfterSeconds): array
    {
        $rows = $this->db->call('pay_webhook_replay_candidates', [$limit, $staleAfterSeconds]);

        return array_map(static fn(array $r): int => (int) $r['o_id'], $rows);
    }

    private static function bool(mixed $v): bool
    {
        return $v === true || $v === 1 || $v === '1' || $v === 't' || $v === 'true' || $v === 'TRUE';
    }
}
