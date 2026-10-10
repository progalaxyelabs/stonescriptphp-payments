<?php

declare(strict_types=1);

namespace Tests\Unit;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use StoneScriptPay\DTO\WebhookRequest;
use StoneScriptPay\Drivers\PaypalDriver;
use StoneScriptPay\Drivers\RazorpayDriver;
use StoneScriptPay\Exceptions\PaymentException;

/**
 * L7.3: mode derivation from the credentials, publishable key, and fetchPayment() for both
 * drivers, offline, through the injectable transports.
 */
final class DriverModeAndFetchTest extends TestCase
{
    private const SECRET = 'whsec';

    // ---- Razorpay mode ----

    public function test_razorpay_mode_comes_from_the_key_id_prefix(): void
    {
        $this->assertSame('test', (new RazorpayDriver('rzp_test_abc', 's', 'w'))->mode());
        $this->assertSame('live', (new RazorpayDriver('rzp_live_abc', 's', 'w'))->mode());
    }

    public function test_razorpay_mode_is_never_guessed(): void
    {
        $this->expectException(PaymentException::class);
        (new RazorpayDriver('somekey', 's', 'w'))->mode();
    }

    public function test_razorpay_webhook_only_instance_needs_an_explicit_mode(): void
    {
        $this->assertSame('live', (new RazorpayDriver('', '', 'w', 'live'))->mode());
        $this->expectException(PaymentException::class);
        (new RazorpayDriver('', '', 'w'))->mode();
    }

    public function test_razorpay_explicit_mode_contradicting_the_key_is_refused(): void
    {
        $this->expectException(PaymentException::class);
        (new RazorpayDriver('rzp_live_abc', 's', 'w', 'test'))->mode();
    }

    public function test_razorpay_rejects_an_invalid_explicit_mode(): void
    {
        $this->expectException(PaymentException::class);
        new RazorpayDriver('', '', 'w', 'staging');
    }

    public function test_razorpay_exposes_the_publishable_key_id(): void
    {
        $this->assertSame('rzp_test_abc', (new RazorpayDriver('rzp_test_abc', 's', 'w'))->publishableKeyId());
    }

    // ---- Razorpay fetchPayment ----

    private function razorpay(array $entity): RazorpayDriver
    {
        return new RazorpayDriver('rzp_test_abc', 's', 'w', null, static fn(string $id): array => $entity);
    }

    public function test_razorpay_fetch_payment_normalises_a_captured_payment(): void
    {
        $d = $this->razorpay([
            'id' => 'pay_1', 'status' => 'captured', 'amount' => 58882, 'currency' => 'INR', 'order_id' => 'order_9',
            'created_at' => 1790000000, 'notes' => ['order_id' => 'ord_x'],
        ])->fetchPayment('pay_1');
        $this->assertTrue($d->isCaptured());
        $this->assertSame('pay_1', $d->paymentId);
        $this->assertSame(58882, $d->amountMinorUnits);
        $this->assertSame('INR', $d->currency);
        $this->assertSame('order_9', $d->gatewayOrderId);
        $this->assertSame(1790000000, $d->capturedAt?->getTimestamp());
        $this->assertSame(['order_id' => 'ord_x'], $d->notes);
    }

    #[DataProvider('statuses')]
    public function test_razorpay_fetch_payment_status_mapping(string $raw, string $expected): void
    {
        $d = $this->razorpay(['id' => 'p', 'status' => $raw, 'amount' => 1, 'currency' => 'INR'])->fetchPayment('pay_p');
        $this->assertSame($expected, $d->status);
        $this->assertSame($expected === 'captured', $d->isCaptured());
    }

    public static function statuses(): array
    {
        return [['captured', 'captured'], ['authorized', 'authorized'], ['failed', 'failed'], ['refunded', 'refunded'], ['created', 'created'], ['weird', 'unknown']];
    }

