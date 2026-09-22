<?php

declare(strict_types=1);

namespace StoneScriptPay\DTO;

/**
 * Result returned by PaymentProvider::createOrder().
 *
 * Pass orderId + publishableKeyId to the frontend so it can open the hosted
 * checkout. The publishableKeyId (Razorpay key_id) is safe to expose to the
 * client — it does NOT grant API access.
 *
 * @package StoneScriptPay\DTO
 */
final class OrderResult
{
    /**
     * @param string $orderId           Provider-assigned order ID (e.g. "order_xxx" on Razorpay).
     * @param int    $amountMinorUnits  Confirmed amount in minor units as set by the server.
     * @param string $currency          ISO 4217 currency code.
     * @param string $receipt           Receipt / reference echoed back from the provider.
     * @param string $publishableKeyId  Publishable key safe to share with the frontend (Razorpay key_id).
     * @param string $status            Order status string from the provider (e.g. "created").
     * @param array  $raw               Raw provider response for logging/debugging.
     */
    public function __construct(
        public readonly string $orderId,
        public readonly int $amountMinorUnits,
        public readonly string $currency,
        public readonly string $receipt,
        public readonly string $publishableKeyId,
        public readonly string $status,
        public readonly array $raw = [],
    ) {}
}
