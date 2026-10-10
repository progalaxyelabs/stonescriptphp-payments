<?php

declare(strict_types=1);

namespace Tests\Http\Support;

use StoneScriptPay\Drivers\RazorpayDriver;
use StoneScriptPay\Http\Webhook\WebhookGateway;

/** Builds genuinely signed Razorpay webhooks, so tests exercise the real driver verification. */
final class WebhookFixtures
{
    public const SECRET = 'whsec_test_only';

    public static function gateway(string $mode = 'test'): WebhookGateway
    {
        return new WebhookGateway('razorpay', new RazorpayDriver('', '', self::SECRET, $mode), 'x-razorpay-signature');
    }

    /** A payment.captured body for a platform (or none) and a payment id. */
    public static function captured(string $paymentId, ?string $platform = 'plat', int $amount = 49900, ?string $orderRef = null, ?string $tenantId = '00000000-0000-0000-0000-000000000001'): string
    {
        $notes = [];
        if ($tenantId !== null) {
            $notes['tenant_id'] = $tenantId;
        }
        if ($platform !== null) {
            $notes['platform_code'] = $platform;
        }
        if ($orderRef !== null) {
            $notes['order_id'] = $orderRef;
        }

        return json_encode([
            'event' => 'payment.captured',
            'payload' => ['payment' => ['entity' => [
                'id' => $paymentId, 'amount' => $amount, 'currency' => 'INR', 'created_at' => 1790000000,
                'notes' => $notes + ['invoice_ref' => 'inv-1'],
            ]]],
        ], JSON_THROW_ON_ERROR);
    }

    /**
     * @return array<string,string> headers carrying a correct signature (or a wrong one) and event id
     */
    public static function headers(string $body, string $eventId, bool $validSignature = true): array
    {
        return [
            'Content-Type' => 'application/json',
            'X-Razorpay-Signature' => $validSignature ? hash_hmac('sha256', $body, self::SECRET) : str_repeat('0', 64),
            'X-Razorpay-Event-Id' => $eventId,
        ];
    }
}
