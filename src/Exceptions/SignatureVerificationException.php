<?php

declare(strict_types=1);

namespace StoneScriptPay\Exceptions;

/**
 * Raised when HMAC signature verification fails on a payment response or webhook.
 *
 * Treat this as a security event: log it, return 400, do NOT process the payload.
 *
 * @package StoneScriptPay\Exceptions
 */
class SignatureVerificationException extends PaymentException
{
    public function __construct(string $context = 'payment response')
    {
        parent::__construct("Signature verification failed for: {$context}");
    }
}
