<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\DTO\WebhookEvent;
use StoneScriptPay\Http\Webhook\InboxEntry;
use StoneScriptPay\Http\Webhook\PlatformRoutingProcessor;
use StoneScriptPay\Http\Webhook\ProcessResult;
use StoneScriptPay\Http\Webhook\SqlWebhookInboxStore;
use StoneScriptPay\Http\Webhook\WebhookIngress;
use StoneScriptPay\Http\Webhook\WebhookProcessor;
use StoneScriptPay\Http\Webhook\WebhookReplayer;
use Tests\Http\Support\FailableCaller;
use Tests\Http\Support\RecordingAlerts;
use Tests\Http\Support\RecordingProcessor;
use Tests\Http\Support\WebhookFixtures;

/**
 * The L7.2 acceptance flows against the REAL pay_webhook_* SQL functions (a throwaway Postgres
 * with the package schema loaded) and the REAL Razorpay signature verification.
 *
 * Needs PAYMENTS_TEST_PG_DSN, e.g. "pgsql:host=127.0.0.1;port=5432;dbname=paytest_x;user=u;password=p";
 * tests/shell/l7_2_webhook_inbox.sh prepares the database and sets it. Without it the tests are
 * reported as SKIPPED (visible in the PHPUnit summary), never silently green.
 */
final class WebhookInboxPostgresTest extends TestCase
{
    private \PDO $pdo;
    private FailableCaller $caller;
    private SqlWebhookInboxStore $store;
    private RecordingProcessor $inner;
    private RecordingAlerts $alerts;
    private WebhookIngress $ingress;
    private string $run;

