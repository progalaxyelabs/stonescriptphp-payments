<?php

declare(strict_types=1);

namespace Tests\Unit;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\DTO\CreateOrderRequest;
use StoneScriptPay\DTO\CreateSubscriptionRequest;
use StoneScriptPay\DTO\WebhookRequest;
use StoneScriptPay\Drivers\PaypalDriver;
use StoneScriptPay\Exceptions\PaymentException;
use StoneScriptPay\Exceptions\SignatureVerificationException;
use StoneScriptPay\Exceptions\WebhookException;

/**
 * Unit tests for PaypalDriver — the parts that don't require a live network
 * call: construction, webhook JSON/signature-header handling, event-type
 * normalisation, normalised-field extraction, settlement model, and the
 * "subscriptions not implemented" contract. createOrder/verifySignature/
 * refund/getAccessToken all make real HTTP calls and are out of scope for
 * unit tests here (same convention RazorpayDriverTest documents).
 */
class PaypalDriverTest extends TestCase
{
    private function driver(string $webhookId = 'WH-123', string $baseUrl = 'https://api-m.sandbox.paypal.com'): PaypalDriver
    {
        return new PaypalDriver(
            baseUrl: $baseUrl,
            clientId: 'client_id',
            clientSecret: 'client_secret',
            webhookId: $webhookId,
        );
    }

    public function test_settlement_model_is_gateway(): void
    {
        $this->assertSame('gateway', $this->driver()->settlementModel());
    }

    public function test_handle_webhook_throws_when_webhook_id_not_configured(): void
    {
        $driver = $this->driver('');

        $this->expectException(WebhookException::class);
        $driver->handleWebhook(new WebhookRequest('{}', '', []));
    }

    public function test_handle_webhook_throws_on_invalid_json(): void
    {
        $driver = $this->driver();

        $this->expectException(WebhookException::class);
        $driver->handleWebhook(new WebhookRequest('not-valid-json', '', ['PayPal-Transmission-Id' => 'x']));
    }

    /**
     * Without network access, verify-webhook-signature can never return
     * SUCCESS (the getAccessToken() call itself fails against a fake
     * client id/secret with no network) — confirming the driver correctly
     * FAILS CLOSED (SignatureVerificationException) rather than trusting an
     * unverifiable event. This exercises the same "never trust an
     * unverified POST" invariant PaymentProvider's docblock requires,
     * without needing real PayPal credentials/network in CI.
     */
    public function test_handle_webhook_fails_closed_without_network_verification(): void
    {
        // Unroutable loopback port — fails fast (connection refused) instead
        // of depending on real network egress being reachable in CI.
        $driver = $this->driver(baseUrl: 'http://127.0.0.1:1');
        $body = json_encode([
            'event_type' => 'PAYMENT.CAPTURE.COMPLETED',
            'resource' => ['id' => 'cap_1', 'custom_id' => 'inv_1'],
        ]);

        $this->expectException(SignatureVerificationException::class);
        $driver->handleWebhook(new WebhookRequest($body, '', [
            'PayPal-Transmission-Id' => 'tx-1',
            'PayPal-Transmission-Time' => '2026-09-14T00:00:00Z',
            'PayPal-Cert-Url' => 'https://example.invalid/cert',
            'PayPal-Auth-Algo' => 'SHA256withRSA',
            'PayPal-Transmission-Sig' => 'sig',
        ]));
    }

    // -------------------------------------------------------------------------
    // TENANT ISOLATION round-trip (added 2026-09-22) — custom_id is the only
    // free-form field PayPal echoes back on the capture webhook, so this
    // driver encodes tenant_id/platform_code into it (see createOrder's
    // docblock). No network call is needed to exercise this: the
    // encode/length-guard runs BEFORE getAccessToken(), and the decode side
    // (extractNormalisedFields) is pure string logic tested directly via
    // reflection — the same convention this repo already documents for
    // type-contract regression tests (no live network/creds needed).
    // -------------------------------------------------------------------------

