<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

use StoneScriptPay\DTO\WebhookEvent;

/**
 * claim -> process -> record the outcome -> alert once. The single place an inbox row is
 * driven to an outcome, shared by the live ingress and the replayer so they cannot diverge.
 */
final class InboxRunner
{
    public function __construct(
        private readonly WebhookInboxStore $store,
        private readonly WebhookProcessor $processor,
        private readonly AlertSink $alerts,
    ) {}

    /**
     * @return ?string The final status, or null when the row could not be claimed (it is final,
     *                 or another worker holds it). Never throws for a processing failure: that
     *                 becomes status 'failed'. A failure to RECORD the outcome is logged and
     *                 leaves the row 'received' (replayable once its lease expires).
     */
    public function run(int $id): ?string
    {
        $entry = $this->store->claim($id);
        if ($entry === null) {
            return null;
        }

        if ($entry->event === null) {
            return $this->finish($entry, 'failed', 'the stored body was unreadable, so there is no event to process', null);
        }

        try {
            $result = $this->processor->process($entry, WebhookEvent::fromArray($entry->event));
        } catch (\Throwable $e) {
            return $this->finish($entry, 'failed', mb_substr(get_class($e) . ': ' . $e->getMessage(), 0, 2000), null);
        }

        return $this->finish($entry, $result->status, $result->detail, $result->platformCode);
    }

    private function finish(InboxEntry $entry, string $status, ?string $detail, ?string $platformCode): string
    {
        try {
            $m = $this->store->mark($entry->id, $status, $detail, $platformCode);
        } catch (\Throwable $e) {
            error_log("[payments] inbox {$entry->id}: outcome '{$status}' could not be recorded: " . $e->getMessage());
            return 'received';
        }
        if ($m->shouldAlert && $m->alertKind !== null) {
            $this->alert($m->alertKind, $entry, (string) $detail);
        }

        return $m->status;
    }

    /**
     * Raise the alert, and mark it delivered ONLY if the sink succeeded: a failing sink leaves the alert due (it is
     * raised again at the next transition) instead of silently consuming it.
     */
    private function alert(string $kind, InboxEntry $entry, string $detail): void
    {
        try {
            $this->alerts->alert($kind, $entry->id, $entry->gatewayCode, $entry->eventId, $detail);
        } catch (\Throwable $e) {
            error_log("[payments] alert sink failed for inbox {$entry->id}: " . $e->getMessage());
            return;
        }
        try {
            $this->store->alertSent($entry->id, $kind);
        } catch (\Throwable $e) {
            error_log("[payments] inbox {$entry->id}: alert sent but could not be stamped: " . $e->getMessage());
        }
    }
}
