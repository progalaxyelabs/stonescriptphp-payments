<?php

declare(strict_types=1);

namespace Tests\Unit;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\DTO\CreateOrderRequest;
use StoneScriptPay\DTO\VerifyRequest;
use StoneScriptPay\DTO\WebhookRequest;
use StoneScriptPay\Drivers\RazorpayDriver;
use StoneScriptPay\Exceptions\PaymentException;
use StoneScriptPay\Exceptions\SignatureVerificationException;
use StoneScriptPay\Exceptions\WebhookException;

/**
 * Unit tests for RazorpayDriver.
 *
 * These tests do NOT make real API calls — they test the driver's own logic:
 *   - Constructor validation
 *   - HMAC signature verification (using known test vectors)
 *   - Webhook signature verification
 *   - Event type normalisation
 *   - Error handling / exception mapping
 *
 * Integration tests against the live Razorpay test API are out of scope
 * (would require real credentials and a network call).
 */
class RazorpayDriverTest extends TestCase
{
    // -------------------------------------------------------------------------
    // Constructor — lazy API-client validation (v0.2.0+)
    // -------------------------------------------------------------------------

    /**
     * Construction with empty keyId/keySecret no longer throws eagerly — a
     * driver built for webhook-only use (e.g. a consuming app's
     * subscription glue, which historically only ever held a webhook
     * secret) must be constructible without real API keys. Only an actual API-touching
     * call throws, lazily, at call time. See RazorpayDriver::getApi().
     */
    public function test_constructor_does_not_throw_with_empty_key_id(): void
    {
        $driver = new RazorpayDriver('', 'secret', 'webhooksecret');
        $this->assertInstanceOf(RazorpayDriver::class, $driver);
    }

    public function test_constructor_does_not_throw_with_empty_key_secret(): void
    {
        $driver = new RazorpayDriver('keyId', '', 'webhooksecret');
        $this->assertInstanceOf(RazorpayDriver::class, $driver);
    }

    public function test_create_order_throws_lazily_when_key_id_is_empty(): void
    {
        $driver = new RazorpayDriver('', 'secret', 'webhooksecret');

        $this->expectException(PaymentException::class);
        $driver->createOrder(new CreateOrderRequest(49900, 'INR', 'receipt_001'));
    }

    public function test_create_order_throws_lazily_when_key_secret_is_empty(): void
    {
        $driver = new RazorpayDriver('keyId', '', 'webhooksecret');

        $this->expectException(PaymentException::class);
        $driver->createOrder(new CreateOrderRequest(49900, 'INR', 'receipt_001'));
    }

    /**
     * The exact scenario this tightening exists for: a webhook-only driver
     * (no API keys at all) can still verify+parse a webhook.
     */
    public function test_webhook_only_driver_with_no_api_keys_still_handles_webhook(): void
    {
        $webhookSecret = 'whsec_test';
        $driver = new RazorpayDriver('', '', $webhookSecret);

        $body = json_encode(['event' => 'payment.captured', 'payload' => []]);
        $signature = hash_hmac('sha256', $body, $webhookSecret);

        $event = $driver->handleWebhook(new WebhookRequest($body, $signature));

        $this->assertSame('payment.captured', $event->type);
    }

    public function test_settlement_model_is_gateway(): void
    {
        $driver = new RazorpayDriver('keyId', 'keySecret', 'webhooksecret');
        $this->assertSame('gateway', $driver->settlementModel());
    }

    // -------------------------------------------------------------------------
    // verifySignature — HMAC test vectors
    // -------------------------------------------------------------------------

    /**
     * Razorpay signature formula: HMAC-SHA256("{orderId}|{paymentId}", keySecret)
     *
     * We compute the expected signature ourselves and pass it in — confirming
     * the driver accepts a correctly-signed response without making an API call.
     *
     * NOTE: The Razorpay PHP SDK's verifyPaymentSignature() does the same HMAC
     * computation internally, so this test confirms the formula is correct.
     */
    public function test_verify_signature_accepts_correct_hmac(): void
    {
        $keyId     = 'rzp_test_TestKeyId123';
        $keySecret = 'TestKeySecret456';
        $orderId   = 'order_ABCDEF1234567890';
        $paymentId = 'pay_XYZ9876543210';

        // Compute the expected signature using Razorpay's formula
        $expectedSig = hash_hmac('sha256', "{$orderId}|{$paymentId}", $keySecret);

        $driver = new RazorpayDriver($keyId, $keySecret, 'webhooksecret');
        $result = $driver->verifySignature(new VerifyRequest($paymentId, $orderId, $expectedSig));

        $this->assertTrue($result->verified);
        $this->assertSame($paymentId, $result->paymentId);
        $this->assertSame($orderId, $result->orderId);
    }

