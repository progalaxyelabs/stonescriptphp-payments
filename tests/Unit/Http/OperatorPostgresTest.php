<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\Http\Operator\RefundQueueResolver;
use StoneScriptPay\Http\Operator\WebhookRequeuer;
use Tests\Http\Support\PdoFunctionCaller;

/** The operator-only (internal, CLI-run) actions over a DIRECT connection. Skipped without PAYMENTS_TEST_PG_DSN. */
final class OperatorPostgresTest extends TestCase
{
    private \PDO $pdo;

    protected function setUp(): void
    {
        $dsn = getenv('PAYMENTS_TEST_PG_DSN');
        if ($dsn === false || $dsn === '' || !extension_loaded('pdo_pgsql')) {
            $this->markTestSkipped('PAYMENTS_TEST_PG_DSN / pdo_pgsql not available: the operator tests did not run.');
        }
        $this->pdo = new \PDO($dsn, null, null, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
    }

    public function test_refund_queue_resolve_requires_actor_and_note_and_closes_the_entry(): void
    {
        $txn = 'pay_op_' . bin2hex(random_bytes(4));
        $this->pdo->prepare("SELECT _pay_queue_refund('razorpay', ?, 'ord_x', NULL, NULL, 100, 'INR', 'review_mismatch', 't')")->execute([$txn]);
        $id = (int) $this->pdo->query('SELECT id FROM pay_refund_queue WHERE gateway_txn_ref = ' . $this->pdo->quote($txn))->fetchColumn();
        $r = new RefundQueueResolver(new PdoFunctionCaller($this->pdo));
        try {
            $r->resolve($id, 'refunded', '', 'note');
            self::fail('an empty actor must be refused');
        } catch (\PDOException $e) {
            self::assertStringContainsString('PY020', (string) $e->getCode() . $e->getMessage());
        }
        self::assertSame('refunded', $r->resolve($id, 'refunded', 'operator', 'refunded in dashboard'));
        self::assertSame('refunded', $this->pdo->query("SELECT status FROM pay_refund_queue WHERE id = $id")->fetchColumn());
    }

    public function test_requeue_refuses_an_applied_row(): void
    {
        $this->pdo->exec("SELECT pay_webhook_record('razorpay', 'evt_op_" . bin2hex(random_bytes(4)) . "', 'payment.captured', 'p', '{\"a\":1}', '{}', '{\"type\":\"x\"}')");
        $id = (int) $this->pdo->query('SELECT max(id) FROM pay_webhook_inbox')->fetchColumn();
        $this->pdo->exec("SELECT * FROM pay_webhook_claim($id)");
        $this->pdo->exec("SELECT * FROM pay_webhook_mark($id, 'applied')");
        $this->expectException(\PDOException::class);
        (new WebhookRequeuer(new PdoFunctionCaller($this->pdo)))->requeue($id, 'op', 'why');
    }
}
