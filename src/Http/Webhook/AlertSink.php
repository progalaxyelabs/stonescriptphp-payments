<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/**
 * Receives the alert raised when an inbox row first becomes failed or unattributed, and once more when it
 * is declared dead (a terminal state). Throw to signal that the alert could not be delivered: it then stays due and is
 * raised again at the next transition. Wire it to whatever the deployment pages on.
 */
interface AlertSink
{
    /**
     * @param string $kind 'webhook.failed' | 'webhook.unattributed' | 'webhook.malformed' | 'webhook.dead'
     */
    public function alert(string $kind, int $inboxId, string $gatewayCode, string $eventId, string $detail): void;
}
