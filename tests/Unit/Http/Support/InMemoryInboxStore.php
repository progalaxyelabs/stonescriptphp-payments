<?php

declare(strict_types=1);

namespace Tests\Http\Support;

use StoneScriptPay\Http\Webhook\InboxEntry;
use StoneScriptPay\Http\Webhook\MarkResult;
use StoneScriptPay\Http\Webhook\RecordResult;
use StoneScriptPay\Http\Webhook\WebhookInboxStore;

/**
 * In-memory WebhookInboxStore that follows the semantics of the pay_webhook_* SQL functions
 * (unique event id, claim lease, final statuses, alert once). It exists to test the ingress logic
 * without a database; the SAME behaviours are proved against the real SQL in
 * WebhookInboxPostgresTest and tests/sql/051_test_webhook_inbox.psql, so this fake cannot drift
 * silently from what ships.
 */
final class InMemoryInboxStore implements WebhookInboxStore
{
    /** @var array<int,array<string,mixed>> */
    public array $rows = [];
    private int $nextId = 1;
    /** Next N record() calls throw, simulating an unavailable database. */
    public int $failRecordTimes = 0;
    /** Next N mark() calls throw. */
    public int $failMarkTimes = 0;
    public int $recordCalls = 0;
    /** ids whose lease is currently held by "another worker" */
    public array $leased = [];
    /** webhook_max_attempts */
    public int $maxAttempts = 3;
    /** @var list<array{id:int,kind:string}> alerts stamped as delivered */
    public array $stamped = [];
    public int $failAlertSentTimes = 0;

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
        $this->recordCalls++;
        if ($this->failRecordTimes > 0) {
            $this->failRecordTimes--;
            throw new \RuntimeException('database unavailable');
        }
        foreach ($this->rows as $row) {
            if ($row['gateway'] === $gatewayCode && $row['event_id'] === $eventId) {
                return new RecordResult($row['id'], false, $row['status'], $row['attempts'], false);
            }
        }
        $id = $this->nextId++;
        $this->rows[$id] = [
            'id' => $id, 'gateway' => $gatewayCode, 'event_id' => $eventId, 'event_type' => $eventType,
            'platform_code' => $platformCode, 'raw_body' => $rawBody, 'headers' => $headers, 'event' => $event,
            'status' => $initialStatus, 'attempts' => 0, 'last_error' => $error, 'alerted' => false, 'dead_alerted' => false,
        ];

        return new RecordResult($id, true, $initialStatus, 0, $initialStatus === 'failed');
    }

    public function claim(int $id): ?InboxEntry
    {
        $r = $this->rows[$id] ?? null;
        if ($r === null || !in_array($r['status'], ['received', 'failed', 'unattributed'], true) || in_array($id, $this->leased, true)) {
            return null;
        }
        $this->rows[$id]['attempts']++;
        $this->leased[] = $id;
        $r = $this->rows[$id];

        return new InboxEntry($id, $r['gateway'], $r['event_id'], $r['event_type'], $r['status'], $r['attempts'], $r['raw_body'], $r['event']);
    }

    public function mark(int $id, string $status, ?string $error = null, ?string $platformCode = null): MarkResult
    {
        if ($this->failMarkTimes > 0) {
            $this->failMarkTimes--;
            throw new \RuntimeException('database unavailable');
        }
        $r = $this->rows[$id];
        if (in_array($r['status'], ['applied', 'ignored', 'foreign', 'dead'], true) && $r['status'] !== $status) {
            throw new \RuntimeException('row is final');
        }
        $kind = null;
        if (in_array($status, ['failed', 'unattributed'], true)) {
            if ($r['attempts'] >= $this->maxAttempts) {
                $status = 'dead';
                $kind = $r['dead_alerted'] ? null : 'webhook.dead';
            } elseif (!$r['alerted']) {
                $kind = $status === 'unattributed' ? 'webhook.unattributed' : 'webhook.failed';
            }
        }
        $this->rows[$id]['status'] = $status;
        $this->rows[$id]['last_error'] = in_array($status, ['failed', 'unattributed', 'dead'], true) ? $error : null;
        $this->rows[$id]['platform_code'] = $platformCode ?? $r['platform_code'];
        $this->leased = array_values(array_diff($this->leased, [$id]));

        return new MarkResult($status, $kind !== null, $kind);
    }

    public function alertSent(int $id, string $kind): void
    {
        if ($this->failAlertSentTimes > 0) {
            $this->failAlertSentTimes--;
            throw new \RuntimeException('database unavailable');
        }
        $this->stamped[] = ['id' => $id, 'kind' => $kind];
        if ($kind === 'webhook.dead') {
            $this->rows[$id]['dead_alerted'] = true;
        } else {
            $this->rows[$id]['alerted'] = true;
        }
    }

    public function replayCandidates(int $limit, int $staleAfterSeconds): array
    {
        $ids = [];
        foreach ($this->rows as $id => $r) {
            // tests treat every 'received' row as stale when $staleAfterSeconds is 0
            $open = in_array($r['status'], ['failed', 'unattributed'], true) || ($r['status'] === 'received' && $staleAfterSeconds === 0);
            if ($open && !in_array($id, $this->leased, true)) {
                $ids[$id] = $r['attempts'];
            }
        }
        asort($ids);      // fewest attempts first (stable: insertion order = oldest first)

        return array_slice(array_keys($ids), 0, $limit);
    }

    /** Status of the row whose gateway event-id header was $headerEventId (the dedupe key itself is the body hash). */
    public function status(string $headerEventId): ?string
    {
        foreach ($this->rows as $r) {
            if (($r['headers']['x-razorpay-event-id'] ?? null) === $headerEventId) {
                return $r['status'];
            }
        }

        return null;
    }
}
