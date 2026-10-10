<?php

declare(strict_types=1);

namespace StoneScriptPay\Http\Webhook;

/**
 * Ageing alert for the refund queue: money that arrived and could not be applied must not sit unrefunded unnoticed.
 *
 * pay_refund_queue_aged() lists open entries older than pay_config 'refund_queue_alert_after_days' (default 3) that were not
 * alerted within 'refund_queue_alert_repeat_hours' (default 24). For each, this raises an alert of kind 'refund_queue.aged'
 * through the AlertSink (the queue id takes the place of the inbox id; the transaction reference takes the event id) and
 * stamps it with pay_refund_queue_alert_sent() ONLY after the sink succeeded, so a failing sink means it is tried again next
 * run. An entry is re-alerted every repeat period until a human closes it with _pay_refund_queue_resolve(). Run it from cron
 * through bin/pay-refund-queue-alerts.
 */
final class RefundQueueMonitor
{
    public function __construct(
        private readonly SqlFunctionCaller $db,
        private readonly AlertSink $alerts,
    ) {}

    /** @return int number of alerts delivered in this run */
    public function run(int $limit = 100): int
    {
        $sent = 0;
        foreach ($this->db->call('pay_refund_queue_aged', [$limit]) as $row) {
            $id = (int) $row['o_id'];
            $detail = sprintf(
                'refund queue entry %d (%s, %s %s, order %s) has been open %d day(s) since %s: refund it or apply it, then resolve the entry',
                $id,
                (string) $row['o_reason'],
                (string) $row['o_amount_minor'],
                (string) $row['o_currency'],
                (string) ($row['o_order_ref'] ?? '-'),
                (int) $row['o_age_days'],
                (string) $row['o_gateway_txn_ref'],
            );
            try {
                $this->alerts->alert('refund_queue.aged', $id, (string) $row['o_gateway_code'], (string) $row['o_gateway_txn_ref'], $detail);
            } catch (\Throwable $e) {
                error_log("[payments] refund-queue alert sink failed for entry {$id}: " . $e->getMessage());
                continue;
            }
            try {
                $this->db->call('pay_refund_queue_alert_sent', [$id]);
            } catch (\Throwable $e) {
                error_log("[payments] refund-queue entry {$id}: alert sent but could not be stamped: " . $e->getMessage());
            }
            $sent++;
        }

        return $sent;
    }
}
