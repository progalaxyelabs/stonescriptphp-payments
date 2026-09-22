<?php

declare(strict_types=1);

namespace StoneScriptPay\DTO;

/**
 * Payload returned by the hosted checkout that the backend must verify.
 *
 * After the user completes payment on the hosted checkout, the provider returns
 * these three values to the frontend. The frontend posts them to the backend,
 * which calls PaymentProvider::verifySignature() to confirm authenticity.
 *
 * NEVER mark a payment as successful without this backend verification step.
 *
 * @package StoneScriptPay\DTO
 */
final class VerifyRequest
{
    /**
     * @param string $paymentId  Provider payment ID (e.g. "pay_xxx").
     * @param string $orderId    Provider order ID (e.g. "order_xxx"). Must match the order created server-side.
     * @param string $signature  HMAC signature from the provider to verify.
     */
    public function __construct(
        public readonly string $paymentId,
        public readonly string $orderId,
        public readonly string $signature,
    ) {}
}