    public function test_verify_signature_throws_on_wrong_signature(): void
    {
        $driver = new RazorpayDriver('rzp_test_key', 'secret', 'webhooksecret');

        $this->expectException(SignatureVerificationException::class);
        $driver->verifySignature(new VerifyRequest('pay_123', 'order_123', 'badsignature'));
    }

    public function test_verify_signature_throws_on_empty_signature(): void
    {
        $driver = new RazorpayDriver('rzp_test_key', 'secret', 'webhooksecret');

        $this->expectException(SignatureVerificationException::class);
        $driver->verifySignature(new VerifyRequest('pay_123', 'order_123', ''));
    }

    // -------------------------------------------------------------------------
    // handleWebhook — HMAC and parse tests
    // -------------------------------------------------------------------------

    /**
     * Build a valid webhook request with the correct HMAC and confirm the driver
     * parses and returns it correctly — without making any network call.
     */
    public function test_handle_webhook_accepts_valid_signature_and_parses_event(): void
    {
        $webhookSecret = 'whsec_test_WebhookSecret';
        $driver        = new RazorpayDriver('rzp_test_key', 'keysecret', $webhookSecret);

        $body = json_encode([
            'event'   => 'payment.captured',
            'payload' => [
                'payment' => [
                    'entity' => [
                        'id'     => 'pay_ABC123',
                        'amount' => 49900,
                        'email'  => 'user@example.com',
                    ],
                ],
            ],
        ]);

        $signature = hash_hmac('sha256', $body, $webhookSecret);
        $event     = $driver->handleWebhook(new WebhookRequest($body, $signature));

        $this->assertSame('payment.captured', $event->type);
        $this->assertSame('payment.captured', $event->providerEvent);
        $this->assertTrue($event->isPaymentCaptured());
        $this->assertArrayHasKey('payment', $event->payload);
    }

    /**
     * The provider-agnostic fields CollectionOrchestrator's settleFromWebhook()
     * relies on — populated from Razorpay's native payload.payment.entity shape.
     */
    public function test_handle_webhook_populates_normalised_fields_for_payment_captured(): void
    {
        $webhookSecret = 'whsec_test_WebhookSecret';
        $driver = new RazorpayDriver('rzp_test_key', 'keysecret', $webhookSecret);

        $body = json_encode([
            'event' => 'payment.captured',
            'payload' => [
                'payment' => [
                    'entity' => [
                        'id' => 'pay_ABC123',
                        'amount' => 49900,
                        'currency' => 'INR',
                        'created_at' => 1_757_800_000,
                        'notes' => ['invoice_ref' => 'inv_42', 'tenant_id' => 'tenant-A', 'platform_code' => 'platform-A'],
                    ],
                ],
            ],
        ]);
        $signature = hash_hmac('sha256', $body, $webhookSecret);

        $event = $driver->handleWebhook(new WebhookRequest($body, $signature));

        $this->assertSame('inv_42', $event->invoiceRef);
        $this->assertSame('pay_ABC123', $event->gatewayTxnRef);
        $this->assertSame(49900, $event->amountMinorUnits);
        $this->assertSame('INR', $event->currency);
        $this->assertInstanceOf(\DateTimeImmutable::class, $event->capturedAt);
        $this->assertSame(1_757_800_000, $event->capturedAt->getTimestamp());
        // TENANT ISOLATION round-trip (added 2026-09-22): tenant_id/platform_code
        // embedded in the order's notes at checkout time (CollectionOrchestrator::
        // initiateCollection()) are echoed back by Razorpay verbatim and must
        // come through untouched — see WebhookEvent's docblock.
        $this->assertSame('tenant-A', $event->tenantId);
        $this->assertSame('platform-A', $event->platformCode);
    }

    public function test_handle_webhook_leaves_tenant_fields_null_when_notes_carry_no_tenant_context(): void
    {
        // An order created without CollectionOrchestrator (e.g. a bare
        // integration using this driver directly) never populated
        // notes.tenant_id/platform_code — the driver must not invent them.
        $webhookSecret = 'whsec_test_notenant';
        $driver = new RazorpayDriver('rzp_test_key', 'keysecret', $webhookSecret);

        $body = json_encode([
            'event' => 'payment.captured',
            'payload' => [
                'payment' => [
                    'entity' => [
                        'id' => 'pay_NOTENANT',
                        'amount' => 100,
                        'currency' => 'INR',
                        'created_at' => 1_757_800_000,
                        'notes' => ['invoice_ref' => 'inv_1'],
                    ],
                ],
            ],
        ]);
        $signature = hash_hmac('sha256', $body, $webhookSecret);

        $event = $driver->handleWebhook(new WebhookRequest($body, $signature));

        $this->assertNull($event->tenantId);
        $this->assertNull($event->platformCode);
    }

