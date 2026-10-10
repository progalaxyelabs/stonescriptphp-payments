<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Operator;

use StoneScriptPay\Http\Webhook\SqlFunctionCaller;

/**
 * Closes a refund-queue entry after a human refunded it, applied it by hand, or decided to dismiss it. Wraps the INTERNAL SQL
 * function _pay_refund_queue_resolve, so it must be given a caller over a DIRECT database connection (never the gateway's
 * /call, which refuses internal functions). Run it through bin/pay-refund-queue-resolve.
 */
final class RefundQueueResolver
{
    public function __construct(private readonly SqlFunctionCaller $db) {}

    /** @return string the entry's new status */
    public function resolve(int $id, string $status, string $actor, string $note): string
    {
        $rows = $this->db->call('_pay_refund_queue_resolve', [$id, $status, $actor, $note]);

        return (string) (array_values($rows[0] ?? [''])[0] ?? '');
    }
}
