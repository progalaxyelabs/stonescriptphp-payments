<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\DTO\WebhookEvent;
use StoneScriptPay\Http\Webhook\PlatformRoutingProcessor;
use StoneScriptPay\Http\Webhook\ProcessResult;
use StoneScriptPay\Http\Webhook\WebhookIngress;
use StoneScriptPay\Http\Webhook\WebhookReplayer;
use Tests\Http\Support\InMemoryInboxStore;
use Tests\Http\Support\RecordingAlerts;
use Tests\Http\Support\RecordingProcessor;
use Tests\Http\Support\WebhookFixtures;

/**
 * L7.2 acceptance for the webhook ingress, against the REAL Razorpay driver's signature
 * verification and an in-memory store that follows the SQL semantics. The same flows run against
 * the real SQL in WebhookInboxPostgresTest.
 */
final class WebhookIngressTest extends TestCase
{
    private InMemoryInboxStore $store;
    private RecordingProcessor $inner;
    private RecordingAlerts $alerts;
    private WebhookIngress $ingress;

    protected function setUp(): void
    {
        $this->store = new InMemoryInboxStore();
        $this->inner = new RecordingProcessor();
        $this->alerts = new RecordingAlerts();
        $this->ingress = new WebhookIngress(
            ['razorpay' => WebhookFixtures::gateway()],
            $this->store,
            new PlatformRoutingProcessor('plat', $this->inner),
            $this->alerts,
        );
    }