    public function test_razorpay_fetch_payment_unreadable_response_is_an_error(): void
    {
        $this->expectException(PaymentException::class);
        $this->razorpay(['status' => 'captured'])->fetchPayment('pay_1');
    }

    public function test_razorpay_fetch_payment_wraps_a_gateway_failure(): void
    {
        $d = new RazorpayDriver('rzp_test_abc', 's', 'w', null, static function (string $id): array {
            throw new \RuntimeException('The id provided does not exist');
        });
        $this->expectException(PaymentException::class);
        $d->fetchPayment('pay_missing');
    }

    public function test_razorpay_fetch_payment_requires_an_id(): void
    {
        $this->expectException(PaymentException::class);
        $this->razorpay([])->fetchPayment('');
    }

    // ---- PayPal ----

    /** @param array<string,array{0:int,1:string}> $routes "METHOD path-prefix" => [status, body] */
    private function paypal(string $base, array $routes, array &$calls = []): PaypalDriver
    {
        return new PaypalDriver($base, 'client', 'secret', 'WH-1', static function (string $method, string $url, string $body, array $headers, ?string $auth) use ($routes, &$calls): array {
            $calls[] = "$method $url";
            if (str_contains($url, '/v1/oauth2/token')) {
                return [200, '{"access_token":"tok"}'];
            }
            foreach ($routes as $key => $resp) {
                [$m, $path] = explode(' ', $key, 2);
                if ($m === $method && str_contains($url, $path)) {
                    return $resp;
                }
            }

            return [404, '{}'];
        });
    }

    public function test_paypal_mode_comes_from_the_base_url(): void
    {
        $this->assertSame('test', $this->paypal('https://api-m.sandbox.paypal.com', [])->mode());
        $this->assertSame('live', $this->paypal('https://api-m.paypal.com', [])->mode());
    }

    public function test_paypal_mode_is_never_guessed_from_an_unknown_host(): void
    {
        $this->expectException(PaymentException::class);
        $this->paypal('https://paypal-proxy.internal.example', [])->mode();
    }

    public function test_paypal_exposes_the_client_id(): void
    {
        $this->assertSame('client', $this->paypal('https://api-m.sandbox.paypal.com', [])->publishableKeyId());
    }

    public function test_paypal_fetch_payment_normalises_a_completed_capture(): void
    {
        $calls = [];
        $d = $this->paypal('https://api-m.sandbox.paypal.com', ['GET /v2/payments/captures/CAP1' => [200, json_encode([
            'id' => 'CAP1', 'status' => 'COMPLETED', 'amount' => ['value' => '588.82', 'currency_code' => 'USD'],
            'custom_id' => 'ord_x|tenant|plat', 'update_time' => '2026-10-10T10:00:00Z',
            'supplementary_data' => ['related_ids' => ['order_id' => 'PPORDER1']],
        ])]], $calls)->fetchPayment('CAP1');
        $this->assertTrue($d->isCaptured());
        $this->assertSame(58882, $d->amountMinorUnits);
        $this->assertSame('USD', $d->currency);
        $this->assertSame('PPORDER1', $d->gatewayOrderId);
        $this->assertSame(['custom_id' => 'ord_x|tenant|plat'], $d->notes);
        $this->assertNotNull($d->capturedAt);
        $this->assertContains('GET https://api-m.sandbox.paypal.com/v2/payments/captures/CAP1', $calls);
    }

    public function test_paypal_fetch_payment_pending_is_not_captured(): void
    {
        $d = $this->paypal('https://api-m.sandbox.paypal.com', ['GET /v2/payments/captures/CAP2' => [200, json_encode([
            'id' => 'CAP2', 'status' => 'PENDING', 'amount' => ['value' => '1.00', 'currency_code' => 'USD'],
        ])]])->fetchPayment('CAP2');
        $this->assertFalse($d->isCaptured());
        $this->assertSame('authorized', $d->status);
    }

    public function test_paypal_fetch_payment_not_found_is_an_error(): void
    {
        $this->expectException(PaymentException::class);
        $this->paypal('https://api-m.sandbox.paypal.com', [])->fetchPayment('NOPE');
    }