    protected function setUp(): void
    {
        $dsn = getenv('PAYMENTS_TEST_PG_DSN');
        if ($dsn === false || $dsn === '') {
            $this->markTestSkipped('PAYMENTS_TEST_PG_DSN is not set: the real-SQL webhook inbox tests did not run.');
        }
        if (!extension_loaded('pdo_pgsql')) {
            $this->markTestSkipped('pdo_pgsql is not loaded in this PHP: the real-SQL webhook inbox tests did not run.');
        }
        $this->pdo = new \PDO($dsn, null, null, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
        $this->caller = FailableCaller::forTests($this->pdo);
        $this->store = new SqlWebhookInboxStore($this->caller);
        $this->inner = new RecordingProcessor();
        $this->alerts = new RecordingAlerts();
        $this->ingress = new WebhookIngress(
            ['razorpay' => WebhookFixtures::gateway()],
            $this->store,
            new PlatformRoutingProcessor('plat', $this->inner),
            $this->alerts,
        );
        $this->run = bin2hex(random_bytes(4));
    }

    private function id(string $n): string
    {
        return "evt_{$this->run}_{$n}";
    }

    private function deliver(string $eventId, ?string $platform = 'plat', bool $valid = true, ?string $orderRef = 'ord_1')
    {
        $body = WebhookFixtures::captured('pay_' . $eventId, $platform, 49900, $orderRef);

        return $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, $eventId, $valid));
    }

    /** @return array<string,mixed>|null */
    private function row(string $eventId): ?array
    {
        $s = $this->pdo->prepare("SELECT * FROM pay_webhook_inbox WHERE gateway_code = 'razorpay' AND headers->>'x-razorpay-event-id' = ?");
        $s->execute([$eventId]);
        $r = $s->fetch(\PDO::FETCH_ASSOC);

        return $r === false ? null : $r;
    }

    private function rowCount(string $eventId): int
    {
        $s = $this->pdo->prepare("SELECT count(*) FROM pay_webhook_inbox WHERE headers->>'x-razorpay-event-id' = ?");
        $s->execute([$eventId]);

        return (int) $s->fetchColumn();
    }

    private function replayer(?WebhookProcessor $p = null): WebhookReplayer
    {
        return new WebhookReplayer($this->store, $p ?? new PlatformRoutingProcessor('plat', $this->inner), $this->alerts);
    }

    public function test_valid_event_is_stored_applied_and_acknowledged(): void
    {
        $id = $this->id('ok');
        $r = $this->deliver($id);
        $this->assertSame(200, $r->httpStatus);
        $row = $this->row($id);
        $this->assertSame('applied', $row['status']);
        $this->assertSame(1, (int) $row['attempts']);
        $this->assertNotNull($row['applied_at']);
        $this->assertSame(1, $this->inner->applied[$id]);
    }

    public function test_the_processor_receives_the_full_normalised_event_read_back_from_the_inbox(): void
    {
        $seen = null;
        $spy = new class($seen) implements WebhookProcessor {
            public function __construct(public mixed &$seen) {}

            public function process(InboxEntry $entry, WebhookEvent $event): ProcessResult
            {
                $this->seen = [$entry, $event];

                return ProcessResult::applied();
            }
        };
        $ingress = new WebhookIngress(['razorpay' => WebhookFixtures::gateway()], $this->store, new PlatformRoutingProcessor('plat', $spy), $this->alerts);
        $id = $this->id('shape');
        $body = WebhookFixtures::captured("pay_shape_{$this->run}", 'plat', 12345, 'ord_1');
        $ingress->handle('razorpay', $body, WebhookFixtures::headers($body, $id));
        [$entry, $event] = $seen;
        $this->assertSame('sha256:' . hash('sha256', $body), $entry->eventId, 'the dedupe key is the hash of the signed body');
        $this->assertSame("pay_shape_{$this->run}", $event->gatewayTxnRef);
        $this->assertSame(12345, $event->amountMinorUnits);
        $this->assertSame('INR', $event->currency);
        $this->assertSame('plat', $event->platformCode);
        $this->assertSame('payment.captured', $event->type);
        $this->assertSame($id, $event->eventId);
    }

    public function test_a_bad_signature_never_writes_a_row(): void
    {
        $id = $this->id('badsig');
        $r = $this->deliver($id, valid: false);
        $this->assertSame(401, $r->httpStatus);
        $this->assertSame(0, $this->rowCount($id));
        $this->assertSame(0, $this->inner->total());
    }

    public function test_database_unavailable_at_insert_is_non_2xx_and_the_retry_applies_exactly_once(): void
    {
        $id = $this->id('dbdown');
        $this->caller->failTimes = 1;
        $first = $this->deliver($id);
        $this->assertSame(503, $first->httpStatus);
        $this->assertSame(0, $this->rowCount($id));
        $this->assertSame(0, $this->inner->total());

        $this->assertSame(200, $this->deliver($id)->httpStatus);
        $this->assertSame(200, $this->deliver($id)->httpStatus);
        $this->assertSame(1, $this->inner->applied[$id]);
        $this->assertSame(1, $this->rowCount($id));
    }

    public function test_a_redelivered_event_id_is_a_no_op(): void
    {
        $id = $this->id('dup');
        $this->deliver($id);
        $again = $this->deliver($id);
        $this->assertTrue($again->data['duplicate']);
        $this->assertSame(1, $this->inner->applied[$id]);
        $this->assertSame(1, $this->rowCount($id));
    }

    public function test_a_processing_exception_leaves_a_failed_row_and_replay_applies_it_once(): void
    {
        $id = $this->id('fail');
        $this->inner->failTimes = 1;
        $r = $this->deliver($id);
        $this->assertSame(200, $r->httpStatus);
        $row = $this->row($id);
        $this->assertSame('failed', $row['status']);
        $this->assertStringContainsString('processing blew up', (string) $row['last_error']);
        $this->assertNotNull($row['alert_raised_at']);
        $this->assertSame(['webhook.failed'], $this->alerts->kinds());

        $this->assertSame([], array_filter($this->replayer()->replay(500), fn($st, $rid) => $rid === (int) $row['id'], ARRAY_FILTER_USE_BOTH), 'the failed row is held back by backoff');
        $this->pdo->exec("UPDATE pay_webhook_inbox SET locked_until = NULL WHERE id = {$row['id']}");     // time passes
        $out = $this->replayer()->replay(500);
        $this->assertSame('applied', $out[(int) $row['id']]);
        $this->assertSame('applied', $this->row($id)['status']);
        $this->assertSame(1, $this->inner->applied[$id]);
        $this->replayer()->replay(500);
        $this->assertSame(1, $this->inner->applied[$id], 'a second replay finds nothing to do for this event');
        $this->assertSame(['webhook.failed'], $this->alerts->kinds());
    }

    public function test_foreign_is_recorded_without_alert_and_unattributed_alerts_once(): void
    {
        $f = $this->id('foreign');
        $u = $this->id('unattr');
        $this->deliver($f, 'some-other-platform');
        $this->deliver($u, 'plat', true, null);      // our platform, no order reference
        $this->assertSame('foreign', $this->row($f)['status']);
        $this->assertSame('some-other-platform', $this->row($f)['platform_code']);
        $this->assertSame('unattributed', $this->row($u)['status']);
        $this->assertSame(['webhook.unattributed'], $this->alerts->kinds());

        $this->replayer()->replay(500);
        $this->replayer()->replay(500);
        $this->assertSame(['webhook.unattributed'], $this->alerts->kinds(), 'alerted once');
        $this->assertSame('unattributed', $this->row($u)['status'], 'still not applied by guess');
        $this->assertArrayNotHasKey($u, $this->inner->applied);
        $this->assertArrayNotHasKey($f, $this->inner->applied);
        $this->assertSame('foreign', $this->row($f)['status'], 'foreign rows are final');
    }

    public function test_an_event_with_no_routing_key_and_no_order_is_foreign_and_silent(): void
    {
        $id = $this->id('nokey');
        $this->deliver($id, null, true, null);
        $this->assertSame('foreign', $this->row($id)['status']);
        $this->assertSame([], $this->alerts->alerts);
        $this->replayer()->replay(500);
        $this->assertSame('foreign', $this->row($id)['status']);
    }

    public function test_a_row_that_keeps_failing_goes_dead_with_one_dead_alert_and_leaves_the_queue(): void
    {
        $this->pdo->exec("UPDATE pay_config SET config_value = '3' WHERE config_key = 'webhook_max_attempts'");
        try {
            $id = $this->id('dead');
            $this->inner->failTimes = 99;
            $this->deliver($id);                                           // attempt 1
            for ($i = 0; $i < 3; $i++) {                                    // backoff holds retries back: lift it like time passing
                $this->pdo->exec("UPDATE pay_webhook_inbox SET locked_until = NULL WHERE headers->>'x-razorpay-event-id' = '{$id}'");
                $this->replayer()->replay(500);
            }
            $row = $this->row($id);
            $this->assertSame('dead', $row['status']);
            $this->assertSame(['webhook.failed', 'webhook.dead'], $this->alerts->kinds());
            $this->assertNotNull($row['dead_alert_raised_at']);
            $this->pdo->exec("UPDATE pay_webhook_inbox SET locked_until = NULL WHERE headers->>'x-razorpay-event-id' = '{$id}'");
            $this->assertSame([], array_filter($this->replayer()->replay(500), fn($st, $rid) => $rid === (int) $row['id'], ARRAY_FILTER_USE_BOTH));
        } finally {
            $this->pdo->exec("UPDATE pay_config SET config_value = '8' WHERE config_key = 'webhook_max_attempts'");
        }
    }

    public function test_only_normalised_non_personal_fields_are_stored_and_expired_payloads_are_redacted(): void
    {
        $id = $this->id('pii');
        $body = json_encode(['event' => 'payment.captured', 'payload' => ['payment' => ['entity' => [
            'id' => "pay_pii_{$this->run}", 'amount' => 49900, 'currency' => 'INR', 'created_at' => 1790000000, 'email' => 'payer@example.test', 'contact' => '+910000000000',
            'notes' => ['order_id' => 'ord_1', 'platform_code' => 'plat', 'tenant_id' => '00000000-0000-0000-0000-000000000001'],
        ]]]]);
        $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, $id));
        $row = $this->row($id);
        $this->assertStringNotContainsString('payer@example.test', (string) $row['event'], 'the normalised event holds no payer data');
        $this->assertSame(hash('sha256', $body), $row['body_sha256']);

        // age it past the retention period and run the audited job
        $this->pdo->exec('ALTER TABLE pay_webhook_inbox DISABLE TRIGGER pay_webhook_inbox_guard');
        $this->pdo->exec("UPDATE pay_webhook_inbox SET received_at = now() - interval '14 months' WHERE id = {$row['id']}");
        $this->pdo->exec('ALTER TABLE pay_webhook_inbox ENABLE TRIGGER pay_webhook_inbox_guard');
        $this->assertGreaterThanOrEqual(1, (new \StoneScriptPay\Http\Webhook\WebhookRetention(new \Tests\Http\Support\PdoFunctionCaller($this->pdo)))->redactExpired('phpunit', 1000));
        $after = $this->row($id);
        $this->assertNotNull($after['redacted_at']);
        $this->assertStringNotContainsString('payer@example.test', $after['raw_body']);
        $this->assertStringNotContainsString('+91', $after['raw_body']);
        $this->assertSame(hash('sha256', $body), json_decode($after['raw_body'], true)['body_sha256']);
        $this->assertSame("pay_pii_{$this->run}", json_decode($after['raw_body'], true)['event']['gateway_txn_ref']);
    }

    public function test_malformed_but_signed_json_is_stored_raw(): void
    {
        $id = $this->id('malformed');
        $body = "{not json {$this->run} \u{00e9}\n";
        $r = $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, $id));
        $this->assertSame(200, $r->httpStatus);
        $row = $this->row($id);
        $this->assertSame('failed', $row['status']);
        $this->assertSame($body, $row['raw_body'], 'byte for byte');
        $this->assertNull($row['event']);
        $this->assertSame(['webhook.malformed'], $this->alerts->kinds());
        // replay cannot process an unreadable body, stays failed, does not alert again
        $this->replayer()->replay(500);
        $this->assertSame('failed', $this->row($id)['status']);
        $this->assertSame(['webhook.malformed'], $this->alerts->kinds());
    }

    public function test_only_safe_headers_are_stored(): void
    {
        $id = $this->id('hdr');
        $body = WebhookFixtures::captured("pay_hdr_{$this->run}", 'plat', 49900, 'ord_1');
        $headers = WebhookFixtures::headers($body, $id) + ['Authorization' => 'Bearer s', 'Cookie' => 'sid=1'];
        $this->ingress->handle('razorpay', $body, $headers);
        $stored = json_decode($this->row($id)['headers'], true);
        $this->assertArrayHasKey('x-razorpay-event-id', $stored);
        foreach (['authorization', 'cookie', 'x-razorpay-signature'] as $secret) {
            $this->assertArrayNotHasKey($secret, $stored);
        }
    }

    public function test_a_stored_row_cannot_be_deleted(): void
    {
        $id = $this->id('keep');
        $this->deliver($id);
        $this->expectException(\PDOException::class);
        $this->pdo->exec("DELETE FROM pay_webhook_inbox WHERE headers->>'x-razorpay-event-id' = '{$id}'");
    }
}