    public function test_create_order_rejects_a_custom_id_that_would_exceed_paypals_127_char_limit(): void
    {
        $driver = $this->driver(baseUrl: 'http://127.0.0.1:1'); // unroutable — proves no network call happens first

        $this->expectException(PaymentException::class);
        $this->expectExceptionMessageMatches('/127-character/');
        $driver->createOrder(new CreateOrderRequest(
            amountMinorUnits: 49900,
            currency: 'USD',
            receipt: str_repeat('r', 60),
            notes: ['tenant_id' => str_repeat('t', 40), 'platform_code' => str_repeat('p', 40)],
        ));
    }

    public function test_create_order_rejects_a_receipt_containing_the_delimiter_character(): void
    {
        $driver = $this->driver(baseUrl: 'http://127.0.0.1:1'); // unroutable — proves no network call happens first

        $this->expectException(PaymentException::class);
        $this->expectExceptionMessageMatches("/contains a literal '\\|'/");
        $driver->createOrder(new CreateOrderRequest(
            amountMinorUnits: 100,
            currency: 'USD',
            receipt: 'inv|42', // a literal '|' would corrupt the encode/decode round-trip
            notes: ['tenant_id' => 'tenant-A', 'platform_code' => 'platform-A'],
        ));
    }

    /**
     * @return array{0:?string,1:?string,2:?int,3:?string,4:?\DateTimeImmutable,5:?string,6:?string}
     */
    private function extractNormalisedFields(PaypalDriver $driver, string $type, array $resource): array
    {
        $method = new \ReflectionMethod(PaypalDriver::class, 'extractNormalisedFields');
        $method->setAccessible(true);

        return $method->invoke($driver, $type, $resource);
    }

    public function test_extract_normalised_fields_splits_a_composite_custom_id_into_invoice_ref_tenant_and_platform(): void
    {
        [$invoiceRef, , , , , $tenantId, $platformCode] = $this->extractNormalisedFields(
            $this->driver(),
            'payment.captured',
            ['id' => 'cap_1', 'custom_id' => 'inv_42|tenant-A|platform-A', 'amount' => ['value' => '10.00', 'currency_code' => 'USD']],
        );

        $this->assertSame('inv_42', $invoiceRef);
        $this->assertSame('tenant-A', $tenantId);
        $this->assertSame('platform-A', $platformCode);
    }

    public function test_extract_normalised_fields_treats_a_bare_custom_id_as_invoice_ref_only(): void
    {
        // No '|' — an order created without tenant context (or by an older
        // caller). invoiceRef is the whole string; tenant/platform stay
        // null, which CollectionOrchestrator::settleFromWebhook() then
        // treats as a fail-loud condition rather than an unenforceable
        // tenant check.
        [$invoiceRef, , , , , $tenantId, $platformCode] = $this->extractNormalisedFields(
            $this->driver(),
            'payment.captured',
            ['id' => 'cap_1', 'custom_id' => 'inv_42', 'amount' => ['value' => '10.00', 'currency_code' => 'USD']],
        );

        $this->assertSame('inv_42', $invoiceRef);
        $this->assertNull($tenantId);
        $this->assertNull($platformCode);
    }

    public function test_create_subscription_throws_not_implemented(): void
    {
        $driver = $this->driver();

        $this->expectException(PaymentException::class);
        $this->expectExceptionMessageMatches('/does not implement subscriptions/');
        $driver->createSubscription(new CreateSubscriptionRequest('plan_1'));
    }

    public function test_cancel_subscription_throws_not_implemented(): void
    {
        $driver = $this->driver();

        $this->expectException(PaymentException::class);
        $driver->cancelSubscription('sub_1');
    }

    public function test_get_subscription_throws_not_implemented(): void
    {
        $driver = $this->driver();

        $this->expectException(PaymentException::class);
        $driver->getSubscription('sub_1');
    }
}