    public function test_handle_webhook_leaves_normalised_fields_null_for_non_settlement_event(): void
    {
        $webhookSecret = 'whsec_test';
        $driver = new RazorpayDriver('rzp_test_key', 'keysecret', $webhookSecret);
        $body = json_encode(['event' => 'payment.failed', 'payload' => []]);
        $signature = hash_hmac('sha256', $body, $webhookSecret);

        $event = $driver->handleWebhook(new WebhookRequest($body, $signature));

        $this->assertNull($event->invoiceRef);
        $this->assertNull($event->gatewayTxnRef);
        $this->assertNull($event->amountMinorUnits);
        $this->assertNull($event->currency);
        $this->assertNull($event->capturedAt);
    }

    public function test_handle_webhook_throws_on_wrong_signature(): void
    {
        $driver = new RazorpayDriver('rzp_test_key', 'keysecret', 'webhooksecret');
        $body   = json_encode(['event' => 'payment.captured', 'payload' => []]);

        $this->expectException(SignatureVerificationException::class);
        $driver->handleWebhook(new WebhookRequest($body, 'wrongsignature'));
    }

    public function test_handle_webhook_throws_on_missing_signature(): void
    {
        $driver = new RazorpayDriver('rzp_test_key', 'keysecret', 'webhooksecret');
        $body   = json_encode(['event' => 'payment.captured', 'payload' => []]);

        $this->expectException(SignatureVerificationException::class);
        $driver->handleWebhook(new WebhookRequest($body, ''));
    }

    public function test_handle_webhook_throws_on_invalid_json(): void
    {
        $webhookSecret = 'whsec_test';
        $driver        = new RazorpayDriver('rzp_test_key', 'keysecret', $webhookSecret);
        $body          = 'not-valid-json';
        $signature     = hash_hmac('sha256', $body, $webhookSecret);

        $this->expectException(WebhookException::class);
        $driver->handleWebhook(new WebhookRequest($body, $signature));
    }

    public function test_handle_webhook_throws_when_webhook_secret_not_configured(): void
    {
        $driver = new RazorpayDriver('rzp_test_key', 'keysecret', '');

        $this->expectException(WebhookException::class);
        $driver->handleWebhook(new WebhookRequest('{}', 'anysig'));
    }

    // -------------------------------------------------------------------------
    // Event type normalisation
    // -------------------------------------------------------------------------

    #[\PHPUnit\Framework\Attributes\DataProvider('provideEventTypeMappings')]
    public function test_event_types_are_normalised_correctly(
        string $providerEvent,
        string $expectedType,
    ): void {
        $webhookSecret = 'whsec_test';
        $driver        = new RazorpayDriver('rzp_test_key', 'keysecret', $webhookSecret);
        $body          = json_encode(['event' => $providerEvent, 'payload' => []]);
        $signature     = hash_hmac('sha256', $body, $webhookSecret);

        $event = $driver->handleWebhook(new WebhookRequest($body, $signature));

        $this->assertSame($expectedType, $event->type);
        $this->assertSame($providerEvent, $event->providerEvent);
    }

    /** @return array<string, array{string, string}> */
    public static function provideEventTypeMappings(): array
    {
        return [
            'payment captured'        => ['payment.captured',       'payment.captured'],
            'payment failed'          => ['payment.failed',         'payment.failed'],
            'subscription activated'  => ['subscription.activated', 'subscription.activated'],
            'subscription charged'    => ['subscription.charged',   'subscription.charged'],
            'subscription completed'  => ['subscription.completed', 'subscription.completed'],
            'subscription cancelled'  => ['subscription.cancelled', 'subscription.cancelled'],
            'subscription halted'     => ['subscription.halted',    'subscription.halted'],
            'refund created'          => ['refund.created',         'refund.created'],
            'refund processed'        => ['refund.processed',       'refund.processed'],
            'unknown event'           => ['order.paid',             'unknown'],
            'completely unknown'      => ['some.new.event',         'unknown'],
        ];
    }

    // -------------------------------------------------------------------------
    // createOrder — validates DTO shape (cannot test real API without creds)
    // -------------------------------------------------------------------------

    public function test_create_order_request_dto_stores_values_correctly(): void
    {
        $req = new CreateOrderRequest(
            amountMinorUnits: 49900,
            currency:         'INR',
            receipt:          'test_receipt_001',
            notes:            ['platform_code' => 'acme_store', 'tenant_id' => 'uuid-123'],
        );

        $this->assertSame(49900, $req->amountMinorUnits);
        $this->assertSame('INR', $req->currency);
        $this->assertSame('test_receipt_001', $req->receipt);
        $this->assertSame('acme_store', $req->notes['platform_code']);
    }
}
