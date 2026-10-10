<?php

declare(strict_types=1);

namespace Tests\Http;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\DTO\PaymentDetails;
use StoneScriptPay\Exceptions\PaymentException;
use StoneScriptPay\Http\Orders\AdminPaymentApplier;
use StoneScriptPay\Http\Orders\CaptureApplier;
use StoneScriptPay\Http\Orders\CaptureOutcome;
use StoneScriptPay\Http\Orders\OrderCreationInProgressException;
use StoneScriptPay\Http\Orders\OrderRequest;
use StoneScriptPay\Http\Orders\RefundRequiredException;
use StoneScriptPay\Http\Orders\OrderService;
use StoneScriptPay\Http\Orders\PaymentNotConfirmedException;
use StoneScriptPay\Http\Webhook\CaptureWebhookProcessor;
use StoneScriptPay\Http\Webhook\PlatformRoutingProcessor;
use StoneScriptPay\Http\Webhook\SqlWebhookInboxStore;
use StoneScriptPay\Http\Webhook\WebhookIngress;
use Tests\Http\Support\FakeProvider;
use Tests\Http\Support\FailableCaller;
use Tests\Http\Support\RecordingAlerts;
use Tests\Http\Support\WebhookFixtures;

/**
 * L7.3 acceptance through PHP against the REAL SQL (see WebhookInboxPostgresTest for the
 * PAYMENTS_TEST_PG_DSN contract): idempotent order creation with the gateway, the webhook ->
 * pay_apply_capture path with a genuinely signed Razorpay event, and the operator path that
 * refuses what the gateway does not confirm.
 */
final class OrdersPostgresTest extends TestCase
{
    private const PRICE = 58882;       // Rs 499 + 18% GST, paise

    private \PDO $pdo;
    private FailableCaller $caller;
    private FakeProvider $gateway;
    private OrderService $orders;
    private string $run;
    private string $tenant;
    private string $platform;
    private string $series;
    private int $planId;
    private RecordingAlerts $alerts;
    private WebhookIngress $ingress;