    private function deliver(string $eventId, ?string $platform = 'plat', string $payment = 'pay_1', bool $valid = true, ?string $orderRef = 'ord_1')
    {
        $body = WebhookFixtures::captured($payment, $platform, 49900, $orderRef);

        return $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, $eventId, $valid));
    }

    public function test_a_valid_event_is_stored_applied_and_acknowledged(): void
    {
        $r = $this->deliver('evt_1');
        $this->assertSame(200, $r->httpStatus);
        $this->assertSame('applied', $r->data['status']);
        $this->assertSame('applied', $this->store->status('evt_1'));
        $this->assertSame(1, $this->inner->total());
        $this->assertSame([], $this->alerts->alerts);
    }

    public function test_a_bad_signature_never_writes_a_row(): void
    {
        $r = $this->deliver('evt_bad', valid: false);
        $this->assertSame(401, $r->httpStatus);
        $this->assertSame(0, $this->store->recordCalls, 'the store must not even be called');
        $this->assertSame([], $this->store->rows);
        $this->assertSame(0, $this->inner->total());
    }

    public function test_a_missing_signature_never_writes_a_row(): void
    {
        $body = WebhookFixtures::captured('pay_1', 'plat', 49900, 'ord_1');
        $r = $this->ingress->handle('razorpay', $body, ['X-Razorpay-Event-Id' => 'evt_nosig']);
        $this->assertSame(401, $r->httpStatus);
        $this->assertSame([], $this->store->rows);
    }

    public function test_an_unknown_gateway_is_404_and_writes_nothing(): void
    {
        $r = $this->ingress->handle('nope', '{}', []);
        $this->assertSame(404, $r->httpStatus);
        $this->assertSame([], $this->store->rows);
    }

    public function test_database_unavailable_at_insert_is_non_2xx_and_the_retry_applies_exactly_once(): void
    {
        $this->store->failRecordTimes = 1;
        $first = $this->deliver('evt_retry');
        $this->assertSame(503, $first->httpStatus, 'not stored => not acknowledged, so the gateway redelivers');
        $this->assertSame([], $this->store->rows);
        $this->assertSame(0, $this->inner->total());

        $second = $this->deliver('evt_retry');       // the gateway's retry
        $this->assertSame(200, $second->httpStatus);
        $this->assertSame(1, $this->inner->applied['evt_retry']);
        $third = $this->deliver('evt_retry');        // and a further redelivery
        $this->assertSame(200, $third->httpStatus);
        $this->assertTrue($third->data['duplicate']);
        $this->assertSame(1, $this->inner->applied['evt_retry'], 'applied exactly once across three deliveries');
        $this->assertCount(1, $this->store->rows);
    }

    public function test_a_redelivered_event_id_is_a_no_op(): void
    {
        $this->deliver('evt_dup');
        $again = $this->deliver('evt_dup');
        $this->assertSame(200, $again->httpStatus);
        $this->assertTrue($again->data['duplicate']);
        $this->assertSame(1, $this->inner->total());
        $this->assertCount(1, $this->store->rows);
    }

    public function test_a_processing_exception_leaves_a_failed_row_acknowledges_and_replay_applies_once(): void
    {
        $this->inner->failTimes = 1;
        $r = $this->deliver('evt_fail');
        $this->assertSame(200, $r->httpStatus, '2xx because the row is durable, not because processing worked');
        $this->assertSame('failed', $r->data['status']);
        $this->assertSame('failed', $this->store->status('evt_fail'));
        $this->assertSame(['webhook.failed'], $this->alerts->kinds());
        $this->assertStringContainsString('processing blew up', (string) $this->store->rows[1]['last_error']);

        $replayer = new WebhookReplayer($this->store, new PlatformRoutingProcessor('plat', $this->inner), $this->alerts);
        $this->assertSame([1 => 'applied'], $replayer->replay());
        $this->assertSame(1, $this->inner->applied['evt_fail']);
        $this->assertSame([], $replayer->replay(), 'nothing left to replay');
        $this->assertSame(1, $this->inner->applied['evt_fail'], 'replay applied it once');
    }

    public function test_a_failing_row_goes_dead_after_its_attempts_with_exactly_one_dead_alert(): void
    {
        $this->inner->failTimes = 99;
        $this->deliver('evt_flap');                                   // attempt 1: failed, alert 1
        $replayer = new WebhookReplayer($this->store, new PlatformRoutingProcessor('plat', $this->inner), $this->alerts);
        $this->assertSame([1 => 'failed'], $replayer->replay());       // attempt 2: still failed, no new alert
        $this->assertSame([1 => 'dead'], $replayer->replay());         // attempt 3 = max: dead
        $this->assertSame(['webhook.failed', 'webhook.dead'], $this->alerts->kinds(), 'one alert per transition, not per attempt');
        $this->assertSame([], $replayer->replay(), 'a dead row is never replayed again');
        $this->assertSame('dead', $this->store->status('evt_flap'));
        $this->assertSame(0, $this->inner->total());
    }

    public function test_an_alert_whose_sink_failed_stays_due_and_is_raised_again(): void
    {
        $flaky = new class implements \StoneScriptPay\Http\Webhook\AlertSink {
            public int $fail = 1;
            public array $got = [];
            public function alert(string $kind, int $inboxId, string $gatewayCode, string $eventId, string $detail): void
            {
                if ($this->fail > 0) {
                    $this->fail--;
                    throw new \RuntimeException('pager down');
                }
                $this->got[] = $kind;
            }
        };
        $ingress = new WebhookIngress(['razorpay' => WebhookFixtures::gateway()], $this->store, new PlatformRoutingProcessor('plat', $this->inner), $flaky);
        $this->inner->failTimes = 2;
        $body = WebhookFixtures::captured('pay_f', 'plat', 49900, 'ord_1');
        $ingress->handle('razorpay', $body, WebhookFixtures::headers($body, 'evt_pager'));
        $this->assertSame([], $flaky->got);
        $this->assertSame([], $this->store->stamped, 'a failed sink must NOT mark the alert as sent');
        $replayer = new WebhookReplayer($this->store, new PlatformRoutingProcessor('plat', $this->inner), $flaky);
        $replayer->replay();
        $this->assertSame(['webhook.failed'], $flaky->got, 'the still-due alert is raised at the next transition');
        $this->assertSame([['id' => 1, 'kind' => 'webhook.failed']], $this->store->stamped);
        $replayer->replay();
        $this->assertSame(['webhook.failed'], $flaky->got, 'and not again once stamped');
    }

    public function test_a_foreign_platform_event_is_recorded_and_not_alerted(): void
    {
        $r = $this->deliver('evt_foreign', 'other-platform');
        $this->assertSame(200, $r->httpStatus);
        $this->assertSame('foreign', $this->store->status('evt_foreign'));
        $this->assertSame('other-platform', $this->store->rows[1]['platform_code']);
        $this->assertSame([], $this->alerts->alerts);
        $this->assertSame(0, $this->inner->total(), 'never applied');
    }

    public function test_our_platform_without_an_order_is_unattributed_recorded_never_applied_and_alerts_once(): void
    {
        $r = $this->deliver('evt_unattr', 'plat', 'pay_u', true, null);
        $this->assertSame(200, $r->httpStatus);
        $this->assertSame('unattributed', $this->store->status('evt_unattr'));
        $this->assertSame(['webhook.unattributed'], $this->alerts->kinds());
        $this->assertSame(0, $this->inner->total());

        $replayer = new WebhookReplayer($this->store, new PlatformRoutingProcessor('plat', $this->inner), $this->alerts);
        $replayer->replay();
        $this->assertSame(['webhook.unattributed'], $this->alerts->kinds(), 'a replay of the same open row does not alert again');
        $this->assertSame(0, $this->inner->total());
    }

    public function test_an_order_reference_of_ours_that_does_not_resolve_is_unattributed(): void
    {
        $this->inner->fixedResult = ProcessResult::unattributed('no such order');
        $r = $this->deliver('evt_noorder', 'plat', 'pay_n', true, 'ord_doesnotexist');
        $this->assertSame('unattributed', $r->data['status']);
        $this->assertSame(['webhook.unattributed'], $this->alerts->kinds());
    }

    public function test_an_event_with_no_routing_key_and_no_order_of_ours_is_foreign_never_replayed_never_alerted(): void
    {
        $r = $this->deliver('evt_nokey', null, 'pay_k', true, null);
        $this->assertSame('foreign', $r->data['status']);
        $this->assertSame('foreign', $this->store->status('evt_nokey'));
        $this->assertSame([], $this->alerts->alerts);
        $replayer = new WebhookReplayer($this->store, new PlatformRoutingProcessor('plat', $this->inner), $this->alerts);
        $this->assertSame([], $replayer->replay(), 'foreign rows are final');
        $this->assertSame(0, $this->inner->total());
    }

    public function test_an_event_type_with_no_handler_is_recorded_as_ignored(): void
    {
        $body = json_encode(['event' => 'payment.authorized', 'payload' => []], JSON_THROW_ON_ERROR);
        $r = $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, 'evt_other'));
        $this->assertSame(200, $r->httpStatus);
        $this->assertSame('ignored', $this->store->status('evt_other'));
        $this->assertSame([], $this->alerts->alerts);
    }

    public function test_malformed_but_signed_json_is_stored_raw_and_alerts_once(): void
    {
        $body = '{this is not json';
        $r = $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, 'evt_malformed'));
        $this->assertSame(200, $r->httpStatus);
        $this->assertSame('failed', $this->store->status('evt_malformed'));
        $this->assertSame($body, $this->store->rows[1]['raw_body'], 'stored raw, byte for byte');
        $this->assertNull($this->store->rows[1]['event']);
        $this->assertSame(['webhook.malformed'], $this->alerts->kinds());
        // the gateway redelivering it changes nothing
        $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, 'evt_malformed'));
        $this->assertCount(1, $this->store->rows);
        $this->assertSame(['webhook.malformed'], $this->alerts->kinds());
        // and replay cannot conjure an event out of it, nor alert again
        $replayer = new WebhookReplayer($this->store, new PlatformRoutingProcessor('plat', $this->inner), $this->alerts);
        $this->assertSame([1 => 'failed'], $replayer->replay());
        $this->assertSame(['webhook.malformed'], $this->alerts->kinds());
        $this->assertSame(0, $this->inner->total());
    }

    public function test_an_unsigned_malformed_body_is_not_stored(): void
    {
        $body = '{this is not json';
        $r = $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, 'evt_forged', false));
        $this->assertSame(401, $r->httpStatus);
        $this->assertSame([], $this->store->rows);
    }

    public function test_the_dedupe_key_is_the_signed_body_not_the_unsigned_header(): void
    {
        $body = WebhookFixtures::captured('pay_9', 'plat', 49900, 'ord_9');
        // the same signed bytes under two different (forgeable) event-id headers are ONE event
        $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, 'evt_a'));
        $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, 'evt_b'));
        $this->assertCount(1, $this->store->rows);
        $this->assertSame('sha256:' . hash('sha256', $body), $this->store->rows[1]['event_id']);
        $this->assertSame(1, $this->inner->total());
        // a DIFFERENT signed body that reuses an id header is a different event and is not swallowed by it
        $other = WebhookFixtures::captured('pay_10', 'plat', 49900, 'ord_10');
        $this->ingress->handle('razorpay', $other, WebhookFixtures::headers($other, 'evt_a'));
        $this->assertCount(2, $this->store->rows, 'a forged or reused header id cannot pre-empt another event');
        $this->assertSame(2, $this->inner->total());
    }

    public function test_the_rate_limiter_hook_answers_429_before_anything_is_verified_or_stored(): void
    {
        $limiter = new class implements \StoneScriptPay\Http\Webhook\RateLimiter {
            public array $keys = [];
            public function allow(string $key): bool
            {
                $this->keys[] = $key;
                return false;
            }
        };
        $ingress = new WebhookIngress(['razorpay' => WebhookFixtures::gateway()], $this->store, new PlatformRoutingProcessor('plat', $this->inner), $this->alerts, $limiter);
        $body = WebhookFixtures::captured('pay_l', 'plat', 49900, 'ord_1');
        $r = $ingress->handle('razorpay', $body, WebhookFixtures::headers($body, 'evt_l'), '203.0.113.9');
        $this->assertSame(429, $r->httpStatus);
        $this->assertSame(['razorpay|203.0.113.9'], $limiter->keys);
        $this->assertSame(0, $this->store->recordCalls);
    }

    public function test_the_signature_header_is_declared_by_the_driver(): void
    {
        $this->assertSame('x-razorpay-signature', WebhookFixtures::gateway()->signatureHeader());
        $this->assertSame('x-razorpay-signature', WebhookFixtures::gateway()->provider->webhookSignatureHeader());
        $pp = new \StoneScriptPay\Drivers\PaypalDriver('https://api-m.sandbox.paypal.com', 'c', 's', 'WH');
        $this->assertSame('paypal-transmission-sig', (new \StoneScriptPay\Http\Webhook\WebhookGateway('paypal', $pp))->signatureHeader());
    }

    public function test_an_interrupted_delivery_is_finished_by_the_redelivery(): void
    {
        // the first delivery stored the event, then the worker died before recording an outcome
        $body = WebhookFixtures::captured('pay_x', 'plat', 49900, 'ord_1');
        $this->store->failMarkTimes = 1;
        $first = $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, 'evt_crash'));
        $this->assertSame(200, $first->httpStatus, 'durable, so acknowledged');
        $this->assertSame('received', $this->store->status('evt_crash'), 'outcome never recorded');
        $this->assertSame(1, $this->inner->applied['evt_crash']);
        // lease expiry (the SQL lease times out; here the dead worker's lease is dropped)
        $this->store->leased = [];
        $replayer = new WebhookReplayer($this->store, new PlatformRoutingProcessor('plat', $this->inner), $this->alerts);
        $this->assertSame([1 => 'applied'], $replayer->replay(50, 0));
        $this->assertSame(2, $this->inner->applied['evt_crash'], 'the processor ran again: it must be idempotent (the capture function is)');
    }

    public function test_a_delivery_that_cannot_claim_the_row_is_acknowledged_without_processing(): void
    {
        // another worker holds the lease on the row the redelivery finds as 'received'
        $this->store->failMarkTimes = 1;
        $body = WebhookFixtures::captured('pay_y', 'plat', 49900, 'ord_1');
        $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, 'evt_busy'));
        $this->assertSame(1, $this->inner->total());
        $this->store->leased = [1];
        $again = $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, 'evt_busy'));
        $this->assertSame(200, $again->httpStatus);
        $this->assertSame(1, $this->inner->total(), 'the lease holder owns it; this delivery processed nothing');
    }

    public function test_the_stored_headers_are_a_safe_subset(): void
    {
        $body = WebhookFixtures::captured('pay_h', 'plat', 49900, 'ord_1');
        $headers = WebhookFixtures::headers($body, 'evt_h') + ['Authorization' => 'Bearer secret', 'Cookie' => 'sid=1', 'X-Api-Key' => 'k'];
        $this->ingress->handle('razorpay', $body, $headers);
        $kept = array_keys($this->store->rows[1]['headers']);
        sort($kept);
        $this->assertSame(['content-type', 'x-razorpay-event-id'], $kept, 'no signature, no credentials');
    }

    public function test_webhook_event_survives_the_inbox_round_trip_without_personal_payload(): void
    {
        $body = WebhookFixtures::captured('pay_rt', 'plat', 49900, 'ord_rt');
        $event = WebhookFixtures::gateway()->provider->handleWebhook(
            new \StoneScriptPay\DTO\WebhookRequest($body, hash_hmac('sha256', $body, WebhookFixtures::SECRET), ['x-razorpay-event-id' => 'evt_rt'])
        );
        $this->assertSame('evt_rt', $event->eventId);
        $stored = $event->toArray();
        $this->assertArrayNotHasKey('payload', $stored, 'the provider-native payload (payer data) is not stored');
        $this->assertArrayNotHasKey('raw', $stored, 'nor the duplicated raw body');
        $again = WebhookEvent::fromArray(json_decode(json_encode($stored), true));
        $this->assertSame('pay_rt', $again->gatewayTxnRef);
        $this->assertSame(49900, $again->amountMinorUnits);
        $this->assertSame('plat', $again->platformCode);
        $this->assertSame('ord_rt', $again->orderRef);
        $this->assertSame('evt_rt', $again->eventId);
        $this->assertSame([], $again->payload);
    }
}