    public function test_paypal_webhook_event_carries_event_id_and_order_ref(): void
    {
        $d = new PaypalDriver('https://api-m.sandbox.paypal.com', 'client', 'secret', 'WH-1', static function (string $method, string $url): array {
            return str_contains($url, 'oauth2/token') ? [200, '{"access_token":"t"}'] : [200, '{"verification_status":"SUCCESS"}'];
        });
        $body = json_encode(['id' => 'WH-EVT-1', 'event_type' => 'PAYMENT.CAPTURE.COMPLETED', 'resource' => [
            'id' => 'CAP9', 'custom_id' => 'ord_abc|00000000-0000-0000-0000-000000000001|plat',
            'amount' => ['value' => '10.00', 'currency_code' => 'USD'], 'create_time' => '2026-10-10T10:00:00Z',
        ]]);
        $e = $d->handleWebhook(new \StoneScriptPay\DTO\WebhookRequest($body, '', ['paypal-transmission-id' => 'x']));
        $this->assertSame('WH-EVT-1', $e->eventId);
        $this->assertSame('ord_abc', $e->orderRef);
        $this->assertSame('plat', $e->platformCode);
        $this->assertSame('CAP9', $e->gatewayTxnRef);
    }

    // ---- review fixes ----

    public function test_razorpay_fetch_payment_rejects_anything_that_is_not_a_payment_id(): void
    {
        $d = $this->razorpay(['id' => 'pay_1', 'status' => 'captured', 'amount' => 1, 'currency' => 'INR']);
        foreach (['', 'abc', 'pay_', 'pay_1/../orders', 'pay_1?x=1', 'order_1', "pay_1\n", 'pay 1'] as $bad) {
            try {
                $d->fetchPayment($bad);
                $this->fail('accepted: ' . json_encode($bad));
            } catch (PaymentException) {
                $this->addToAssertionCount(1);
            }
        }
        $this->assertSame('pay_1', $d->fetchPayment('pay_1')->paymentId);
    }

    public function test_razorpay_fetch_payment_reports_refunds_and_flags_the_capture_time_as_an_estimate(): void
    {
        $d = $this->razorpay(['id' => 'pay_2', 'status' => 'captured', 'amount' => 1000, 'currency' => 'INR', 'amount_refunded' => 250, 'created_at' => 1790000000])->fetchPayment('pay_2');
        $this->assertTrue($d->isCaptured());
        $this->assertTrue($d->isPartlyRefunded());
        $this->assertSame(250, $d->amountRefundedMinorUnits);
        $this->assertTrue($d->capturedAtIsEstimate);
    }

    public function test_razorpay_finds_an_existing_order_by_receipt(): void
    {
        $d = new RazorpayDriver('rzp_test_abc', 's', 'w', null, null, static fn(string $r): array => [
            ['id' => 'order_x', 'receipt' => 'other', 'amount' => 1, 'currency' => 'INR'],
            ['id' => 'order_y', 'receipt' => 'ord_abc', 'amount' => 5000, 'currency' => 'INR', 'status' => 'created'],
        ]);
        $o = $d->findOrderByReceipt('ord_abc');
        $this->assertSame('order_y', $o?->orderId);
        $this->assertNull($d->findOrderByReceipt('ord_none'));
    }

    public function test_razorpay_capture_time_prefers_the_gateways_then_the_event_time_and_flags_estimates(): void
    {
        $d = new RazorpayDriver('', '', self::SECRET);
        $mk = function (array $entityExtra, array $top) use ($d) {
            $body = json_encode($top + ['event' => 'payment.captured', 'payload' => ['payment' => ['entity' => $entityExtra + ['id' => 'pay_t', 'amount' => 1, 'currency' => 'INR', 'created_at' => 1000, 'notes' => []]]]]);

            return $d->handleWebhook(new WebhookRequest($body, hash_hmac('sha256', $body, self::SECRET), []));
        };
        $real = $mk(['captured_at' => 3000], ['created_at' => 2000]);
        $this->assertSame(3000, $real->capturedAt->getTimestamp());
        $this->assertFalse($real->capturedAtIsEstimate);
        $event = $mk([], ['created_at' => 2000]);
        $this->assertSame(2000, $event->capturedAt->getTimestamp(), 'the event time beats the payment creation time');
        $this->assertTrue($event->capturedAtIsEstimate);
        $created = $mk([], []);
        $this->assertSame(1000, $created->capturedAt->getTimestamp());
        $this->assertTrue($created->capturedAtIsEstimate);
    }

