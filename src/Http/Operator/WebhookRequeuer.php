<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Operator;

use StoneScriptPay\Http\Webhook\SqlFunctionCaller;

/**
 * Puts a dead / failed / unattributed inbox row back into the replay queue with a fresh attempt and alert budget, after the
 * cause was fixed. Wraps the INTERNAL SQL function _pay_webhook_requeue: give it a caller over a DIRECT database connection.
 * Run it through bin/pay-webhook-requeue.
 */
final class WebhookRequeuer
{
    public function __construct(private readonly SqlFunctionCaller $db) {}

    /** @return string the row's new status */
    public function requeue(int $inboxId, string $actor, string $reason): string
    {
        $rows = $this->db->call('_pay_webhook_requeue', [$inboxId, $actor, $reason]);

        return (string) (array_values($rows[0] ?? [''])[0] ?? '');
    }
}
