<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\Http\Webhook\AlertSink;
use StoneScriptPay\Http\Webhook\RefundQueueMonitor;
use Tests\Http\Support\FailableCaller;
use Tests\Http\Support\RecordingAlerts;

/** Real-SQL tests of the refund-queue ageing alert and of the server-side allow-list parity. Skipped without PAYMENTS_TEST_PG_DSN. */
final class RefundQueueMonitorPostgresTest extends TestCase
{
    private \PDO $pdo;
    private FailableCaller $caller;
    private string $run;

    protected function setUp(): void
    {
        $dsn = getenv('PAYMENTS_TEST_PG_DSN');
        if ($dsn === false || $dsn === '' || !extension_loaded('pdo_pgsql')) {
            $this->markTestSkipped('PAYMENTS_TEST_PG_DSN / pdo_pgsql not available: the real-SQL refund-queue tests did not run.');
        }
        $this->pdo = new \PDO($dsn, null, null, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
        $this->caller = FailableCaller::forTests($this->pdo);
        $this->run = bin2hex(random_bytes(4));
    }

    private function queue(string $txn, int $ageDays): int
    {
        $this->pdo->prepare("SELECT _pay_queue_refund('razorpay', ?, 'ord_x', NULL, NULL, 58882, 'INR', 'review_mismatch', 'test')")->execute([$txn]);
        $this->pdo->prepare('UPDATE pay_refund_queue SET created_at = now() - make_interval(days => ?) WHERE gateway_txn_ref = ?')->execute([$ageDays, $txn]);

        return (int) $this->pdo->query("SELECT id FROM pay_refund_queue WHERE gateway_txn_ref = " . $this->pdo->quote($txn))->fetchColumn();
    }

    public function test_an_aged_entry_is_alerted_then_stamped_and_a_failing_sink_leaves_it_due(): void
    {
        $old = $this->queue("pay_mon_old_{$this->run}", 5);
        $fresh = $this->queue("pay_mon_new_{$this->run}", 1);

        $failing = new class implements AlertSink {
            public function alert(string $kind, int $inboxId, string $gatewayCode, string $eventId, string $detail): void
            {
                throw new \RuntimeException('pager down');
            }
        };
        self::assertSame(0, (new RefundQueueMonitor($this->caller, $failing))->run());
        self::assertNull($this->pdo->query("SELECT last_alert_at FROM pay_refund_queue WHERE id = $old")->fetchColumn(), 'not stamped when the sink failed');

        $alerts = new RecordingAlerts();
        $sent = (new RefundQueueMonitor($this->caller, $alerts))->run();
        self::assertGreaterThanOrEqual(1, $sent);
        $mine = array_values(array_filter($alerts->alerts, static fn (array $a) => $a['id'] === $old));
        self::assertCount(1, $mine);
        self::assertSame('refund_queue.aged', $mine[0]['kind']);
        self::assertStringContainsString('review_mismatch', $mine[0]['detail']);
        self::assertSame([], array_filter($alerts->alerts, static fn (array $a) => $a['id'] === $fresh), 'a fresh entry is not alerted');
        self::assertNotNull($this->pdo->query("SELECT last_alert_at FROM pay_refund_queue WHERE id = $old")->fetchColumn(), 'stamped after the sink succeeded');

        $again = new RecordingAlerts();
        (new RefundQueueMonitor($this->caller, $again))->run();
        self::assertSame([], array_filter($again->alerts, static fn (array $a) => $a['id'] === $old), 'not re-alerted inside the repeat period');
    }
}