    public function test_paypal_create_order_is_idempotent_through_a_stable_request_id(): void
    {
        $headers = [];
        $d = new PaypalDriver('https://api-m.sandbox.paypal.com', 'c', 's', 'WH', static function (string $m, string $url, string $body, array $h) use (&$headers): array {
            if (str_contains($url, 'oauth2/token')) {
                return [200, '{"access_token":"t","expires_in":3600}'];
            }
            $headers[] = $h;

            return [201, '{"id":"PPORDER","status":"CREATED"}'];
        });
        $req = new \StoneScriptPay\DTO\CreateOrderRequest(58882, 'USD', 'ord_abc', ['tenant_id' => 't', 'platform_code' => 'plat']);
        $d->createOrder($req);
        $d->createOrder($req);
        $rid = static fn(array $h): string => implode('|', array_filter($h, fn($x) => str_starts_with($x, 'PayPal-Request-Id:')));
        $this->assertNotSame('', $rid($headers[0]));
        $this->assertSame($rid($headers[0]), $rid($headers[1]), 'the same receipt always carries the same PayPal-Request-Id');
        $d->createOrder(new \StoneScriptPay\DTO\CreateOrderRequest(58882, 'USD', 'ord_other', ['tenant_id' => 't', 'platform_code' => 'plat']));
        $this->assertNotSame($rid($headers[0]), $rid($headers[2]));
        $this->assertNull($d->findOrderByReceipt('ord_abc'), 'PayPal has no receipt lookup; request-id idempotency covers it');
    }

    public function test_paypal_server_side_capture_posts_with_a_request_id_and_normalises_the_capture(): void
    {
        $seen = [];
        $d = new PaypalDriver('https://api-m.sandbox.paypal.com', 'c', 's', 'WH', static function (string $m, string $url, string $body, array $h) use (&$seen): array {
            if (str_contains($url, 'oauth2/token')) {
                return [200, '{"access_token":"t","expires_in":3600}'];
            }
            $seen[] = [$m, $url, $h];

            return [201, json_encode(['id' => 'PPORDER', 'status' => 'COMPLETED', 'purchase_units' => [['payments' => ['captures' => [[
                'id' => 'CAP1', 'status' => 'COMPLETED', 'amount' => ['value' => '588.82', 'currency_code' => 'USD'], 'create_time' => '2026-10-10T04:30:00Z', 'custom_id' => 'ord_abc|t|plat',
            ]]]]]])];
        });
        $this->assertInstanceOf(\StoneScriptPay\Contracts\ServerSideCapture::class, $d);
        $p = $d->captureApprovedOrder('PPORDER', 'ord_abc');
        $this->assertTrue($p->isCaptured());
        $this->assertSame('CAP1', $p->paymentId);
        $this->assertSame(58882, $p->amountMinorUnits);
        $this->assertSame('PPORDER', $p->gatewayOrderId);
        $this->assertSame('POST', $seen[0][0]);
        $this->assertSame('https://api-m.sandbox.paypal.com/v2/checkout/orders/PPORDER/capture', $seen[0][1]);
        $this->assertNotEmpty(array_filter($seen[0][2], fn($x) => str_starts_with($x, 'PayPal-Request-Id:')));
        $this->expectException(PaymentException::class);
        $d->captureApprovedOrder('../evil', 'ord_abc');
    }
}
