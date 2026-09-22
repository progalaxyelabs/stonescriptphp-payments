<?php

declare(strict_types=1);

namespace StoneScriptPay\DTO;

/**
 * Result of PaymentProvider::verifySignature().
 *
 * verified === true means the HMAC matched: the payment response is authentic
 * and originated from the provider. The consuming route handler should then
 * record the payment and return success to the frontend.
 *
 * verified === false should NEVER happen in normal flow — the driver throws
 * SignatureVerificationException instead. This flag is retained for defensive
 * use by callers who catch and suppress the exception.
 *
 * @package StoneScriptPay\DTO
 */
final class VerificationResult
{
    /**
     * @param bool   $verified   True if HMAC signature matched.
     * @param string $paymentId  Echoed from the verified VerifyRequest.
     * @param string $orderId    Echoed from the verified VerifyRequest.
     */
    public function __construct(
        public readonly bool $verified,
        public readonly string $paymentId,
        public readonly string $orderId,
    ) {}
}
