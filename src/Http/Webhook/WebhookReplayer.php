<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/**
 * Re-drives inbox rows that did not reach a final outcome: failed, unattributed, and stale
 * 'received' rows (a worker died between storing and recording). Run it from cron/systemd (see
 * bin/pay-replay-webhooks) or after fixing whatever made rows fail.
 *
 * Safe to run concurrently with live deliveries and with itself: each row is claimed under a
 * lease first, so an event is never processed by two workers at once, and applied/ignored/foreign
 * rows are final and never touched. A row that fails again does not alert again (alert once).
 */
final class WebhookReplayer
{
    private readonly InboxRunner $runner;

    public function __construct(
        private readonly WebhookInboxStore $store,
        WebhookProcessor $processor,
        ?AlertSink $alerts = null,
    ) {
        $this->runner = new InboxRunner($store, $processor, $alerts ?? new ErrorLogAlertSink());
    }

    /**
     * @return array<int,string> inbox id => resulting status ('skipped' when it could not be claimed)
     */
    public function replay(int $limit = 50, int $staleAfterSeconds = 300): array
    {
        $out = [];
        foreach ($this->store->replayCandidates($limit, $staleAfterSeconds) as $id) {
            $out[$id] = $this->runner->run($id) ?? 'skipped';
        }

        return $out;
    }
}
