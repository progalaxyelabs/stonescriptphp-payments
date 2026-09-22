<?php

declare(strict_types=1);

namespace Tests\Unit\DTO;

use PHPUnit\Framework\TestCase;
use StoneScriptPay\DTO\WebhookEvent;

class WebhookEventTest extends TestCase
{
    public function test_is_payment_captured_returns_true_for_payment_captured_type(): void
    {
        $event = new WebhookEvent('payment.captured', 'payment.captured', []);
        $this->assertTrue($event->isPaymentCaptured());
    }

    public function test_is_payment_captured_returns_false_for_other_types(): void
    {
        $event = new WebhookEvent('payment.failed', 'payment.failed', []);
        $this->assertFalse($event->isPaymentCaptured());
    }

    public function test_is_subscription_event_returns_true_for_subscription_prefix(): void
    {
        foreach (['subscription.activated', 'subscription.charged', 'subscription.cancelled', 'subscription.halted'] as $type) {
            $event = new WebhookEvent($type, $type, []);
            $this->assertTrue($event->isSubscriptionEvent(), "Expected true for type: {$type}");
        }
    }

    public function test_is_refund_event_returns_true_for_refund_prefix(): void
    {
        foreach (['refund.created', 'refund.processed'] as $type) {
            $event = new WebhookEvent($type, $type, []);
            $this->assertTrue($event->isRefundEvent(), "Expected true for type: {$type}");
        }
    }

    public function test_unknown_event_has_correct_type(): void
    {
        $event = new WebhookEvent('unknown', 'some.unrecognised.event', []);
        $this->assertSame('unknown', $event->type);
        $this->assertSame('some.unrecognised.event', $event->providerEvent);
        $this->assertFalse($event->isPaymentCaptured());
        $this->assertFalse($event->isSubscriptionEvent());
        $this->assertFalse($event->isRefundEvent());
    }

    public function test_payload_and_raw_are_stored(): void
    {
        $payload = ['payment' => ['entity' => ['id' => 'pay_123']]];
        $raw     = ['event' => 'payment.captured', 'payload' => $payload];
        $event   = new WebhookEvent('payment.captured', 'payment.captured', $payload, $raw);

        $this->assertSame($payload, $event->payload);
        $this->assertSame($raw, $event->raw);
    }

    /**
     * The normalised fields (v0.2.0+) are additive and default to null —
     * an existing 4-arg construction call is completely unaffected.
     */
    public function test_normalised_fields_default_to_null(): void
    {
        $event = new WebhookEvent('payment.captured', 'payment.captured', []);

        $this->assertNull($event->invoiceRef);
        $this->assertNull($event->gatewayTxnRef);
        $this->assertNull($event->amountMinorUnits);
        $this->assertNull($event->currency);
        $this->assertNull($event->capturedAt);
    }

    public function test_normalised_fields_can_be_populated(): void
    {
        $capturedAt = new \DateTimeImmutable('2026-09-14T00:00:00+00:00');
        $event = new WebhookEvent(
            type: 'payment.captured',
            providerEvent: 'payment.captured',
            payload: [],
            raw: [],
            invoiceRef: 'inv_42',
            gatewayTxnRef: 'pay_ABC123',
            amountMinorUnits: 49900,
            currency: 'INR',
            capturedAt: $capturedAt,
        );

        $this->assertSame('inv_42', $event->invoiceRef);
        $this->assertSame('pay_ABC123', $event->gatewayTxnRef);
        $this->assertSame(49900, $event->amountMinorUnits);
        $this->assertSame('INR', $event->currency);
        $this->assertSame($capturedAt, $event->capturedAt);
    }
}