    protected function setUp(): void
    {
        $dsn = getenv('PAYMENTS_TEST_PG_DSN');
        if ($dsn === false || $dsn === '') {
            $this->markTestSkipped('PAYMENTS_TEST_PG_DSN is not set: the real-SQL order tests did not run.');
        }
        if (!extension_loaded('pdo_pgsql')) {
            $this->markTestSkipped('pdo_pgsql is not loaded in this PHP: the real-SQL order tests did not run.');
        }
        $this->pdo = new \PDO($dsn, null, null, [\PDO::ATTR_ERRMODE => \PDO::ERRMODE_EXCEPTION]);
        $this->caller = FailableCaller::forTests($this->pdo);
        $this->gateway = new FakeProvider('test');
        $this->orders = new OrderService($this->caller, ['razorpay' => $this->gateway]);
        $this->run = bin2hex(random_bytes(3));
        $this->tenant = sprintf('00000000-0000-4000-8000-%012x', random_int(1, 0xFFFFFFFFFFFF));
        $this->platform = 'plat';
        $this->alerts = new RecordingAlerts();

        $this->q("SELECT _inv_issuer_upsert(?, ?, NULL, 'Acme Pvt Ltd', 'regular', '29AAACX1234C1ZP', '29', 'Bengaluru', false, 'phpunit')",
            ["iss-{$this->run}", $this->platform]);
        $this->series = "ser-{$this->run}";
        for ($i = 0; $i < 30; $i++) {   // a short random TEST prefix; retry on the rare collision
            try {
                $this->q("SELECT _inv_series_create(?, ?, 'invoice', 'test', ?, '/', 3, true, 'phpunit')",
                    [$this->series, "iss-{$this->run}", 'TEST' . strtoupper(bin2hex(random_bytes(1)))]);
                break;
            } catch (\PDOException $e) {
                if ($i === 29) {
                    throw $e;
                }
            }
        }
        $this->q("INSERT INTO pricing_plans (name, is_subscription, is_active, is_trial, created_at, created_by) VALUES (?, true, true, false, now(), 'phpunit')", ["Monthly {$this->run}"]);
        $planPricing = (int) $this->pdo->query('SELECT max(id) FROM pricing_plans')->fetchColumn();
        $this->q("INSERT INTO subscription_pricing_plans (pricing_plan_id, duration, duration_uom, amount, is_amount_tax_exclusive, is_post_paid, is_active, created_at, created_by)
                  VALUES (?, 1, 'month', 49900, true, false, true, now(), 'phpunit')", [$planPricing]);
        $this->planId = (int) $this->pdo->query('SELECT max(id) FROM subscription_pricing_plans')->fetchColumn();

        $this->ingress = new WebhookIngress(
            ['razorpay' => WebhookFixtures::gateway('test')],
            new SqlWebhookInboxStore($this->caller),
            new PlatformRoutingProcessor($this->platform, new CaptureWebhookProcessor(new CaptureApplier($this->caller), ['razorpay' => $this->gateway])),
            $this->alerts,
        );
    }

    /** @param list<mixed> $args */
    private function q(string $sql, array $args = []): array
    {
        $s = $this->pdo->prepare($sql);
        $s->execute($args);

        return $s->columnCount() > 0 ? $s->fetchAll(\PDO::FETCH_ASSOC) : [];
    }

    private function scalar(string $sql, array $args = []): mixed
    {
        $rows = $this->q($sql, $args);

        return $rows === [] ? null : array_values($rows[0])[0];
    }

    private function request(string $key, int $amount = self::PRICE): OrderRequest
    {
        return new OrderRequest(
            tenantId: $this->tenant, platformCode: $this->platform, idempotencyKey: "{$this->run}-{$key}", gatewayCode: 'razorpay',
            purpose: OrderRequest::SUBSCRIPTION_PERIOD, amountMinorUnits: $amount, currency: 'INR',
            catalogRef: (string) $this->planId, seriesCode: $this->series,
            invoiceSpec: [
                'buyer' => ['legal_name' => 'Buyer One', 'registration_status' => 'unregistered', 'address_state' => 'Karnataka'],
                'billing_country_code' => 'IN', 'billing_state' => 'Karnataka', 'supply_type' => 'domestic',
                'price_is_inclusive' => false, 'round_off' => false, 'due_days' => 0,
                'lines' => [['description' => 'Monthly plan', 'hsn_sac' => '998314', 'quantity' => '1', 'unit_price' => '499.00', 'gst_rate' => 0.18]],
            ],
        );
    }

    /**
     * Over PDO the SQLSTATE is the exception code. Through the gateway it is deliberately NOT in the HTTP answer (the gateway
     * keeps error detail out of responses and logs the SQLSTATE), so there the SQL's own message is what identifies the refusal.
     */
    private function assertRefusal(int|string $code, string $message, string $sqlstate, string $messageFragment): void
    {
        if ($this->caller instanceof \Tests\Http\Support\GatewayHttpCaller) {
            $this->assertStringContainsString($messageFragment, $message);

            return;
        }
        $this->assertSame($sqlstate, $code);
    }

    private function invoicesFor(string $orderRef): int
    {
        return (int) $this->scalar('SELECT count(*) FROM inv_invoices WHERE charge_ref = ?', [$orderRef]);
    }

    private function deliver(string $eventId, string $paymentId, string $orderRef, int $amount = self::PRICE, ?string $tenant = null, ?string $platform = 'plat')
    {
        $body = WebhookFixtures::captured($paymentId, $platform, $amount, $orderRef, $tenant ?? $this->tenant);

        return $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, $eventId));
    }

    // ------------------------------------------------------------------ order creation

    public function test_order_creation_is_idempotent_and_makes_one_gateway_order(): void
    {
        $first = $this->orders->create($this->request('a'));
        $second = $this->orders->create($this->request('a'));

        $this->assertTrue($first->isNew);
        $this->assertFalse($second->isNew);
        $this->assertSame($first->orderRef, $second->orderRef, 'a client retry returns the same order');
        $this->assertSame($first->gatewayOrderId, $second->gatewayOrderId);
        $this->assertCount(1, $this->gateway->createdOrders, 'the gateway was asked for one order only');
        $this->assertSame('open', $second->status);
        $this->assertSame('test', $first->mode);
        $this->assertSame('rzp_test_fake', $second->publishableKeyId, 'a retry still returns the checkout key without calling the gateway');
        $n = $this->gateway->createdOrders[0];
        $this->assertSame(self::PRICE, $n->amountMinorUnits);
        $this->assertSame($first->orderRef, $n->receipt);
        $this->assertSame($first->orderRef, $n->notes['order_id']);
        $this->assertSame($this->platform, $n->notes['platform_code']);
        $this->assertSame($this->tenant, $n->notes['tenant_id']);
        $this->assertSame(1, (int) $this->scalar('SELECT count(*) FROM pay_orders WHERE idempotency_key = ?', ["{$this->run}-a"]));
    }

    public function test_the_same_key_for_a_different_request_is_refused(): void
    {
        $this->orders->create($this->request('b'));
        try {
            $this->orders->create($this->request('b', self::PRICE + 1));
            $this->fail('expected the reuse of the key to be refused');
        } catch (\PDOException $e) {
            $this->assertRefusal($e->getCode(), $e->getMessage(), 'PY036', 'already used for a different order request');
        }
    }

    public function test_a_gateway_failure_leaves_a_retryable_order_and_the_retry_creates_exactly_one_gateway_order(): void
    {
        $this->gateway->failCreateTimes = 1;
        try {
            $this->orders->create($this->request('c'));
            $this->fail('expected the gateway failure to surface');
        } catch (PaymentException) {
        }
        $this->assertSame('created', $this->scalar('SELECT status FROM pay_orders WHERE idempotency_key = ?', ["{$this->run}-c"]));
        $this->assertNull($this->scalar('SELECT gateway_order_id FROM pay_orders WHERE idempotency_key = ?', ["{$this->run}-c"]));

        $view = $this->orders->create($this->request('c'));
        $this->assertFalse($view->isNew, 'same order row as the failed attempt');
        $this->assertNotNull($view->gatewayOrderId);
        $this->assertCount(1, $this->gateway->createdOrders);
    }

    public function test_mode_comes_from_the_driver_and_cannot_cross_series_modes(): void
    {
        $live = new OrderService($this->caller, ['razorpay' => new FakeProvider('live', 'rzp_live_fake')]);
        try {
            $live->create($this->request('d'));
            $this->fail('a live-mode order must not use a test series');
        } catch (\PDOException $e) {
            $this->assertRefusal($e->getCode(), $e->getMessage(), 'PY012', 'but the order is in');
        }
        $this->assertSame(0, (int) $this->scalar('SELECT count(*) FROM pay_orders WHERE idempotency_key = ?', ["{$this->run}-d"]));
    }

    public function test_status_poll_is_tenant_scoped(): void
    {
        $o = $this->orders->create($this->request('e'));
        $this->assertSame('open', $this->orders->status($o->orderRef, $this->tenant, $this->platform)['o_status']);
        $this->assertNull($this->orders->status($o->orderRef, '00000000-0000-4000-8000-00000000dead', $this->platform));
    }

    // ------------------------------------------------------------------ webhook -> pay_apply_capture

    public function test_a_signed_capture_webhook_applies_once_even_when_the_gateway_redelivers_it_under_new_event_ids(): void
    {
        $o = $this->orders->create($this->request('f'));
        $r = $this->deliver("evt_{$this->run}_1", "pay_{$this->run}_f", $o->orderRef);
        $this->assertSame(200, $r->httpStatus);
        $this->assertSame('applied', $r->data['status']);
        $this->assertSame(1, $this->invoicesFor($o->orderRef));
        $inv = $this->q("SELECT * FROM inv_invoices WHERE charge_ref = ?", [$o->orderRef])[0];
        $this->assertSame('paid', $inv['status']);
        $this->assertSame((string) self::PRICE, (string) $inv['gross_total_minor']);
        $this->assertSame('test', $inv['mode']);
        $this->assertStringStartsWith('TEST', $inv['invoice_number']);
        $this->assertSame('paid', $this->scalar('SELECT status FROM pay_orders WHERE order_ref = ?', [$o->orderRef]));
        $this->assertSame('paid', $this->orders->status($o->orderRef, $this->tenant, $this->platform)['o_status'], 'the status poll sees the webhook-applied state');

        // same event id again: inbox no-op
        $this->deliver("evt_{$this->run}_1", "pay_{$this->run}_f", $o->orderRef);
        // the gateway sending the same payment under a NEW event id: capture-level idempotency
        $r3 = $this->deliver("evt_{$this->run}_2", "pay_{$this->run}_f", $o->orderRef);
        $this->assertSame('applied', $r3->data['status']);
        $this->assertSame(1, $this->invoicesFor($o->orderRef), 'still exactly one invoice');
        $this->assertSame(1, (int) $this->scalar("SELECT count(*) FROM pay_events WHERE order_ref = ? AND event_type = 'payment.applied'", [$o->orderRef]));
        $this->assertSame(1, (int) $this->scalar('SELECT count(*) FROM customer_pricing_plans WHERE tenant_id = ?::uuid AND subscription_pricing_plan_id = ?', [$this->tenant, $this->planId]));
        $this->assertSame([], $this->alerts->alerts);
    }

    public function test_a_capture_for_an_unknown_order_is_unattributed_and_alerts_once(): void
    {
        $r = $this->deliver("evt_{$this->run}_u", "pay_{$this->run}_u", 'ord_' . str_repeat('0', 32));
        $this->assertSame('unattributed', $r->data['status']);
        $this->assertSame(['webhook.unattributed'], $this->alerts->kinds());
        $this->assertSame(0, (int) $this->scalar('SELECT count(*) FROM pay_captured_payments WHERE gateway_txn_ref = ?', ["pay_{$this->run}_u"]));
        $this->assertSame(0, (int) $this->scalar('SELECT count(*) FROM inv_invoices WHERE tenant_id = ?::uuid', [$this->tenant]));
    }

    public function test_a_capture_with_the_wrong_amount_tenant_or_mode_is_refused_and_alerted_and_writes_nothing(): void
    {
        $o = $this->orders->create($this->request('g'));
        $wrongAmount = $this->deliver("evt_{$this->run}_ga", "pay_{$this->run}_ga", $o->orderRef, self::PRICE - 100);
        $wrongTenant = $this->deliver("evt_{$this->run}_gt", "pay_{$this->run}_gt", $o->orderRef, self::PRICE, '00000000-0000-4000-8000-00000000beef');
        $this->assertSame('failed', $wrongAmount->data['status']);
        $this->assertSame('failed', $wrongTenant->data['status']);
        $this->assertSame(2, count($this->alerts->alerts));
        $this->assertSame(0, $this->invoicesFor($o->orderRef));
        $this->assertSame('open', $this->scalar('SELECT status FROM pay_orders WHERE order_ref = ?', [$o->orderRef]));
        $this->assertSame(0, (int) $this->scalar("SELECT count(*) FROM pay_captured_payments WHERE gateway_txn_ref LIKE ?", ["pay_{$this->run}_g%"]));
        foreach (['ga', 'gt'] as $k) {
            $err = (string) $this->scalar('SELECT last_error FROM pay_webhook_inbox WHERE headers->>\'x-razorpay-event-id\' = ?', ["evt_{$this->run}_{$k}"]);
            $this->assertTrue(str_contains($err, 'SQLSTATE[PY031]') || str_contains($err, 'does not match order') || str_contains($err, 'names tenant/platform'),
                'the failed row says why (a PY031 mismatch), for the operator: ' . $err);
        }

        // a webhook gateway configured for the OTHER mode is refused by mode, not applied
        $liveIngress = new WebhookIngress(
            ['razorpay' => WebhookFixtures::gateway('live')],
            new SqlWebhookInboxStore($this->caller),
            new PlatformRoutingProcessor($this->platform, new CaptureWebhookProcessor(new CaptureApplier($this->caller), ['razorpay' => new FakeProvider('live')])),
            $this->alerts,
        );
        $body = WebhookFixtures::captured("pay_{$this->run}_gm", 'plat', self::PRICE, $o->orderRef, $this->tenant);
        $liveIngress->handle('razorpay', $body, WebhookFixtures::headers($body, "evt_{$this->run}_gm"));
        $this->assertSame('failed', $this->scalar('SELECT status FROM pay_webhook_inbox WHERE headers->>\'x-razorpay-event-id\' = ?', ["evt_{$this->run}_gm"]));
        $this->assertStringContainsString($this->caller instanceof \Tests\Http\Support\GatewayHttpCaller ? 'is in mode' : 'capture is in mode live', (string) $this->scalar('SELECT last_error FROM pay_webhook_inbox WHERE headers->>\'x-razorpay-event-id\' = ?', ["evt_{$this->run}_gm"]));
        $this->assertSame(0, $this->invoicesFor($o->orderRef), 'a live capture never settles a test order');

        // and the right capture still works afterwards
        $ok = $this->deliver("evt_{$this->run}_gok", "pay_{$this->run}_gok", $o->orderRef);
        $this->assertSame('applied', $ok->data['status']);
        $this->assertSame(1, $this->invoicesFor($o->orderRef));
    }

    // ------------------------------------------------------------------ operator path

    private function admin(): AdminPaymentApplier
    {
        return new AdminPaymentApplier($this->caller, new CaptureApplier($this->caller), ['razorpay' => $this->gateway]);
    }

    private function payment(string $id, string $gatewayOrderId, string $status = 'captured', int $amount = self::PRICE, string $currency = 'INR'): void
    {
        $this->gateway->payments[$id] = new PaymentDetails($id, $status, $amount, $currency, $gatewayOrderId,
            new \DateTimeImmutable('2026-10-10T10:00:00+05:30'), [], ['id' => $id]);
    }

    public function test_the_operator_path_applies_only_what_the_gateway_confirms_and_stays_exactly_once_with_a_late_webhook(): void
    {
        $o = $this->orders->create($this->request('h'));
        $pid = "pay_{$this->run}_h";

        // refusals: each writes nothing
        $cases = [
            'not captured' => fn() => $this->payment($pid, $o->gatewayOrderId, 'authorized'),
            'wrong amount' => fn() => $this->payment($pid, $o->gatewayOrderId, 'captured', self::PRICE - 1),
            'wrong currency' => fn() => $this->payment($pid, $o->gatewayOrderId, 'captured', self::PRICE, 'USD'),
            'another order' => fn() => $this->payment($pid, 'order_somebody_else'),
            'failed' => fn() => $this->payment($pid, $o->gatewayOrderId, 'failed'),
        ];
        foreach ($cases as $label => $arrange) {
            $arrange();
            try {
                $this->admin()->apply($this->tenant, $this->platform, $o->orderRef, 'razorpay', $pid, 'ops-person');
                $this->fail("expected refusal: {$label}");
            } catch (PaymentNotConfirmedException) {
            }
            $this->assertSame(0, $this->invoicesFor($o->orderRef), "nothing written: {$label}");
            $this->assertSame(0, (int) $this->scalar('SELECT count(*) FROM pay_captured_payments WHERE gateway_txn_ref = ?', [$pid]));
        }
        unset($this->gateway->payments[$pid]);
        try {
            $this->admin()->apply($this->tenant, $this->platform, $o->orderRef, 'razorpay', $pid, 'ops-person');
            $this->fail('a payment id the gateway does not know must be refused');
        } catch (PaymentException) {
        }
        $this->assertSame(0, $this->invoicesFor($o->orderRef));

        // an operator name is mandatory
        $this->payment($pid, $o->gatewayOrderId);
        try {
            $this->admin()->apply($this->tenant, $this->platform, $o->orderRef, 'razorpay', $pid, ' ');
            $this->fail('an anonymous operator must be refused');
        } catch (\InvalidArgumentException) {
        }
        // another tenant cannot apply to this order
        try {
            $this->admin()->apply('00000000-0000-4000-8000-00000000dead', $this->platform, $o->orderRef, 'razorpay', $pid, 'ops-person');
            $this->fail('another tenant must not reach this order');
        } catch (PaymentNotConfirmedException) {
        }

        // confirmed: applied, attributed to the operator
        $out = $this->admin()->apply($this->tenant, $this->platform, $o->orderRef, 'razorpay', $pid, 'ops-person');
        $this->assertSame(CaptureOutcome::APPLIED, $out->outcome);
        $this->assertSame(1, $this->invoicesFor($o->orderRef));
        $this->assertSame('admin:ops-person', $this->scalar('SELECT created_by FROM pay_captured_payments WHERE gateway_txn_ref = ?', [$pid]));
        $this->assertSame('paid', $this->scalar('SELECT status FROM pay_orders WHERE order_ref = ?', [$o->orderRef]));

        // a second operator click and the webhook that finally arrives are both already_applied
        $again = $this->admin()->apply($this->tenant, $this->platform, $o->orderRef, 'razorpay', $pid, 'ops-person');
        $this->assertSame(CaptureOutcome::ALREADY_APPLIED, $again->outcome);
        $late = $this->deliver("evt_{$this->run}_late", $pid, $o->orderRef);
        $this->assertSame('applied', $late->data['status']);
        $this->assertSame(1, $this->invoicesFor($o->orderRef), 'exactly once across operator + webhook');
        $this->assertSame(1, (int) $this->scalar("SELECT count(*) FROM pay_events WHERE order_ref = ? AND event_type = 'payment.applied'", [$o->orderRef]));
    }

    // ------------------------------------------------------------------ review fixes

    public function test_the_gateway_order_is_created_by_one_request_only_and_a_crashed_creator_is_found_by_receipt(): void
    {
        // a request that lost the creation lease waits for the winner's attach, then is handed the same order
        $svc = new OrderService($this->caller, ['razorpay' => $this->gateway], null, 1, 0);
        $first = $this->orders->create($this->request('l1'));
        $this->assertCount(1, $this->gateway->createdOrders);

        $req = $this->request('l2');
        // simulate: another request holds the lease and has not attached yet
        $row = $this->q('SELECT o_order_ref FROM pay_order_create(?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?)', [
            $this->tenant, $this->platform, "{$this->run}-l2", $req->purpose, $req->catalogRef, $req->amountMinorUnits, $req->currency,
            'razorpay', 'test', $this->series, json_encode($req->invoiceSpec), 'phpunit'])[0];
        $this->assertTrue((bool) $this->q('SELECT pay_order_begin_gateway_create(?, 30) AS b', [$row['o_order_ref']])[0]['b']);
        try {
            $svc->create($req);
            $this->fail('a request that cannot get the lease and sees no attach must say so, not create a second order');
        } catch (OrderCreationInProgressException) {
        }
        $this->assertCount(1, $this->gateway->createdOrders, 'no second gateway order was created');
        // the winner attaches; the next retry returns that very order
        $this->q('SELECT * FROM pay_order_attach_gateway_order(?, ?)', [$row['o_order_ref'], 'order_winner_' . $this->run]);
        $again = $svc->create($req);
        $this->assertSame('order_winner_' . $this->run, $again->gatewayOrderId);
        $this->assertSame($row['o_order_ref'], $again->orderRef);
        $this->assertCount(1, $this->gateway->createdOrders);

        // crashed creator: the gateway already has an order with our receipt but we never attached it
        $req3 = $this->request('l3');
        $row3 = $this->q('SELECT o_order_ref FROM pay_order_create(?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?)', [
            $this->tenant, $this->platform, "{$this->run}-l3", $req3->purpose, $req3->catalogRef, $req3->amountMinorUnits, $req3->currency,
            'razorpay', 'test', $this->series, json_encode($req3->invoiceSpec), 'phpunit'])[0];
        $this->gateway->existingByReceipt[$row3['o_order_ref']] = new \StoneScriptPay\DTO\OrderResult('order_found_' . $this->run, self::PRICE, 'INR', $row3['o_order_ref'], 'k', 'created', []);
        $view = $this->orders->create($req3);
        $this->assertSame('order_found_' . $this->run, $view->gatewayOrderId, 'the existing gateway order is reused');
        $this->assertCount(1, $this->gateway->createdOrders, 'and no new one was created');
    }

    public function test_a_server_side_capture_after_approval_completes_the_order_exactly_once_with_the_webhook(): void
    {
        $pp = new \Tests\Http\Support\FakeCapturingProvider('test', 'ppclient');
        $pp->amount = self::PRICE;
        $applier = new CaptureApplier($this->caller);
        $svc = new OrderService($this->caller, ['razorpay' => $pp], $applier, 1, 0);
        $o = $svc->create($this->request('pp'));
        $out = $svc->completeApproval($this->tenant, $this->platform, $o->orderRef);
        $this->assertSame(CaptureOutcome::APPLIED, $out->outcome);
        $this->assertSame(1, $this->invoicesFor($o->orderRef));
        $again = $svc->completeApproval($this->tenant, $this->platform, $o->orderRef);      // a retry of the same call
        $this->assertSame(CaptureOutcome::ALREADY_APPLIED, $again->outcome);
        $this->assertSame(1, $this->invoicesFor($o->orderRef));
        $this->assertCount(2, $pp->captureCalls);
        $this->assertSame($pp->captureCalls[0][1], $pp->captureCalls[1][1], 'the same request id both times: a retried capture cannot double-charge');
        $this->assertSame($o->orderRef, $pp->captureCalls[0][1]);
        $this->assertStringStartsWith('server-capture:razorpay', (string) $this->scalar('SELECT created_by FROM pay_captured_payments WHERE reference = ?', [$o->orderRef]));
        $raw = (string) $this->scalar('SELECT raw_payload::text FROM pay_captured_payments WHERE reference = ?', [$o->orderRef]);
        $this->assertStringNotContainsString('payer@example.test', $raw, 'no personal data in the accounting record');
        $this->assertStringContainsString('body_sha256', $raw);

        // not approved / wrong gateway kind are refused without writing
        $pp->approved = false;
        $o2 = $svc->create($this->request('pp2'));
        try {
            $svc->completeApproval($this->tenant, $this->platform, $o2->orderRef);
            $this->fail('an unapproved order must not be captured');
        } catch (PaymentException) {
        }
        $this->assertSame(0, $this->invoicesFor($o2->orderRef));
        $plain = new OrderService($this->caller, ['razorpay' => $this->gateway], $applier, 1, 0);
        $this->expectException(\LogicException::class);
        $plain->completeApproval($this->tenant, $this->platform, $o2->orderRef);
    }

    public function test_a_partly_refunded_payment_is_refused_by_the_operator_path_unless_explicitly_allowed(): void
    {
        $o = $this->orders->create($this->request('pr'));
        $pid = "pay_{$this->run}_pr";
        $this->gateway->payments[$pid] = new PaymentDetails($pid, 'captured', self::PRICE, 'INR', $o->gatewayOrderId, new \DateTimeImmutable('2026-10-10T10:00:00+05:30'), [], ['id' => $pid], 10000);
        try {
            $this->admin()->apply($this->tenant, $this->platform, $o->orderRef, 'razorpay', $pid, 'ops-person');
            $this->fail('a partly refunded payment must be refused');
        } catch (PaymentNotConfirmedException $e) {
            $this->assertStringContainsString('partly refunded', $e->getMessage());
        }
        $this->assertSame(0, $this->invoicesFor($o->orderRef));
        $out = $this->admin()->apply($this->tenant, $this->platform, $o->orderRef, 'razorpay', $pid, 'ops-person', true);
        $this->assertSame(CaptureOutcome::APPLIED, $out->outcome);
    }

    public function test_money_for_an_already_paid_order_fails_the_inbox_row_loudly_and_sits_in_the_refund_queue(): void
    {
        $o = $this->orders->create($this->request('rq'));
        $this->deliver("evt_{$this->run}_rq1", "pay_{$this->run}_rq1", $o->orderRef);
        $dup = $this->deliver("evt_{$this->run}_rq2", "pay_{$this->run}_rq2", $o->orderRef);      // a second, different payment
        $this->assertSame('failed', $dup->data['status']);
        $this->assertContains('webhook.failed', $this->alerts->kinds());
        $this->assertStringContainsString(RefundRequiredException::class, (string) $this->scalar('SELECT last_error FROM pay_webhook_inbox WHERE headers->>\'x-razorpay-event-id\' = ?', ["evt_{$this->run}_rq2"]));
        $this->assertSame(1, (int) $this->scalar("SELECT count(*) FROM pay_refund_queue WHERE gateway_txn_ref = ? AND status = 'open'", ["pay_{$this->run}_rq2"]));
        $this->assertSame(1, $this->invoicesFor($o->orderRef), 'still exactly one invoice');
    }

    public function test_the_stored_capture_record_holds_no_personal_data(): void
    {
        $o = $this->orders->create($this->request('pii'));
        $body = json_encode(['event' => 'payment.captured', 'created_at' => 1790000100, 'payload' => ['payment' => ['entity' => [
            'id' => "pay_{$this->run}_pii", 'amount' => self::PRICE, 'currency' => 'INR', 'created_at' => 1790000000, 'email' => 'payer@example.test', 'contact' => '+910000000000',
            'notes' => ['order_id' => $o->orderRef, 'platform_code' => $this->platform, 'tenant_id' => $this->tenant],
        ]]]]);
        $this->ingress->handle('razorpay', $body, WebhookFixtures::headers($body, "evt_{$this->run}_pii"));
        $raw = (string) $this->scalar('SELECT raw_payload::text FROM pay_captured_payments WHERE reference = ?', [$o->orderRef]);
        $this->assertStringNotContainsString('payer@example.test', $raw);
        $this->assertStringNotContainsString('+91', $raw);
        $this->assertStringContainsString(hash('sha256', $body), $raw, 'the hash of the full body proves what arrived');
        $this->assertStringContainsString("pay_{$this->run}_pii", $raw);
        // the capture time is the EVENT time (1790000100), not the payment creation time, and is flagged as an estimate
        $this->assertStringContainsString(':capture-time-estimated', (string) $this->scalar('SELECT created_by FROM pay_captured_payments WHERE reference = ?', [$o->orderRef]));
        $this->assertSame(1790000100, (int) $this->scalar('SELECT extract(epoch FROM captured_at) FROM pay_captured_payments WHERE reference = ?', [$o->orderRef]));
    }
}
